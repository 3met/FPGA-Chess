"""Compile and run shared SystemVerilog benches with Verilator or ModelSim/Questa."""

import argparse
import concurrent.futures
import hashlib
import json
import os
import re
import shutil
from pathlib import Path

from .common import (
    BUILD_ROOT, REPO_ROOT, RTL_COMPILE_TIMEOUT_SECONDS, BuildError, clean_dir,
    print_failure_excerpt, rel, require_tool, rtl_source_dependencies, run_command,
    simulation_lock,
)
from .rtl_config import load_type_config, write_rtl_config
from .manifest import expand_source_set, load_manifest, repo_path


def modelsim_tools() -> dict[str, str]:
    return {
        "vlib": require_tool("vlib"),
        "vlog": require_tool("vlog"),
        "vsim": require_tool("vsim"),
    }


def has_sim_errors(output: str) -> bool:
    error_patterns = [
        r"# \*\* Error:",
        r"# \*\* Fatal:",
        r"\bFatal:",
        r"\bfatal:",
        r"^%Error:",
    ]
    return any(re.search(pattern, output, re.MULTILINE) for pattern in error_patterns)


def parse_fail_count(output: str) -> int | None:
    matches = re.findall(r"Fail Count:\s*([0-9]+)", output, flags=re.IGNORECASE)
    if not matches:
        return None
    return max(int(value) for value in matches)


def parse_pass_count(output: str) -> int | None:
    matches = re.findall(r"Pass Count:\s*([0-9]+)", output, flags=re.IGNORECASE)
    if not matches:
        return None
    return max(int(value) for value in matches)


def compile_modelsim(name: str, sources: list[Path], run_dir: Path, sim_config: dict) -> dict:
    tools = modelsim_tools()
    clean_dir(run_dir)
    if "type_config" not in sim_config:
        raise BuildError("Standalone RTL compilation requires a type_config")
    config_source = write_rtl_config(run_dir, load_type_config(sim_config["type_config"]))
    sources = [config_source, *sources]
    lib_dir = run_dir / "work"
    compile_log = run_dir / "compile.log"

    code, output, elapsed = run_command([tools["vlib"], str(lib_dir)], REPO_ROOT, run_dir / "vlib.log", timeout_seconds=RTL_COMPILE_TIMEOUT_SECONDS)
    if code != 0:
        return {
            "name": name,
            "ok": False,
            "elapsed": elapsed,
            "log": run_dir / "vlib.log",
            "message": f"vlib timed out after {RTL_COMPILE_TIMEOUT_SECONDS}s" if code == 124 else "vlib failed",
            "output": output,
        }

    cmd = [tools["vlog"], *sim_config.get("vlog_args", ["-sv"]), "-work", str(lib_dir)] + [str(path) for path in sources]
    code, output, elapsed = run_command(cmd, REPO_ROOT, compile_log, timeout_seconds=RTL_COMPILE_TIMEOUT_SECONDS)
    ok = code == 0 and not has_sim_errors(output)
    return {
        "name": name,
        "ok": ok,
        "elapsed": elapsed,
        "log": compile_log,
        "message": "compiled" if ok else (f"vlog timed out after {RTL_COMPILE_TIMEOUT_SECONDS}s"
                                               if code == 124 else "vlog failed"),
        "lib_dir": lib_dir,
        "output": output,
    }


def run_modelsim_top(
    name: str,
    top: str,
    lib_dir: Path,
    run_dir: Path,
    sim_config: dict,
    timeout_seconds: float,
) -> dict:
    tools = modelsim_tools()
    run_log = run_dir / "transcript.log"
    cmd = [
        tools["vsim"],
        *sim_config.get("vsim_args", ["-batch", "-t", "ns"]),
        "-lib",
        str(lib_dir),
        top,
        "-l",
        str(run_log),
        "-do",
        sim_config.get("run_do", "run -all; quit -f"),
    ]
    code, output, elapsed = run_command(
        cmd,
        REPO_ROOT,
        run_dir / "vsim.stdout.log",
        timeout_seconds=timeout_seconds,
    )
    transcript = run_log.read_text(encoding="utf-8", errors="replace") if run_log.exists() else output
    return simulation_result(name, code, transcript, elapsed,
                             run_log if run_log.exists() else run_dir / "vsim.stdout.log",
                             timeout_seconds)


