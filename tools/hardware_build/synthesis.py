"""Quartus and Vivado project generation and synthesis commands."""

import argparse
import base64
import json
import re
import secrets
import shutil
from pathlib import Path

from .common import (
    BUILD_ROOT,
    BuildError,
    QUARTUS_ERROR_RE,
    REPO_ROOT,
    begin_synth_metadata,
    clean_dir,
    finish_synth_metadata,
    host_parallel_processors,
    print_failure_excerpt,
    print_quartus_failure_excerpt,
    quote_tcl_path,
    rel,
    require_tool,
    run_command,
    write_synth_metadata,
)
from .generated_data import command_gen_data
from .engine_config import engine_clock_mhz_for_target, engine_config_for_target
from .manifest import ensure_existing, expand_source_set, load_manifest, repo_path


def qsf_assignment_for_source(path: Path) -> str:
    ext = path.suffix.lower()
    if ext == ".sv":
        assignment = "SYSTEMVERILOG_FILE"
    elif ext == ".v":
        assignment = "VERILOG_FILE"
    elif ext in {".vh", ".svh"}:
        assignment = "MISC_FILE"
    elif ext == ".mif":
        assignment = "MIF_FILE"
    elif ext == ".hex":
        assignment = "HEX_FILE"
    else:
        assignment = "MISC_FILE"
    return f'set_global_assignment -name {assignment} "{quote_tcl_path(path)}"'


def qsf_relevant_pin_line(line: str) -> bool:
    match = re.search(r"\s-to\s+([A-Za-z0-9_]+)", line)
    if not match:
        return False
    base = match.group(1)
    return (
        base == "CLOCK_50"
        or base in {"KEY", "SW", "LEDR"}
        or base.startswith("DRAM_")
        or base.startswith("GPIO_0")
        or base.startswith("HEX")
    )


def replace_once(path: Path, pattern: str, replacement: str) -> None:
    """Update one generated PLL setting and reject an unexpected IP layout."""
    contents = path.read_text(encoding="utf-8")
    updated, count = re.subn(pattern, replacement, contents, count=1)
    if count != 1:
        raise BuildError(f"Could not configure clock-generator template {rel(path)}")
    path.write_text(updated, encoding="utf-8")


def engine_clock_values(engine_clock_mhz: float) -> tuple[str, int]:
    """Quantize MHz to the PLL's micro-MHz precision and derive exact Hz for RTL."""
    frequency_text = f"{engine_clock_mhz:.6f}"
    return frequency_text, round(float(frequency_text) * 1_000_000)


def materialize_intel_pll(template: Path, build_dir: Path, engine_clock_mhz: float) -> Path:
    """Copy the Intel PLL IP and set its output frequency for this build target."""
    destination = build_dir / "clock_generator"
    shutil.copytree(template, destination, dirs_exist_ok=True)
    frequency_text, _ = engine_clock_values(engine_clock_mhz)
    replace_once(
        destination / "pll_ip" / "pll_ip_0002.v",
        r'\.output_clock_frequency0\("[^"]+"\),',
        f'.output_clock_frequency0("{frequency_text} MHz"),',
    )
    replace_once(
        destination / "pll_ip.v",
        r'(gui_output_clock_frequency0" value=")[^"]+(" />)',
        rf"\g<1>{float(frequency_text):g}\g<2>",
    )
    qip = destination / "pll_ip.qip"
    gui_value = base64.b64encode(f"{float(frequency_text):g}".encode()).decode()
    output_value = base64.b64encode(f"{frequency_text} MHz".encode()).decode()
    replace_once(
        qip,
        r"(Z3VpX291dHB1dF9jbG9ja19mcmVxdWVuY3kw::)[^:]+(::RGVzaXJlZCBGcmVxdWVuY3k=)",
        rf"\g<1>{gui_value}\g<2>",
    )
    replace_once(
        qip,
        r"(b3V0cHV0X2Nsb2NrX2ZyZXF1ZW5jeTA=::)[^:]+(::b3V0cHV0X2Nsb2NrX2ZyZXF1ZW5jeTA=)",
        rf"\g<1>{output_value}\g<2>",
    )
    return destination / "pll_ip.qip"


