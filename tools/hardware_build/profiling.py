"""Cycle-accurate engine profiling with Verilator or ModelSim/Questa."""

from __future__ import annotations

import argparse
import concurrent.futures
import hashlib
import os
import re
import shutil
import subprocess
import time
from pathlib import Path

from software.engine.protocol import (
    NODE_COUNT_MAX,
    TIME_MAX_MS,
    ProtocolError,
    encode_fen,
)

from .common import (
    rtl_source_dependencies,
    BUILD_ROOT,
    RTL_COMPILE_TIMEOUT_SECONDS,
    REPO_ROOT,
    BuildError,
    host_parallel_processors,
    print_failure_excerpt,
    rel,
    require_tool,
    run_command,
)
from .clocks import clock_rtl_parameters, resolve_clocks
from .engine_config import (
    engine_config_digest,
    engine_rtl_parameter_values,
    load_engine_config,
)
from .manifest import expand_source_set, load_manifest
from .profile_format import format_profile_topics
from .profile_runs import (
    complete_profile_run, prepare_profile_run, profile_output_dir, write_profile_reports,
)
from .profile_positions import PROFILE_POSITIONS, STARTPOS_FEN
from .profile_report import (
    build_profile_report,
    build_profile_suite_report,
    parse_metric_records,
)
from .rtl_config import rtl_config_source, write_rtl_config
from .simulation import has_sim_errors


VERILATOR_PROFILE_CACHE_LIMIT = 10
DEFAULT_PROFILE_TARGET = "quartus-de1-soc"
VERILATOR_TRAINING_NODES = 3000
VERILATOR_TRAINING_FENS = (STARTPOS_FEN, *(
    case.fen for case in PROFILE_POSITIONS
    if case.name in {"high-branching-castling-tactical", "pure-pawn-endgame"}
))

def _profile_fingerprint(sources: list[Path], extra: str = "") -> str:
    digest = hashlib.sha256()
    digest.update(b"engine-profile-v2")
    digest.update(extra.encode())
    for source in rtl_source_dependencies(sources):
        digest.update(source.as_posix().encode())
        digest.update(source.read_bytes())
    return digest.hexdigest()


def _profile_parameter_args(config: dict, prefix: str) -> list[str]:
    """Translate the same resolved RTL parameters used by synthesis."""
    values = engine_rtl_parameter_values(config)
    return [f"{prefix}{name}={value}" for name, value in values.items()]


def _profile_clock_parameter_args(args: argparse.Namespace, prefix: str) -> list[str]:
    """Use the resolved engine profile for every simulated clock setting."""
    values = clock_rtl_parameters(args.resolved_engine_config["clocks"], profiling=True)
    return [f"{prefix}{name}={value}" for name, value in values.items()]


def _resolve_profile_config(args: argparse.Namespace, manifest: dict | None = None) -> dict:
    """Resolve the synthesis target's engine profile and apply CLI overrides."""
    if manifest is None:
        manifest = load_manifest()
    target_name = getattr(args, "target", DEFAULT_PROFILE_TARGET)
    targets = manifest["synthesis_targets"]
    if target_name not in targets:
        raise BuildError(f"Unknown synthesis target '{target_name}'")
    engine_config = getattr(args, "engine_config", None) or targets[target_name].get("engine_config")
    if engine_config is None:
        raise BuildError(f"Synthesis target '{target_name}' has no engine configuration")
    args.synthesis_target = target_name
    config = load_engine_config(engine_config)
    if args.threads is None:
        args.threads = config["threads"]
    if args.stack_depth is None:
        args.stack_depth = config["stack_depth"]
    if args.engine_clock_hz is None:
        args.engine_clock_hz = config["clocks"]["engine"]["frequency_hz"]
    config["threads"] = args.threads
    config["stack_depth"] = args.stack_depth
    config["clocks"]["engine"]["frequency_hz"] = args.engine_clock_hz
    config["clocks"] = resolve_clocks(config["clocks"])
    config["digest"] = engine_config_digest(config)
    return config


def _compact_verilator_profile_build(build_dir: Path) -> None:
    """Keep only reusable outputs after Verilator has linked the simulator."""
    keep = {"profile_sim.exe" if os.name == "nt" else "profile_sim", "fingerprint.txt", "compile.log", "rtl_config.sv"}
    for path in build_dir.iterdir():
        if path.name in keep:
            continue
        if path.is_dir():
            shutil.rmtree(path)
        else:
            path.unlink()