def simulation_result(name: str, code: int, output: str, elapsed: float,
                      log: Path, timeout_seconds: float) -> dict:
    """Require clean execution and real assertion summaries for either backend."""
    fail_count = parse_fail_count(output)
    pass_count = parse_pass_count(output)
    has_completion_counts = pass_count is not None and fail_count is not None
    has_passing_checks = pass_count is not None and pass_count > 0
    timed_out = code == 124
    # Identify the simulator's license failure before missing bench summaries.
    license_lock_failed = (
        "Unable to read lock file necessary for use of uncounted nodelocked license"
        in output
    )
    ok = (
        code == 0
        and not has_sim_errors(output)
        and not license_lock_failed
        and has_completion_counts
        and has_passing_checks
        and fail_count == 0
    )
    return {
        "name": name,
        "ok": ok,
        "elapsed": elapsed,
        "log": log,
        "message": "passed" if ok else (
            f"timed out after {timeout_seconds:.0f}s" if timed_out
            else "ModelSim license-lock failure" if license_lock_failed
            else "simulator error" if has_sim_errors(output) and not has_completion_counts
            else (
                "missing completion counts" if not has_completion_counts
                else ("no passing checks" if not has_passing_checks else "failed")
            )
        ),
        "pass_count": pass_count,
        "fail_count": fail_count,
        "output": output,
    }


def compile_verilator(name: str, top: str, sources: list[Path], run_dir: Path,
                      sim_config: dict) -> dict:
    """Cache executable benches by source content, capacities, flags, and toolchain."""
    verilator = require_tool("verilator")
    compiler = require_tool(os.environ.get("CXX", "g++"))
    if "type_config" not in sim_config:
        raise BuildError("Standalone RTL compilation requires a type_config")
    config_source = write_rtl_config(run_dir, load_type_config(sim_config["type_config"]))
    sources = [config_source, *sources]
    executable = run_dir / ("test_sim.exe" if os.name == "nt" else "test_sim")
    compile_log = run_dir / "compile.log"
    fingerprint_path = run_dir / "fingerprint.txt"
    objects = run_dir / "obj"
    # Preserve shared bench flags across coroutines and clocked monitors.
    flags = ["--binary", "--timing", "--assert", "--localize-max-size", "0", "-Wno-fatal", "-O3",
             "-CFLAGS", "-O2", "-j", "2", "--top-module", top,
             *sim_config.get("verilator_args", [])]
    digest = hashlib.sha256()
    for tool in (verilator, compiler):
        code, version, _ = run_command([tool, "--version"], REPO_ROOT)
        if code:
            raise BuildError(f"Could not identify simulator toolchain: {tool}")
        digest.update((tool + version).encode())
    digest.update(json.dumps([flags, {key: os.environ.get(key, "")
        for key in ("CXX", "CXXFLAGS", "LDFLAGS", "MAKE") }], sort_keys=True).encode())
    for source in rtl_source_dependencies(sources):
        digest.update(str(source).encode())
        digest.update(source.read_bytes())
    fingerprint = digest.hexdigest()
    cached = (executable.exists() and fingerprint_path.exists()
              and fingerprint_path.read_text(encoding="utf-8") == fingerprint)
    if cached:
        if objects.exists():
            shutil.rmtree(objects)
        return {"name": name, "ok": True, "elapsed": 0, "log": compile_log,
                "message": "cached", "executable": executable, "output": ""}
    fingerprint_path.unlink(missing_ok=True)
    executable.unlink(missing_ok=True)
    clean_dir(objects)
    cmd = [verilator, *flags, "--Mdir", str(objects), "-o", str(executable),
           *[str(source) for source in sources]]
    code, output, elapsed = run_command(cmd, REPO_ROOT, compile_log, timeout_seconds=RTL_COMPILE_TIMEOUT_SECONDS)
    ok = code == 0 and executable.exists()
    if ok:
        fingerprint_path.write_text(fingerprint, encoding="utf-8")
        # Only the executable and identity are needed for subsequent runs.
        shutil.rmtree(objects)
    return {"name": name, "ok": ok, "elapsed": elapsed, "log": compile_log,
            "message": "compiled" if ok else (f"build timed out after {RTL_COMPILE_TIMEOUT_SECONDS}s"
                                               if code == 124 else "Verilator build failed"),
            "executable": executable, "output": output}


def select_simulators(requested: str) -> list[str]:
    """Select backends explicitly; compilation or assertion failures never trigger fallback."""
    if requested == "auto":
        return ["verilator" if shutil.which("verilator") else "modelsim"]
    if requested == "both":
        return ["verilator", "modelsim"]
    if requested not in ("verilator", "modelsim"):
        raise BuildError(f"Unknown simulator: {requested}")
    return [requested]