def new_build_id() -> int:
    """Return a fresh nonzero 64-bit identifier for one synthesis invocation."""
    build_id = 0
    while build_id == 0:
        build_id = secrets.randbits(64)
    return build_id


def write_engine_build_config(
    build_dir: Path,
    engine_clock_mhz: float,
    build_id: int,
    engine_config: dict | None = None,
) -> Path:
    """Generate constant engine metadata for the exact synthesized image."""
    config = build_dir / "engine_build_config.svh"
    lines = [
        "// Generated for this synthesis invocation; do not edit.\n"
        f"localparam logic [63:0] FPGA_BUILD_ID = 64'h{build_id:016x};\n"
        f"localparam int ENGINE_CLOCK_FREQ = {engine_clock_values(engine_clock_mhz)[1]:_};\n"
    ]
    if engine_config is not None:
        search = engine_config["search"]
        thresholds = search["quiet_bucket_thresholds"]
        increment = search["increment_fraction"]
        remaining = search["remaining_time_fraction"]
        values = {
            "ENGINE_SEARCH_THREAD_COUNT": engine_config["threads"],
            "ENGINE_SEARCH_STACK_DEPTH": engine_config["stack_depth"],
            "ENGINE_TT_TAG_BITS": engine_config["tt_tag_bits"],
            "ENGINE_ENABLE_SEARCH_STATS": int(engine_config["search_statistics"]),
            "ENGINE_ASPIRATION_HALF_WINDOW": search["aspiration_half_window"],
            "ENGINE_LMR_A_Q8": search["lmr_a_q8"],
            "ENGINE_LMR_B_Q8": search["lmr_b_q8"],
            "ENGINE_LMR_MINIMUM_DEPTH": search["lmr_minimum_depth"],
            "ENGINE_LMR_MINIMUM_MOVE_NUMBER": search["lmr_minimum_move_number"],
            "ENGINE_NULL_MINIMUM_DEPTH": search["null_minimum_depth"],
            "ENGINE_NULL_DEEP_DEPTH_THRESHOLD": search["null_deep_depth_threshold"],
            "ENGINE_NULL_SHALLOW_REDUCTION": search["null_shallow_reduction"],
            "ENGINE_NULL_DEEP_REDUCTION": search["null_deep_reduction"],
            "ENGINE_MOVE_OVERHEAD_MS": search["move_overhead_ms"],
            "ENGINE_MINIMUM_SEARCH_MS": search["minimum_search_ms"],
            "ENGINE_INCREMENT_NUMERATOR": increment[0],
            "ENGINE_INCREMENT_DENOMINATOR": increment[1],
            "ENGINE_REMAINING_TIME_NUMERATOR": remaining[0],
            "ENGINE_REMAINING_TIME_DENOMINATOR": remaining[1],
            "ENGINE_HISTORY_REWARD_PER_DEPTH": search["history_reward_per_depth"],
            "ENGINE_HISTORY_MAXIMUM_REWARD": search["history_maximum_reward"],
            "ENGINE_HISTORY_MALUS_DIVISOR": search["history_malus_divisor"],
            "ENGINE_QUIET_THRESHOLD_1": thresholds[0],
            "ENGINE_QUIET_THRESHOLD_2": thresholds[1],
            "ENGINE_QUIET_THRESHOLD_3": thresholds[2],
            "ENGINE_CASTLING_HISTORY_BONUS": search["castling_history_bonus"],
            "ENGINE_TT_VALIDATE_MINIMUM_DEPTH": search["tt_history_validation_minimum_depth"],
            "ENGINE_TT_VALIDATE_BYPASS_HALFMOVES": search["tt_history_validation_bypass_halfmoves"],
            "ENGINE_TT_STALE_DEPTH_TOLERANCE": search["tt_stale_entry_depth_tolerance"],
        }
        lines.append(f"localparam logic [255:0] ENGINE_CONFIG_DIGEST = 256'h{engine_config['digest']};\n")
        lines.extend(f"localparam int {name} = {value};\n" for name, value in values.items())
    config.write_text("".join(lines), encoding="utf-8")
    return config