def _prune_verilator_profile_cache(cache_root: Path, active_dir: Path) -> None:
    """Compact completed builds and retain the ten most recently used executables."""
    completed = []
    for build_dir in cache_root.iterdir():
        fingerprint = build_dir / "fingerprint.txt"
        executable = build_dir / ("profile_sim.exe" if os.name == "nt" else "profile_sim")
        if build_dir.is_dir() and fingerprint.is_file() and executable.is_file():
            _compact_verilator_profile_build(build_dir)
            completed.append((fingerprint.stat().st_mtime_ns, build_dir))
    completed.sort(reverse=True)
    for _, build_dir in completed[VERILATOR_PROFILE_CACHE_LIMIT:]:
        if build_dir != active_dir:
            shutil.rmtree(build_dir)


def _verilator_native_flags(verilator: str) -> tuple[str, str, bool]:
    """Probe host instructions, compiler identity, and GCC profile-guided support."""
    try:
        root = subprocess.run(
            [verilator, "-getenv", "VERILATOR_ROOT"], capture_output=True,
            text=True, check=True, timeout=10,
        ).stdout.strip()
        makefile = (Path(root) / "include" / "verilated.mk").read_text(encoding="utf-8")
        compiler = re.search(r"^CXX\s*=\s*([\w.+/\\:-]+)\s*$", makefile, re.MULTILINE)
        if compiler is None:
            return "", "portable", False
        probe = subprocess.run(
            [compiler.group(1), "-march=native", "-dM", "-E", "-x", "c++", "-"],
            input="", capture_output=True, text=True, check=True, timeout=10,
        )
        if not probe.stdout.strip():
            return "", "portable", False
        # Include compiler/ABI macros as well as ISA features so cached native
        # executables are rebuilt when the compiler or host capabilities change.
        macros = "\n".join(sorted(probe.stdout.splitlines()))
        gcc = "#define __GNUC__ " in macros and not any(
            name in macros for name in ("__clang__", "__INTEL_COMPILER", "__INTEL_LLVM_COMPILER")
        )
        return " -march=native", hashlib.sha256(macros.encode()).hexdigest(), gcc
    except (OSError, subprocess.SubprocessError):
        return "", "portable", False


def _clear_verilator_profile_objects(build_dir: Path, executable: Path) -> None:
    """Force recompilation when switching between instrumented and optimized code."""
    for pattern in ("*.o", "*.a", "*.gch"):
        for path in build_dir.glob(pattern):
            path.unlink()
    executable.unlink(missing_ok=True)


def _train_verilator_profile(executable: Path, build_dir: Path) -> None:
    """Collect compiler branch counts from short, bounded representative searches."""
    training_dir = build_dir / "training"
    training_dir.mkdir(exist_ok=True)
    for index, fen in enumerate(VERILATOR_TRAINING_FENS):
        board_path = training_dir / f"board-{index}.hex"
        metrics_path = training_dir / f"metrics-{index}.tsv"
        log_path = training_dir / f"position-{index}.log"
        log_label = rel(log_path) if log_path.is_relative_to(REPO_ROOT) else str(log_path)
        payload = encode_fen(fen)
        board_path.write_text("".join(f"{value:02x}\n" for value in payload), encoding="ascii")
        code, output, _ = run_command([
            str(executable), f"+BOARD_FILE={board_path}", f"+METRICS_FILE={metrics_path}",
            "+SEARCH_KIND=1", f"+SEARCH_LIMIT={VERILATOR_TRAINING_NODES}",
        ], REPO_ROOT, log_path, timeout_seconds=120)
        if code != 0 or has_sim_errors(output) or not metrics_path.is_file():
            raise BuildError(f"Verilator optimization training failed; see {log_label}")
        _, result = parse_metric_records(metrics_path.read_text(encoding="utf-8"))
        if result.get("error", 0):
            raise BuildError(f"Engine fault during Verilator optimization training; see {log_label}")


