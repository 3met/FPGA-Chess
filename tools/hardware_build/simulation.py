"""ModelSim/Questa compilation and SystemVerilog test commands."""

import argparse
import concurrent.futures
import re
from pathlib import Path

from .common import BUILD_ROOT, REPO_ROOT, BuildError, clean_dir, print_failure_excerpt, rel, require_tool, run_command
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
    ]
    return any(re.search(pattern, output) for pattern in error_patterns)


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
    lib_dir = run_dir / "work"
    compile_log = run_dir / "compile.log"

    code, output, elapsed = run_command([tools["vlib"], str(lib_dir)], REPO_ROOT, run_dir / "vlib.log")
    if code != 0:
        return {
            "name": name,
            "ok": False,
            "elapsed": elapsed,
            "log": run_dir / "vlib.log",
            "message": "vlib failed",
            "output": output,
        }

    cmd = [tools["vlog"], *sim_config.get("vlog_args", ["-sv"]), "-work", str(lib_dir)] + [str(path) for path in sources]
    code, output, elapsed = run_command(cmd, REPO_ROOT, compile_log)
    ok = code == 0 and not has_sim_errors(output)
    return {
        "name": name,
        "ok": ok,
        "elapsed": elapsed,
        "log": compile_log,
        "message": "compiled" if ok else "vlog failed",
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
        *sim_config.get("vsim_args", ["-c", "-t", "ns"]),
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
    fail_count = parse_fail_count(transcript)
    pass_count = parse_pass_count(transcript)
    has_completion_counts = pass_count is not None and fail_count is not None
    has_passing_checks = pass_count is not None and pass_count > 0
    timed_out = code == 124
    ok = (
        code == 0
        and not has_sim_errors(transcript)
        and has_completion_counts
        and has_passing_checks
        and fail_count == 0
    )
    return {
        "name": name,
        "ok": ok,
        "elapsed": elapsed,
        "log": run_log if run_log.exists() else run_dir / "vsim.stdout.log",
        "message": "passed" if ok else (
            f"timed out after {timeout_seconds:.0f}s" if timed_out
            else (
                "missing completion counts" if not has_completion_counts
                else ("no passing checks" if not has_passing_checks else "failed")
            )
        ),
        "pass_count": pass_count,
        "fail_count": fail_count,
        "output": transcript,
    }


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


def run_test(manifest: dict, name: str, timeout_seconds: float) -> tuple[dict, dict | None]:
    test = manifest["tests"][name]
    sources = expand_source_set(manifest, test["source_set"]) + [repo_path(test["testbench"])]
    run_dir = BUILD_ROOT / "sim" / name
    compile_result = compile_modelsim(name, sources, run_dir, manifest["simulator"]["modelsim"])
    if not compile_result["ok"]:
        return compile_result, None
    return (
        compile_result,
        run_modelsim_top(
            name,
            test["top"],
            compile_result["lib_dir"],
            run_dir,
            manifest["simulator"]["modelsim"],
            timeout_seconds,
        ),
    )


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
    test_names = args.names or sorted(manifest["tests"])
    unknown = [name for name in test_names if name not in manifest["tests"]]
    if unknown:
        raise BuildError("Unknown test(s): " + ", ".join(unknown))

    jobs = 1 if args.jobs is None else args.jobs
    if jobs < 1:
        raise BuildError("--jobs must be at least 1")
    if args.timeout < 1:
        raise BuildError("--timeout must be at least 1 second")
    if jobs == 1:
        results = {name: run_test(manifest, name, args.timeout) for name in test_names}
    else:
        with concurrent.futures.ThreadPoolExecutor(max_workers=jobs) as executor:
            futures = {name: executor.submit(run_test, manifest, name, args.timeout) for name in test_names}
            results = {name: futures[name].result() for name in test_names}

    failures = 0
    for name in test_names:
        if not print_test_result(name, results[name]):
            failures += 1

    return 1 if failures else 0