def quartus_negative_slack(build_dir: Path) -> list[str]:
    """Return STA summary rows that violate a setup or hold requirement."""
    failures: list[str] = []
    for path in sorted(build_dir.glob("*.sta.summary")):
        for raw in path.read_text(encoding="utf-8", errors="replace").splitlines():
            if re.search(r"\bSlack\s*:\s*-", raw):
                failures.append(f"{rel(path)}: {raw.strip()}")
    return failures


def write_quartus_project(
    manifest: dict,
    target: dict,
    build_dir: Path,
    parallel_processors: int,
    build_id: int,
) -> Path:
    build_dir.mkdir(parents=True, exist_ok=True)
    project = build_dir / "fpga_chess"
    qpf = project.with_suffix(".qpf")
    qsf = project.with_suffix(".qsf")
    sources = expand_source_set(manifest, target["source_set"])
    generated_build_config = None
    engine_clock_mhz = engine_clock_mhz_for_target(target)
    if engine_clock_mhz is not None:
        generated_build_config = write_engine_build_config(
            build_dir,
            engine_clock_mhz,
            build_id,
            engine_config_for_target(target),
        )
    generated_outputs = [
        repo_path(output)
        for item in manifest.get("generated_data", {}).values()
        for output in item["outputs"]
    ]
    ensure_existing(generated_outputs)

    copied_generated_outputs: dict[Path, Path] = {}
    for source in generated_outputs:
        dest = build_dir / rel(source)
        dest.parent.mkdir(parents=True, exist_ok=True)
        shutil.copy2(source, dest)
        copied_generated_outputs[source] = dest

    qpf.write_text(
        'QUARTUS_VERSION = "20.1"\nPROJECT_REVISION = "fpga_chess"\n',
        encoding="utf-8",
    )

    lines = [
        f'set_global_assignment -name FAMILY "{target["family"]}"',
        f'set_global_assignment -name DEVICE {target["device"]}',
        f'set_global_assignment -name TOP_LEVEL_ENTITY {target["top"]}',
        f"set_global_assignment -name NUM_PARALLEL_PROCESSORS {parallel_processors}",
        f'set_global_assignment -name SEARCH_PATH "{quote_tcl_path(REPO_ROOT)}"',
        f'set_global_assignment -name SEARCH_PATH "{quote_tcl_path(build_dir)}"',
        f'set_global_assignment -name SDC_FILE "{quote_tcl_path(repo_path(target["sdc"]))}"',
    ]
    resolved_engine_config = engine_config_for_target(target)
    if resolved_engine_config is not None:
        (build_dir / "resolved_engine_config.json").write_text(
            json.dumps(resolved_engine_config, indent=2) + "\n", encoding="utf-8"
        )
        lines.extend([
            f"set_global_assignment -name VERILOG_MACRO \"FPGA_CHESS_THREAD_CAPACITY={resolved_engine_config['threads']}\"",
            f"set_global_assignment -name VERILOG_MACRO \"FPGA_CHESS_SEARCH_STACK_CAPACITY={resolved_engine_config['stack_depth']}\"",
        ])
    if "seed" in target:
        lines.append(f"set_global_assignment -name SEED {target['seed']}")
    if target.get("fit_timing_optimization", False):
        # Use Quartus's placement-aware optimizations without register
        # retiming, preserving every RTL pipeline and state-machine boundary.
        lines.extend([
            "set_global_assignment -name PHYSICAL_SYNTHESIS_COMBO_LOGIC ON",
            "set_global_assignment -name PHYSICAL_SYNTHESIS_REGISTER_DUPLICATION ON",
            "set_global_assignment -name PHYSICAL_SYNTHESIS_REGISTER_RETIMING OFF",
            "set_global_assignment -name PHYSICAL_SYNTHESIS_EFFORT NORMAL",
            "set_global_assignment -name ROUTER_TIMING_OPTIMIZATION_LEVEL MAXIMUM",
            "set_global_assignment -name ROUTER_LCELL_INSERTION_AND_LOGIC_DUPLICATION ON",
            "set_global_assignment -name ENABLE_BENEFICIAL_SKEW_OPTIMIZATION ON",
        ])
    for message_id in target.get("message_disable", []):
        lines.append(f"set_global_assignment -name MESSAGE_DISABLE {message_id}")
    assigned_sources = set(sources)
    lines.extend(qsf_assignment_for_source(source) for source in sources)
    if generated_build_config is not None:
        lines.append(qsf_assignment_for_source(generated_build_config))
    lines.extend(
        qsf_assignment_for_source(copied_generated_outputs[output])
        for output in generated_outputs
        if output not in assigned_sources
    )
    qip_files = [repo_path(qip) for qip in target.get("qip_files", [])]
    if "clock_generator" in target:
        qip_files.append(
            materialize_intel_pll(
                repo_path(target["clock_generator"]["template"]), build_dir, engine_clock_mhz
            )
        )
    for qip in qip_files:
        lines.append(f'set_global_assignment -name QIP_FILE "{quote_tcl_path(qip)}"')

    template = repo_path(target["qsf_template"])
    if template.exists():
        lines.append("")
        lines.append("# Pin and IO assignments imported from the board template for current top-level ports.")
        for raw_line in template.read_text(encoding="utf-8", errors="replace").splitlines():
            stripped = raw_line.strip()
            if stripped.startswith("set_location_assignment") or stripped.startswith("set_instance_assignment"):
                if qsf_relevant_pin_line(stripped):
                    lines.append(stripped)

    qsf.write_text("\n".join(lines) + "\n", encoding="utf-8")
    return project