def _compile_verilator(sources: list[Path], args: argparse.Namespace) -> Path:
    """Build and cache a native timed profiler executable."""
    verilator = require_tool("verilator")
    verilator_path = Path(verilator).resolve()
    verilator_stat = verilator_path.stat()
    native_flags, native_target, profile_guided = _verilator_native_flags(verilator)
    build_key = (
        f"threads={args.threads};stack={args.stack_depth};clock={args.engine_clock_hz};"
        f"clocks={_profile_clock_parameter_args(args, '')};sim_threads={args.simulator_threads};trace={int(args.waveform)};"
        f"verilator={verilator_path}:{verilator_stat.st_size}:{verilator_stat.st_mtime_ns};"
        f"config={args.resolved_engine_config['digest']};native_opt=o3-lto{native_flags};native_target={native_target}"
        f";assertions=enabled;localize=0;pgo={int(profile_guided)};training={VERILATOR_TRAINING_NODES}:{VERILATOR_TRAINING_FENS if profile_guided else ()}"
    )
    build_key += rtl_config_source(args.resolved_engine_config)
    fingerprint = _profile_fingerprint(sources, build_key)
    build_dir = BUILD_ROOT / "profile" / "compile" / "verilator" / fingerprint[:16]
    config_source = write_rtl_config(build_dir, args.resolved_engine_config)
    executable = build_dir / ("profile_sim.exe" if os.name == "nt" else "profile_sim")
    fingerprint_path = build_dir / "fingerprint.txt"
    if (
        not args.force_rebuild
        and executable.exists()
        and fingerprint_path.exists()
        and fingerprint_path.read_text(encoding="utf-8").strip() == fingerprint
    ):
        fingerprint_path.touch()
        _compact_verilator_profile_build(build_dir)
        _prune_verilator_profile_cache(build_dir.parent, build_dir)
        return executable

    build_dir.mkdir(parents=True, exist_ok=True)
    # An interrupted rebuild must never leave an instrumented executable marked
    # reusable by the previous completed-build fingerprint.
    fingerprint_path.unlink(missing_ok=True)
    _clear_verilator_profile_objects(build_dir, executable)
    for path in build_dir.glob("*.gcda"):
        path.unlink()
    warnings = [
        "TIMESCALEMOD", "WIDTHEXPAND", "WIDTHTRUNC", "WIDTHXZEXPAND",
        "ALWCOMBORDER", "MULTIDRIVEN", "SIDEEFFECT", "CASEINCOMPLETE",
        "LATCH", "UNOPTFLAT", "UNOPTTHREADS",
    ]
    cmd = [
        verilator,
        "--binary",
        "--timing",
        "--assert",
        "--localize-max-size",
        "0",
        "--top-module",
        "tb_engine_profile",
        "--threads",
        str(args.simulator_threads),
        "-O3",
        "-CFLAGS",
        f"-O3 -flto{native_flags}",
        "-LDFLAGS",
        "-flto",
        "-j",
        "0",
        "-DFPGA_CHESS_PROFILE",
        "-Wno-fatal",
        *[f"-Wno-{warning}" for warning in warnings],
        "-Mdir",
        str(build_dir),
        "-o",
        executable.name,
        *_profile_parameter_args(args.resolved_engine_config, "-G"),
        *_profile_clock_parameter_args(args, "-G"),
    ]
    if args.waveform:
        cmd.append("--trace-fst")
    cmd.extend(str(path) for path in [config_source, *sources])
    if profile_guided:
        instrumented_cmd = cmd.copy()
        instrumented_cmd[instrumented_cmd.index("-CFLAGS") + 1] += " -fprofile-generate"
        if args.simulator_threads > 1:
            instrumented_cmd[instrumented_cmd.index("-CFLAGS") + 1] += " -fprofile-update=atomic"
        instrumented_cmd[instrumented_cmd.index("-LDFLAGS") + 1] += " -fprofile-generate"
        instrumented_log = build_dir / "instrumented-compile.log"
        print("Building and training the optimized Verilator simulator...", flush=True)
        code, output, _ = run_command(instrumented_cmd, REPO_ROOT, instrumented_log,
                                      timeout_seconds=RTL_COMPILE_TIMEOUT_SECONDS)
        if code != 0 or not executable.exists():
            print_failure_excerpt(output)
            raise BuildError(f"Verilator training build failed; see {rel(instrumented_log)}")
        _train_verilator_profile(executable, build_dir)
        _clear_verilator_profile_objects(build_dir, executable)
        cmd[cmd.index("-CFLAGS") + 1] += " -fprofile-use -fprofile-correction"
        cmd[cmd.index("-LDFLAGS") + 1] += " -fprofile-use -fprofile-correction"
    code, output, _ = run_command(cmd, REPO_ROOT, build_dir / "compile.log",
                                  timeout_seconds=RTL_COMPILE_TIMEOUT_SECONDS)
    if code != 0 or not executable.exists():
        print_failure_excerpt(output)
        raise BuildError(f"Verilator profile build failed; see {rel(build_dir / 'compile.log')}")
    fingerprint_path.write_text(fingerprint + "\n", encoding="utf-8")
    _compact_verilator_profile_build(build_dir)
    _prune_verilator_profile_cache(build_dir.parent, build_dir)
    return executable