def command_compile(args: argparse.Namespace) -> int:
    manifest = load_manifest()
    sim_config = manifest["simulator"]["modelsim"]
    set_names = args.sets or ["portable-rtl"]
    failures = 0

    for set_name in set_names:
        sources = expand_source_set(manifest, set_name)
        result = compile_modelsim(set_name, sources, BUILD_ROOT / "compile" / set_name, sim_config)
        status = "PASS" if result["ok"] else "FAIL"
        print(f"[{status}] compile {set_name}: {result['message']} ({result['elapsed']:.2f}s)")
        print(f"  log: {rel(result['log'])}")
        if not result["ok"]:
            print_failure_excerpt(result["output"])
        failures += 0 if result["ok"] else 1

    return 1 if failures else 0


def run_test(manifest: dict, name: str, timeout_seconds: float,
             simulator: str = "modelsim") -> tuple[dict, dict | None]:
    """Prevent concurrent commands from rebuilding or overwriting one bench's artifacts."""
    with simulation_lock(BUILD_ROOT / "sim" / simulator / f".{name}.lock"):
        return _run_test_unlocked(manifest, name, timeout_seconds, simulator)


def _run_test_unlocked(manifest: dict, name: str, timeout_seconds: float,
                       simulator: str) -> tuple[dict, dict | None]:
    """Run the same bench in isolated backend directories with a shared result contract."""
    test = manifest["tests"][name]
    sources = expand_source_set(manifest, test["source_set"]) + [repo_path(test["testbench"])]
    run_dir = BUILD_ROOT / "sim" / simulator / name
    sim_config = manifest["simulator"]["modelsim"]
    if simulator == "verilator":
        compile_result = compile_verilator(name, test["top"], sources, run_dir,
            {**sim_config, "verilator_args": test.get("verilator_args", [])})
        if not compile_result["ok"]:
            return compile_result, None
        log = run_dir / "transcript.log"
        code, output, elapsed = run_command([str(compile_result["executable"])],
            REPO_ROOT, log, timeout_seconds=timeout_seconds)
        return compile_result, simulation_result(name, code, output, elapsed, log, timeout_seconds)
    compile_result = compile_modelsim(name, sources, run_dir, sim_config)
    if not compile_result["ok"]:
        return compile_result, None
    return compile_result, run_modelsim_top(name, test["top"], compile_result["lib_dir"],
                                           run_dir, sim_config, timeout_seconds)


def print_test_result(name: str, results: tuple[dict, dict | None]) -> bool:
    compile_result, run_result = results
    compile_status = "PASS" if compile_result["ok"] else "FAIL"
    print(f"[{compile_status}] compile {name}: {compile_result['message']} ({compile_result['elapsed']:.2f}s)")
    print(f"  compile log: {rel(compile_result['log'])}")
    if not compile_result["ok"]:
        print_failure_excerpt(compile_result["output"])
        return False

    assert run_result is not None
    run_status = "PASS" if run_result["ok"] else "FAIL"
    counts = []
    if run_result["pass_count"] is not None:
        counts.append(f"pass={run_result['pass_count']}")
    if run_result["fail_count"] is not None:
        counts.append(f"fail={run_result['fail_count']}")
    count_text = f" ({', '.join(counts)})" if counts else ""
    print(f"[{run_status}] run {name}: {run_result['message']}{count_text} ({run_result['elapsed']:.2f}s)")
    print(f"  transcript: {rel(run_result['log'])}")
    if not run_result["ok"]:
        print_failure_excerpt(run_result["output"])
    return run_result["ok"]


def command_test(args: argparse.Namespace) -> int:
    manifest = load_manifest()
    test_names = list(dict.fromkeys(args.names or sorted(manifest["tests"])))
    unknown = [name for name in test_names if name not in manifest["tests"]]
    if unknown:
        raise BuildError("Unknown test(s): " + ", ".join(unknown))

    jobs = 1 if args.jobs is None else args.jobs
    if jobs < 1:
        raise BuildError("--jobs must be at least 1")
    if args.timeout < 1:
        raise BuildError("--timeout must be at least 1 second")
    backends = select_simulators(getattr(args, "simulator", "auto"))
    print("RTL simulator(s): " + ", ".join(backends), flush=True)
    tasks = [(backend, name) for backend in backends for name in test_names]
    failures = 0
    with concurrent.futures.ThreadPoolExecutor(max_workers=jobs) as executor:
        futures = {executor.submit(run_test, manifest, name, args.timeout, backend):
                   (backend, name) for backend, name in tasks}
        for future in concurrent.futures.as_completed(futures):
            backend, name = futures[future]
            if not print_test_result(f"{name} [{backend}]", future.result()):
                failures += 1
            print(flush=True)
    return 1 if failures else 0