def synth_quartus(
    manifest: dict,
    target_name: str,
    target: dict,
    jobs: int | None,
    clean: bool = False,
    stream_logs: bool = False,
) -> int:
    parallel_processors = host_parallel_processors() if jobs is None else jobs
    if parallel_processors < 1:
        raise BuildError("--jobs must be at least 1")
    require_tool("quartus_map")
    require_tool("quartus_fit")
    require_tool("quartus_asm")
    require_tool("quartus_sta")
    build_dir = BUILD_ROOT / target_name
    if clean:
        clean_dir(build_dir)
    else:
        build_dir.mkdir(parents=True, exist_ok=True)
    build_id = new_build_id()
    project = write_quartus_project(manifest, target, build_dir, parallel_processors, build_id)
    metadata = begin_synth_metadata(build_dir, target_name, target)
    resolved_engine_config = engine_config_for_target(target)
    if resolved_engine_config is not None:
        metadata["engine_profile"] = resolved_engine_config
    metadata["build_id"] = f"{build_id:016x}"
    metadata["parallel_processors"] = parallel_processors
    write_synth_metadata(build_dir, metadata)
    project_name = project.name
    parallel_arg = f"--parallel={parallel_processors}"
    map_args = [f"--effort={target['map_effort']}"] if "map_effort" in target else []
    if "map_optimization" in target:
        map_args.append(f"--optimize={target['map_optimization']}")
    fit_args = [f"--effort={target['fit_effort']}"] if "fit_effort" in target else []
    if "seed" in target:
        fit_args.append(f"--seed={target['seed']}")
    commands = [
        ["quartus_map", project_name, parallel_arg, *map_args],
        ["quartus_fit", project_name, parallel_arg, *fit_args],
        ["quartus_asm", project_name],
        ["quartus_sta", project_name, parallel_arg],
    ]
    failed = False
    print(f"Quartus parallel processors: {parallel_processors}")
    for cmd in commands:
        log = build_dir / f"{cmd[0]}.log"
        print(f"Running {' '.join(cmd)}...")
        code, output, elapsed = run_command(
            cmd,
            build_dir,
            log,
            live_log=True,
            tee_stdout=stream_logs,
        )
        ok = code == 0 and not QUARTUS_ERROR_RE.search(output)
        metadata["stages"].append(
            {
                "name": cmd[0],
                "status": "pass" if ok else "fail",
                "return_code": code,
                "elapsed_seconds": round(elapsed, 2),
            }
        )
        write_synth_metadata(build_dir, metadata)
        status = "PASS" if ok else "FAIL"
        print(f"[{status}] {cmd[0]} ({elapsed:.2f}s)")
        print(f"  log: {rel(log)}")
        if not ok:
            print_quartus_failure_excerpt(output)
        failed = failed or not ok
        if not ok:
            break

    timing_failures = quartus_negative_slack(build_dir) if not failed else []
    if timing_failures:
        failed = True
        metadata["stages"][-1]["status"] = "fail"
        print("[FAIL] quartus_sta reported negative slack")
        for line in timing_failures:
            print(f"  {line}")

    finish_synth_metadata(build_dir, metadata, failed)
    return 1 if failed else 0