def _compile_profile(manifest: dict, sources: list[Path], args: argparse.Namespace) -> Path:
    vlog = require_tool("vlog")
    tool = Path(vlog).resolve()
    tool_stat = tool.stat()
    capacity_key = f"threads={args.threads};stack={args.stack_depth};config={args.resolved_engine_config['digest']}"
    capacity_key += repr((str(tool), tool_stat.st_size, tool_stat.st_mtime_ns,
                          manifest["simulator"]["modelsim"].get("vlog_args", ["-sv"])))
    capacity_key += rtl_config_source(args.resolved_engine_config)
    fingerprint = _profile_fingerprint(sources, capacity_key)
    library_dir = BUILD_ROOT / "profile" / "compile" / "modelsim" / fingerprint[:16]
    config_source = write_rtl_config(library_dir, args.resolved_engine_config)
    work_dir = library_dir / "modelsim_work"
    fingerprint_path = library_dir / "fingerprint.txt"
    if not args.force_rebuild and work_dir.exists() and fingerprint_path.exists():
        if fingerprint_path.read_text(encoding="utf-8").strip() == fingerprint:
            return work_dir
    library_dir.mkdir(parents=True, exist_ok=True)
    vlib = require_tool("vlib")
    # Invalidate the receipt before a rebuild can alter this library.
    fingerprint_path.unlink(missing_ok=True)
    if not work_dir.exists():
        code, output, _ = run_command([vlib, str(work_dir)], REPO_ROOT, library_dir / "vlib.log",
                                      timeout_seconds=RTL_COMPILE_TIMEOUT_SECONDS)
        if code != 0:
            raise BuildError(f"Could not create profile simulator library:\n{output}")
    cmd = [
        vlog,
        *manifest["simulator"]["modelsim"].get("vlog_args", ["-sv"]),
        "+define+FPGA_CHESS_PROFILE",
        "-work",
        str(work_dir),
        *[str(path) for path in [config_source, *sources]],
    ]
    code, output, _ = run_command(cmd, REPO_ROOT, library_dir / "compile.log",
                                  timeout_seconds=RTL_COMPILE_TIMEOUT_SECONDS)
    if code != 0 or has_sim_errors(output):
        print_failure_excerpt(output)
        raise BuildError(f"Profile RTL compilation failed; see {rel(library_dir / 'compile.log')}")
    fingerprint_path.write_text(fingerprint + "\n", encoding="utf-8")
    return work_dir


def _validate_profile_args(args: argparse.Namespace) -> tuple[str, int]:
    if args.threads < 1:
        raise BuildError("--threads must be positive")
    if args.stack_depth < 1:
        raise BuildError("--stack-depth must be positive")
    if args.engine_clock_hz < 1:
        raise BuildError("--engine-clock-hz must be positive")
    if args.timeout is not None and args.timeout < 1:
        raise BuildError("--timeout must be at least 1 second")
    if not 1 <= args.simulator_threads <= 32:
        raise BuildError("--simulator-threads must be between 1 and 32")
    if args.depth is not None:
        if not 1 <= args.depth < args.stack_depth:
            raise BuildError("--depth must be positive and smaller than --stack-depth")
        return "depth", args.depth
    if args.nodes is not None:
        if not 1 <= args.nodes <= NODE_COUNT_MAX:
            raise BuildError(f"--nodes must be between 1 and {NODE_COUNT_MAX}")
        return "nodes", args.nodes
    if args.time_ms is not None:
        if not 1 <= args.time_ms <= TIME_MAX_MS:
            raise BuildError(f"--time-ms must be between 1 and {TIME_MAX_MS}")
        return "time", args.time_ms
    return "time", 50


def _prepare_profile_simulator(
    args: argparse.Namespace, manifest: dict
) -> tuple[dict, str, Path | None, Path | None]:
    """Compile the selected backend once for one position or a complete suite."""
    sources = expand_source_set(manifest, "engine-profile")
    simulator = args.simulator
    if simulator == "auto":
        simulator = "verilator" if shutil.which("verilator") else "modelsim"
    if simulator == "verilator":
        return manifest, simulator, None, _compile_verilator(sources, args)
    return manifest, simulator, _compile_profile(manifest, sources, args), None


def _run_profile_position(
    args: argparse.Namespace,
    fen: str,
    run_dir: Path,
    search_kind: str,
    search_limit: int,
    manifest: dict,
    simulator: str,
    library: Path | None,
    executable: Path | None,
    position_name: str | None = None,
) -> dict:
    """Run one already-prepared simulation and persist its detailed artifacts."""
    try:
        board_payload = encode_fen(fen)
    except ProtocolError as exc:
        raise BuildError(f"Invalid FEN: {exc}") from exc

    run_dir.mkdir(parents=True, exist_ok=True)
    board_path = run_dir / "board.hex"
    metrics_path = run_dir / "metrics.tsv"
    transcript_path = run_dir / "transcript.log"
    stdout_path = transcript_path if simulator == "verilator" else run_dir / f"{simulator}.stdout.log"
    transient_wave = run_dir / ("wave.wlf" if args.waveform else "transient.wlf")
    board_path.write_text("".join(f"{value:02x}\n" for value in board_payload), encoding="ascii")

    kind_number = {"depth": 0, "nodes": 1, "time": 2}[search_kind]
    plusargs = [
        f"+BOARD_FILE={board_path}",
        f"+METRICS_FILE={metrics_path}",
        f"+SEARCH_KIND={kind_number}",
        f"+SEARCH_LIMIT={search_limit}",
    ]
    if args.event_trace:
        plusargs.append(f"+EVENTS_FILE={run_dir / 'events.jsonl'}")
    if simulator == "verilator":
        assert executable is not None
        if args.waveform:
            plusargs.append(f"+WAVE_FILE={run_dir / 'wave.fst'}")
        cmd = [str(executable), *plusargs]
    else:
        assert library is not None
        vsim = require_tool("vsim")
        run_do = (
            "log -r /*; run -all; quit -f"
            if args.waveform
            else "nolog -all; run -all; quit -f"
        )
        cmd = [
            vsim,
            *manifest["simulator"]["modelsim"].get("vsim_args", ["-batch", "-t", "ns"]),
            "-lib",
            str(library),
            *_profile_parameter_args(args.resolved_engine_config, "-g"),
            *_profile_clock_parameter_args(args, "-g"),
            *plusargs,
        ]
        if not args.waveform:
            # ModelSim can discard its mandatory working WLF while quitting,
            # avoiding a needless final flush of an artifact the profiler removes.
            cmd.append("-wlfdeleteonquit")
        cmd += [
            "-wlf", str(transient_wave), "tb_engine_profile",
            "-l", str(transcript_path), "-do", run_do,
        ]
    code, output, elapsed = run_command(
        cmd, REPO_ROOT, stdout_path, timeout_seconds=args.timeout
    )
    transcript = transcript_path.read_text(encoding="utf-8", errors="replace") if transcript_path.exists() else output
    if code != 0 or has_sim_errors(transcript) or not metrics_path.exists():
        print_failure_excerpt(transcript)
        if code == 124:
            raise BuildError(f"Engine profile timed out after {args.timeout:.0f}s")
        transcript_label = (
            rel(transcript_path) if transcript_path.is_relative_to(REPO_ROOT) else str(transcript_path)
        )
        raise BuildError(f"Engine profile failed; see {transcript_label}")

    metrics, result_values = parse_metric_records(metrics_path.read_text(encoding="utf-8"))
    configuration = {
        "fen": fen,
        "search_limit": {"kind": search_kind, "value": search_limit},
        "threads": args.threads,
        "stack_depth": args.stack_depth,
        "engine_clock_hz": args.engine_clock_hz,
        "engine_profile": args.resolved_engine_config,
        "synthesis_target": args.synthesis_target,
        "memory_clock_hz": args.resolved_engine_config["clocks"]["memory"]["frequency_hz"],
        "tt_tag_bits": args.resolved_engine_config["tt_tag_bits"],
        "tt_entry_words": metrics["tt.entry_words"],
        "tt_entries": metrics["tt.external_entries"],
        "tt_cache_sets": 1 << args.resolved_engine_config["tt_cache_index_bits"],
        "tt_cache_ways": 2,
        "tt_initial_state": "cold",
        "memory_path": "external-cache-cdc-sdr-sdram",
        "simulator": simulator,
        "simulator_threads": args.simulator_threads if simulator == "verilator" else 1,
    }
    if position_name is not None:
        configuration["position_name"] = position_name
    report = build_profile_report(configuration, metrics, result_values, elapsed)
    write_profile_reports(run_dir, report)
    if simulator == "modelsim" and not args.waveform:
        transient_wave.unlink(missing_ok=True)
    return report