def write_vivado_project(manifest: dict, target_name: str, target: dict, part: str) -> Path:
    build_dir = BUILD_ROOT / target_name
    clean_dir(build_dir)
    sources = expand_source_set(manifest, target["source_set"])
    xdc = build_dir / "generic_clock.xdc"
    tcl = build_dir / "synth.tcl"

    xdc.write_text(
        f"create_clock -name {target['clock_port']} -period {target['clock_period_ns']} [get_ports {target['clock_port']}]\n",
        encoding="utf-8",
    )

    lines = [
        f"cd {{{quote_tcl_path(REPO_ROOT)}}}",
        f"set_part {{{part}}}",
    ]
    lines.extend(f"read_verilog -sv {{{quote_tcl_path(source)}}}" for source in sources)
    lines.extend(
        [
            f"read_xdc {{{quote_tcl_path(xdc)}}}",
            f"synth_design -top {target['top']} -part {{{part}}}",
            f"report_utilization -hierarchical -hierarchical_depth 10 -file {{{quote_tcl_path(build_dir / 'utilization.rpt')}}}",
            f"report_timing_summary -file {{{quote_tcl_path(build_dir / 'timing_summary.rpt')}}}",
            f"write_checkpoint -force {{{quote_tcl_path(build_dir / 'post_synth.dcp')}}}",
        ]
    )
    tcl.write_text("\n".join(lines) + "\n", encoding="utf-8")
    return tcl


def collect_vivado_summary(build_dir: Path) -> list[str]:
    summaries: list[str] = []
    for report in [build_dir / "utilization.rpt", build_dir / "timing_summary.rpt"]:
        if not report.exists():
            continue
        text = report.read_text(encoding="utf-8", errors="replace")
        for line in text.splitlines():
            stripped = line.strip()
            if (
                stripped.startswith("| Slice LUTs")
                or stripped.startswith("| Slice Registers")
                or stripped.startswith("| Block RAM Tile")
                or "WNS(ns)" in stripped
                or "TNS(ns)" in stripped
            ):
                summaries.append(f"{rel(report)}: {stripped}")
                if len(summaries) >= 12:
                    return summaries
    return summaries


def synth_vivado(manifest: dict, target_name: str, target: dict, part: str | None) -> int:
    if not part:
        raise BuildError(f"--part is required for {target_name}")
    require_tool("vivado")
    tcl = write_vivado_project(manifest, target_name, target, part)
    build_dir = tcl.parent
    metadata = begin_synth_metadata(build_dir, target_name, target)
    metadata["part"] = part
    log = build_dir / "vivado.log"
    cmd = ["vivado", "-mode", "batch", "-source", str(tcl)]
    print(f"Running Vivado synthesis for part {part}...")
    code, output, elapsed = run_command(cmd, REPO_ROOT, log)
    ok = code == 0 and not re.search(r"\bERROR:", output)
    metadata["stages"].append(
        {
            "name": "vivado",
            "status": "pass" if ok else "fail",
            "return_code": code,
            "elapsed_seconds": round(elapsed, 2),
        }
    )
    finish_synth_metadata(build_dir, metadata, not ok)
    status = "PASS" if ok else "FAIL"
    print(f"[{status}] vivado synth ({elapsed:.2f}s)")
    print(f"  log: {rel(log)}")
    if not ok:
        print_failure_excerpt(output)
    for line in collect_vivado_summary(build_dir):
        print(f"  {line}")
    return 0 if ok else 1


def command_synth(args: argparse.Namespace) -> int:
    manifest = load_manifest()
    targets = manifest["synthesis_targets"]
    if args.target not in targets:
        raise BuildError(f"Unknown synthesis target '{args.target}'")
    print("== Generated data ==")
    if command_gen_data(argparse.Namespace(update=args.update_generated_data)) != 0:
        return 1
    print("\n== Synthesis ==")
    target = targets[args.target]
    if target["tool"] == "quartus":
        return synth_quartus(manifest, args.target, target, args.jobs, args.clean, args.stream_logs)
    if target["tool"] == "vivado":
        return synth_vivado(manifest, args.target, target, args.part)