def command_profile_position(args: argparse.Namespace) -> int:
    """Run the detailed profiler for one explicitly supplied FEN."""
    manifest = load_manifest()
    args.resolved_engine_config = _resolve_profile_config(args, manifest)
    search_kind, search_limit = _validate_profile_args(args)
    try:
        encode_fen(args.fen)
    except ProtocolError as exc:
        raise BuildError(f"Invalid FEN: {exc}") from exc
    run_dir = profile_output_dir(args)
    prepare_profile_run(run_dir, args.replace)
    manifest, simulator, library, executable = _prepare_profile_simulator(args, manifest)
    report = _run_profile_position(
        args, args.fen, run_dir, search_kind, search_limit,
        manifest, simulator, library, executable,
    )
    complete_profile_run(run_dir)
    print(format_profile_topics(report), end="")
    print(f"Run: {run_dir.name}")
    print()
    print(f"Artifacts: {rel(run_dir) if run_dir.is_relative_to(REPO_ROOT) else run_dir}")
    return 0


def _profile_job_count(args: argparse.Namespace, simulator: str) -> int:
    """Choose process-level suite parallelism without oversubscribing Verilator workers."""
    if args.jobs is not None:
        if args.jobs < 1:
            raise BuildError("--jobs must be positive")
        return min(args.jobs, len(PROFILE_POSITIONS))
    if simulator != "verilator":
        return 1
    return min(
        len(PROFILE_POSITIONS),
        max(1, host_parallel_processors() // args.simulator_threads),
    )


def command_profile(args: argparse.Namespace) -> int:
    """Profile the standard named position suite and print only its summary."""
    profiling_start = time.monotonic()
    manifest = load_manifest()
    args.resolved_engine_config = _resolve_profile_config(args, manifest)
    search_kind, search_limit = _validate_profile_args(args)
    if args.jobs is not None and args.jobs < 1:
        raise BuildError("--jobs must be positive")
    run_dir = profile_output_dir(args)
    prepare_profile_run(run_dir, args.replace)
    manifest, simulator, library, executable = _prepare_profile_simulator(args, manifest)
    jobs = _profile_job_count(args, simulator)
    suite_start = time.monotonic()

    def run_case(case) -> dict:
        """Run one suite case in its own simulator process and artifact directory."""
        return _run_profile_position(
            args, case.fen, run_dir / "positions" / case.name,
            search_kind, search_limit, manifest, simulator, library, executable,
            position_name=case.name,
        )

    reports: list[dict | None] = [None] * len(PROFILE_POSITIONS)
    with concurrent.futures.ThreadPoolExecutor(max_workers=jobs) as executor:
        future_indices = {
            executor.submit(run_case, case): index
            for index, case in enumerate(PROFILE_POSITIONS)
        }
        for future in concurrent.futures.as_completed(future_indices):
            index = future_indices[future]
            try:
                reports[index] = future.result()
            except BuildError as exc:
                raise BuildError(f"Position {PROFILE_POSITIONS[index].name} failed: {exc}") from exc
    suite_wall_seconds = time.monotonic() - suite_start
    named_reports = [
        (case.name, report)
        for case, report in zip(PROFILE_POSITIONS, reports)
        if report is not None
    ]
    suite_report = build_profile_suite_report(
        named_reports, suite_wall_seconds, jobs,
        profiling_wall_seconds=time.monotonic() - profiling_start,
    )
    write_profile_reports(run_dir, suite_report)
    complete_profile_run(run_dir)
    print(format_profile_topics(suite_report), end="")
    print(f"Run: {run_dir.name}")
    print()
    print(f"Artifacts: {rel(run_dir) if run_dir.is_relative_to(REPO_ROOT) else run_dir}")
    return 0
