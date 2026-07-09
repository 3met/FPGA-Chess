#!/usr/bin/env python3
"""Unified build, test, and synthesis entrypoint for FPGA-Chess."""

from __future__ import annotations

import argparse
import concurrent.futures
import json
import os
import re
import shutil
import subprocess
import sys
import time
from datetime import datetime, timezone
from pathlib import Path


REPO_ROOT = Path(__file__).resolve().parents[1]
MANIFEST_PATH = REPO_ROOT / "hardware" / "build" / "manifest.json"
BUILD_ROOT = REPO_ROOT / "work" / "build"
SYNTH_METADATA = "synthesis.json"


class BuildError(RuntimeError):
    pass


def rel(path: Path) -> str:
    return path.relative_to(REPO_ROOT).as_posix()


def load_manifest() -> dict:
    try:
        with MANIFEST_PATH.open(encoding="utf-8") as f:
            manifest = json.load(f)
    except (OSError, json.JSONDecodeError) as exc:
        raise BuildError(f"Could not load {rel(MANIFEST_PATH)}: {exc}") from exc
    validate_manifest(manifest)
    return manifest


def repo_path(value: str) -> Path:
    return (REPO_ROOT / value).resolve()


def manifest_object(manifest: dict, key: str) -> dict:
    value = manifest.get(key)
    if not isinstance(value, dict):
        raise BuildError(f"Manifest field '{key}' must be an object")
    return value


def require_fields(item: dict, context: str, fields: set[str]) -> None:
    missing = sorted(fields - item.keys())
    if missing:
        raise BuildError(f"{context} is missing field(s): {', '.join(missing)}")


def validate_manifest(manifest: object) -> None:
    if not isinstance(manifest, dict):
        raise BuildError("Manifest root must be an object")
    if manifest.get("schema_version") != 1:
        raise BuildError("Manifest schema_version must be 1")

    source_sets = manifest_object(manifest, "source_sets")
    tests = manifest_object(manifest, "tests")
    generated_data = manifest_object(manifest, "generated_data")
    targets = manifest_object(manifest, "synthesis_targets")
    simulator = manifest_object(manifest, "simulator")
    modelsim = simulator.get("modelsim")
    if not isinstance(modelsim, dict):
        raise BuildError("Manifest field 'simulator.modelsim' must be an object")

    for name, items in source_sets.items():
        if not isinstance(items, list) or not all(isinstance(item, str) for item in items):
            raise BuildError(f"Source set '{name}' must be a list of paths or @references")
        expand_source_set(manifest, name)

    for name, test in tests.items():
        if not isinstance(test, dict):
            raise BuildError(f"Test '{name}' must be an object")
        require_fields(test, f"Test '{name}'", {"source_set", "testbench", "top"})
        if test["source_set"] not in source_sets:
            raise BuildError(f"Test '{name}' uses unknown source set '{test['source_set']}'")
        ensure_existing([repo_path(test["testbench"])])

    for name, item in generated_data.items():
        if not isinstance(item, dict):
            raise BuildError(f"Generated data '{name}' must be an object")
        require_fields(item, f"Generated data '{name}'", {"script", "outputs"})
        if not isinstance(item["outputs"], list) or not item["outputs"]:
            raise BuildError(f"Generated data '{name}' outputs must be a non-empty list")
        ensure_existing([repo_path(item["script"])])

    for name, target in targets.items():
        if not isinstance(target, dict):
            raise BuildError(f"Synthesis target '{name}' must be an object")
        require_fields(target, f"Synthesis target '{name}'", {"tool", "top", "source_set"})
        if target["source_set"] not in source_sets:
            raise BuildError(f"Synthesis target '{name}' uses unknown source set '{target['source_set']}'")
        tool_fields = {
            "quartus": {"family", "device", "sdc", "qsf_template"},
            "vivado": {"clock_port", "clock_period_ns"},
        }
        if target["tool"] not in tool_fields:
            raise BuildError(f"Synthesis target '{name}' uses unsupported tool '{target['tool']}'")
        require_fields(target, f"Synthesis target '{name}'", tool_fields[target["tool"]])
        if target["tool"] == "quartus":
            ensure_existing(
                [
                    repo_path(target["sdc"]),
                    repo_path(target["qsf_template"]),
                    *[repo_path(path) for path in target.get("qip_files", [])],
                ]
            )


def quote_tcl_path(path: Path) -> str:
    return path.resolve().as_posix()


def require_tool(name: str) -> str:
    found = shutil.which(name)
    if not found:
        raise BuildError(f"Required tool '{name}' was not found on PATH")
    return found


def host_parallel_processors() -> int:
    if hasattr(os, "sched_getaffinity"):
        try:
            return max(1, len(os.sched_getaffinity(0)))
        except OSError:
            pass
    return max(1, os.cpu_count() or 1)


def run_command(
    cmd: list[str],
    cwd: Path,
    log_path: Path | None = None,
    live_log: bool = False,
) -> tuple[int, str, float]:
    start = time.monotonic()
    if not live_log:
        proc = subprocess.run(
            cmd,
            cwd=str(cwd),
            stdout=subprocess.PIPE,
            stderr=subprocess.STDOUT,
            text=True,
            encoding="utf-8",
            errors="replace",
        )
        elapsed = time.monotonic() - start
        output = proc.stdout
        if log_path is not None:
            log_path.parent.mkdir(parents=True, exist_ok=True)
            log_path.write_text(output, encoding="utf-8")
        return proc.returncode, output, elapsed

    if log_path is None:
        raise BuildError("live_log requires a log path")

    log_path.parent.mkdir(parents=True, exist_ok=True)
    chunks: list[str] = []
    with log_path.open("w", encoding="utf-8", errors="replace") as log_file:
        proc = subprocess.Popen(
            cmd,
            cwd=str(cwd),
            stdout=subprocess.PIPE,
            stderr=subprocess.STDOUT,
            text=True,
            encoding="utf-8",
            errors="replace",
            bufsize=1,
        )
        try:
            assert proc.stdout is not None
            for line in proc.stdout:
                chunks.append(line)
                log_file.write(line)
                log_file.flush()
            code = proc.wait()
        except BaseException:
            proc.terminate()
            try:
                proc.wait(timeout=10)
            except subprocess.TimeoutExpired:
                proc.kill()
                proc.wait()
            raise
    elapsed = time.monotonic() - start
    return code, "".join(chunks), elapsed


def error_excerpt(output: str, limit: int = 8) -> list[str]:
    lines = [line.strip() for line in output.splitlines() if line.strip()]
    interesting = [
        line
        for line in lines
        if re.search(r"\b(error|fatal|failed|failure)\b", line, flags=re.IGNORECASE)
    ]
    return (interesting or lines)[-limit:]


def print_failure_excerpt(output: str) -> None:
    excerpt = error_excerpt(output)
    if excerpt:
        print("  error summary:")
        for line in excerpt:
            print(f"    {line}")


def write_synth_metadata(build_dir: Path, metadata: dict) -> None:
    (build_dir / SYNTH_METADATA).write_text(json.dumps(metadata, indent=2) + "\n", encoding="utf-8")


def begin_synth_metadata(build_dir: Path, target_name: str, target: dict) -> dict:
    metadata = {
        "target": target_name,
        "tool": target["tool"],
        "top": target["top"],
        "started": datetime.now(timezone.utc).astimezone().isoformat(timespec="seconds"),
        "status": "running",
        "stages": [],
    }
    write_synth_metadata(build_dir, metadata)
    return metadata


def finish_synth_metadata(build_dir: Path, metadata: dict, failed: bool) -> None:
    metadata["finished"] = datetime.now(timezone.utc).astimezone().isoformat(timespec="seconds")
    metadata["status"] = "failed" if failed else "complete"
    metadata["elapsed_seconds"] = round(sum(stage["elapsed_seconds"] for stage in metadata["stages"]), 2)
    write_synth_metadata(build_dir, metadata)


def restore_outputs(before: dict[Path, bytes | None]) -> None:
    for path, old in before.items():
        if old is None:
            path.unlink(missing_ok=True)
        else:
            path.write_bytes(old)


def ensure_existing(paths: list[Path]) -> None:
    missing = [rel(path) for path in paths if not path.exists()]
    if missing:
        raise BuildError("Missing required file(s): " + ", ".join(missing))


def expand_source_set(manifest: dict, name: str) -> list[Path]:
    source_sets = manifest["source_sets"]
    if name not in source_sets:
        raise BuildError(f"Unknown source set '{name}'")

    expanded: list[Path] = []
    seen: set[Path] = set()
    active: list[str] = []

    def visit(set_name: str) -> None:
        if set_name in active:
            chain = " -> ".join(active + [set_name])
            raise BuildError(f"Recursive source-set reference: {chain}")
        if set_name not in source_sets:
            raise BuildError(f"Unknown source set '{set_name}'")

        active.append(set_name)
        for item in source_sets[set_name]:
            if item.startswith("@"):
                visit(item[1:])
            else:
                path = repo_path(item)
                if path not in seen:
                    expanded.append(path)
                    seen.add(path)
        active.pop()

    visit(name)
    ensure_existing(expanded)
    return expanded


def print_list(manifest: dict) -> None:
    print("Source sets:")
    for name in sorted(manifest["source_sets"]):
        sources = expand_source_set(manifest, name)
        print(f"  {name}: {len(sources)} files")

    print("\nTests:")
    for name, test in sorted(manifest["tests"].items()):
        print(f"  {name}: top={test['top']} source_set={test['source_set']}")

    print("\nSynthesis targets:")
    for name, target in sorted(manifest["synthesis_targets"].items()):
        print(f"  {name}: tool={target['tool']} top={target['top']}")

    print("\nGenerated data:")
    for name, item in sorted(manifest["generated_data"].items()):
        outputs = ", ".join(item["outputs"])
        print(f"  {name}: {item['script']} -> {outputs}")


def command_list(args: argparse.Namespace) -> int:
    print_list(load_manifest())
    return 0


def command_validate(args: argparse.Namespace) -> int:
    manifest = load_manifest()
    print(
        "Manifest is valid: "
        f"{len(manifest['source_sets'])} source sets, "
        f"{len(manifest['tests'])} tests, "
        f"{len(manifest['synthesis_targets'])} synthesis targets."
    )
    return 0


def command_gen_data(args: argparse.Namespace) -> int:
    manifest = load_manifest()
    changed: list[str] = []

    for name, item in sorted(manifest["generated_data"].items()):
        script = repo_path(item["script"])
        outputs = [repo_path(output) for output in item["outputs"]]
        ensure_existing([script])
        before = {path: path.read_bytes() if path.exists() else None for path in outputs}

        print(f"Generating {name}...")
        code, output, elapsed = run_command([sys.executable, str(script)], REPO_ROOT)
        if output.strip():
            print(output.rstrip())
        if code != 0:
            if not args.update:
                restore_outputs(before)
            raise BuildError(f"{rel(script)} failed with exit code {code}")

        for path in outputs:
            old = before[path]
            new = path.read_bytes() if path.exists() else None
            if old != new:
                changed.append(rel(path))
                if not args.update:
                    restore_outputs({path: old})
        print(f"  done in {elapsed:.2f}s")

    if changed and not args.update:
        print("Generated data drift detected; restored original files:")
        for path in changed:
            print(f"  {path}")
        print("Run with --update to keep regenerated outputs.")
        return 1

    if changed:
        print("Updated generated data:")
        for path in changed:
            print(f"  {path}")
    else:
        print("Generated data is up to date.")
    return 0


def command_check(args: argparse.Namespace) -> int:
    if args.jobs is not None and args.jobs < 1:
        raise BuildError("--jobs must be at least 1")
    print("== Generated data ==")
    if command_gen_data(argparse.Namespace(update=False)) != 0:
        return 1

    print("\n== Python tests ==")
    cmd = [sys.executable, "-m", "unittest", "discover", "-s", "software", "-p", "test_*.py"]
    code, output, elapsed = run_command(cmd, REPO_ROOT)
    if output.strip():
        print(output.rstrip())
    print(f"[{'PASS' if code == 0 else 'FAIL'}] Python tests ({elapsed:.2f}s)")
    if code != 0:
        print_failure_excerpt(output)
        return 1

    print("\n== RTL tests ==")
    return command_test(argparse.Namespace(names=None, jobs=args.jobs))


def clean_dir(path: Path) -> None:
    if path.exists():
        shutil.rmtree(path)
    path.mkdir(parents=True, exist_ok=True)


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


def run_modelsim_top(name: str, top: str, lib_dir: Path, run_dir: Path, sim_config: dict) -> dict:
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
    code, output, elapsed = run_command(cmd, REPO_ROOT, run_dir / "vsim.stdout.log")
    transcript = run_log.read_text(encoding="utf-8", errors="replace") if run_log.exists() else output
    fail_count = parse_fail_count(transcript)
    pass_count = parse_pass_count(transcript)
    has_completion_counts = pass_count is not None and fail_count is not None
    ok = code == 0 and not has_sim_errors(transcript) and has_completion_counts and fail_count == 0
    return {
        "name": name,
        "ok": ok,
        "elapsed": elapsed,
        "log": run_log if run_log.exists() else run_dir / "vsim.stdout.log",
        "message": "passed" if ok else ("missing completion counts" if not has_completion_counts else "failed"),
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


def run_test(manifest: dict, name: str) -> tuple[dict, dict | None]:
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
    if jobs == 1:
        results = {name: run_test(manifest, name) for name in test_names}
    else:
        with concurrent.futures.ThreadPoolExecutor(max_workers=jobs) as executor:
            futures = {name: executor.submit(run_test, manifest, name) for name in test_names}
            results = {name: futures[name].result() for name in test_names}

    failures = 0
    for name in test_names:
        if not print_test_result(name, results[name]):
            failures += 1

    return 1 if failures else 0


def qsf_assignment_for_source(path: Path) -> str:
    ext = path.suffix.lower()
    if ext == ".sv":
        assignment = "SYSTEMVERILOG_FILE"
    elif ext in {".v", ".vh"}:
        assignment = "VERILOG_FILE"
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
        or base.startswith("GPIO_0")
        or base.startswith("HEX")
    )


def write_quartus_project(manifest: dict, target: dict, build_dir: Path, parallel_processors: int) -> Path:
    build_dir.mkdir(parents=True, exist_ok=True)
    project = build_dir / "fpga_chess"
    qpf = project.with_suffix(".qpf")
    qsf = project.with_suffix(".qsf")
    sources = expand_source_set(manifest, target["source_set"])
    generated_outputs = [
        repo_path(output)
        for item in manifest.get("generated_data", {}).values()
        for output in item["outputs"]
    ]
    ensure_existing(generated_outputs)

    for source in generated_outputs:
        dest = build_dir / rel(source)
        dest.parent.mkdir(parents=True, exist_ok=True)
        shutil.copy2(source, dest)

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
    assigned_sources = set(sources)
    lines.extend(qsf_assignment_for_source(source) for source in sources)
    lines.extend(qsf_assignment_for_source(output) for output in generated_outputs if output not in assigned_sources)
    for qip in target.get("qip_files", []):
        lines.append(f'set_global_assignment -name QIP_FILE "{quote_tcl_path(repo_path(qip))}"')

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


def collect_quartus_summary(build_dir: Path) -> list[str]:
    summaries: list[str] = []
    for pattern in ("*.map.summary", "*.fit.summary", "*.sta.summary", "*.sta.rpt"):
        for path in sorted(build_dir.rglob(pattern)):
            text = path.read_text(encoding="utf-8", errors="replace")
            for line in text.splitlines():
                stripped = line.strip()
                if (
                    "Fmax" in stripped
                    or "Total logic elements" in stripped
                    or "Total registers" in stripped
                    or "Total block memory bits" in stripped
                    or "Slack" in stripped
                    or "Timing requirements" in stripped
                ):
                    summaries.append(f"{rel(path)}: {stripped}")
                    if len(summaries) >= 12:
                        return summaries
    return summaries


def report_timestamp(build_dir: Path, metadata: dict | None) -> str:
    if metadata and metadata.get("started"):
        return str(metadata["started"])
    logs = sorted(build_dir.glob("quartus_*.log"), key=lambda path: path.stat().st_mtime, reverse=True)
    for path in logs:
        text = path.read_text(encoding="utf-8", errors="replace")
        match = re.search(r"Processing started:\s+(.+)$", text, re.MULTILINE)
        if match:
            try:
                return datetime.strptime(match.group(1).strip(), "%a %b %d %H:%M:%S %Y").astimezone().isoformat(
                    timespec="seconds"
                )
            except ValueError:
                pass
    files = [path for path in build_dir.rglob("*") if path.is_file()]
    if not files:
        return "unknown"
    timestamp = min(path.stat().st_mtime for path in files)
    return datetime.fromtimestamp(timestamp).astimezone().isoformat(timespec="seconds")


def load_synth_metadata(build_dir: Path) -> dict | None:
    path = build_dir / SYNTH_METADATA
    if not path.exists():
        return None
    try:
        value = json.loads(path.read_text(encoding="utf-8"))
    except (OSError, json.JSONDecodeError):
        return None
    return value if isinstance(value, dict) else None


def report_lines(paths: list[Path]) -> list[str]:
    lines: list[str] = []
    for path in paths:
        if path.exists():
            lines.extend(path.read_text(encoding="utf-8", errors="replace").splitlines())
    return lines


def matching_report_rows(lines: list[str], patterns: tuple[str, ...]) -> list[str]:
    rows: list[str] = []
    seen: set[str] = set()
    for raw in lines:
        stripped = raw.strip()
        if not stripped or stripped in seen:
            continue
        if any(re.search(pattern, stripped, re.IGNORECASE) for pattern in patterns):
            rows.append(stripped)
            seen.add(stripped)
    return rows


def format_duration(seconds: float) -> str:
    if seconds < 60:
        return f"{seconds:.2f}s"
    minutes, remainder = divmod(seconds, 60)
    if minutes < 60:
        return f"{int(minutes)}m {remainder:04.1f}s"
    hours, minutes = divmod(int(minutes), 60)
    return f"{hours}h {minutes}m {remainder:04.1f}s"


def print_table(title: str, headers: list[str], rows: list[list[str]]) -> None:
    if not rows:
        return
    print(f"\n{title}:")
    widths = [len(header) for header in headers]
    for row in rows:
        for index, value in enumerate(row):
            widths[index] = max(widths[index], len(value))
    print("  " + "  ".join(header.ljust(widths[index]) for index, header in enumerate(headers)).rstrip())
    print("  " + "  ".join("-" * width for width in widths))
    for row in rows:
        print("  " + "  ".join(value.ljust(widths[index]) for index, value in enumerate(row)).rstrip())


def print_unavailable(title: str, reason: str) -> None:
    print(f"\n{title}:")
    print(f"  Unavailable ({reason})")


def parse_quartus_summary(lines: list[str]) -> list[list[str]]:
    resources: list[list[str]] = []
    wanted = (
        "Logic utilization",
        "Total ALMs",
        "Total combinational functions",
        "Total registers",
        "Total pins",
        "Total block memory bits",
        "Total RAM Blocks",
        "Total memory blocks",
        "Total DSP",
    )
    for raw in lines:
        match = re.match(r"\s*([^:]+?)\s*:\s*(.+?)\s*$", raw)
        if not match or not match.group(1).startswith(wanted):
            continue
        value = match.group(2)
        amount_match = re.match(r"(.+?)\s*/\s*(.+?)\s*\(\s*(\d+)\s*%\s*\)$", value)
        if amount_match:
            resources.append([match.group(1), amount_match.group(1).strip(), amount_match.group(2).strip(), f"{amount_match.group(3)}%"])
        else:
            resources.append([match.group(1), value, "", ""])
    return resources


def quartus_table(lines: list[str], title: str) -> tuple[list[str], list[list[str]]]:
    for index, raw in enumerate(lines):
        if title not in raw:
            continue
        for header_index in range(index + 1, min(index + 8, len(lines))):
            header = lines[header_index].strip()
            if not header.startswith(";") or "Compilation Hierarchy Node" not in header:
                continue
            headers = [cell.strip() for cell in header.strip(";").split(";")]
            rows: list[list[str]] = []
            for row_line in lines[header_index + 1 :]:
                stripped = row_line.strip()
                if stripped.startswith("+") and rows:
                    break
                if not stripped.startswith(";") or "|" not in stripped:
                    continue
                cells = stripped.strip(";").split(";")
                cells = [cells[0].rstrip(), *[cell.strip() for cell in cells[1:]]]
                if len(cells) == len(headers):
                    rows.append(cells)
            return headers, rows
    return [], []


def hierarchy_depth(name: str) -> int:
    return (len(name) - len(name.lstrip())) // 3


def quartus_hierarchy(lines: list[str], fitter: bool, verbose: bool) -> list[list[str]]:
    title = "Fitter Resource Utilization by Entity" if fitter else "Analysis & Synthesis Resource Utilization by Entity"
    headers, raw_rows = quartus_table(lines, title)
    if not headers:
        return []
    indices = {header: index for index, header in enumerate(headers)}
    name_index = indices["Compilation Hierarchy Node"]
    library_index = indices.get("Library Name")
    logic_header = "ALMs needed [=A-B+C]" if fitter else "Combinational ALUTs"
    selected: list[list[str]] = []
    for row in raw_rows:
        name = row[name_index]
        depth = hierarchy_depth(name)
        generated = any(marker in name for marker in ("auto_generated", "altsyncram:", "altera_pll:"))
        if not verbose and (depth > 3 or generated or (library_index is not None and row[library_index] != "work")):
            continue
        display_name = name.lstrip().lstrip("|").rstrip("|")
        selected.append(
            [
                f"{'  ' * depth}{display_name}",
                row[indices[logic_header]],
                row[indices["Dedicated Logic Registers"]],
                row[indices["Block Memory Bits"]],
                row[indices["DSP Blocks"]],
            ]
        )
    return selected


def quartus_synth_report(build_dir: Path, verbose: bool = False) -> bool:
    timing_paths = sorted(build_dir.glob("*.sta.summary")) + sorted(build_dir.glob("*.sta.rpt"))
    fit_paths = sorted(build_dir.glob("*.fit.rpt"))
    map_paths = sorted(build_dir.glob("*.map.rpt"))
    fit_summary_paths = sorted(build_dir.glob("*.fit.summary"))
    map_summary_paths = sorted(build_dir.glob("*.map.summary"))
    summary = report_lines(fit_summary_paths) or report_lines(map_summary_paths)
    timing = report_lines(timing_paths)
    resources = parse_quartus_summary(summary)
    clocks = matching_report_rows(
        timing,
        (r"Fmax", r"Restricted Fmax", r"Slack", r"Timing requirements", r"\bMHz\b"),
    )
    fit_lines = report_lines(fit_paths)
    components = quartus_hierarchy(fit_lines, True, verbose)
    if not components:
        components = quartus_hierarchy(report_lines(map_paths), False, verbose)
    found = bool(resources or clocks or components)
    if not found:
        return False
    print_table("Device utilization", ["Resource", "Used", "Available", "Use"], resources)
    if clocks:
        print_table("Clock and timing", ["Result"], [[row] for row in clocks[:20]])
    else:
        print_unavailable("Clock and timing", "timing report not generated")
    print_table("Utilization by component", ["Component", "Logic", "Registers", "Memory bits", "DSP"], components)
    return True


def quartus_partial_report(build_dir: Path) -> bool:
    log_paths = sorted(build_dir.glob("quartus_*.log"))
    if not log_paths:
        return False
    lines = report_lines(log_paths)
    if not lines:
        return False

    errors = matching_report_rows(lines, (r"^Error(?:\s+\(\d+\))?:", r"\bfatal\b"))
    warnings = sum(1 for line in lines if re.match(r"\s*Warning(?:\s+\(\d+\))?:", line))
    entities = {
        match.group(1)
        for line in lines
        if (match := re.search(r"Found entity \d+:\s+([A-Za-z_][A-Za-z0-9_$]*)", line))
    }
    elaborated = [
        match.group(1)
        for line in lines
        if (match := re.search(r'Elaborating entity "([^"]+)"', line))
    ]
    completed = any("Processing ended:" in line or "successful. 0 errors" in line.lower() for line in lines)
    started_match = next(
        (re.search(r"Processing started:\s+(.+)$", line) for line in lines if "Processing started:" in line),
        None,
    )
    elapsed_text = "unknown"
    if started_match:
        try:
            started = datetime.strptime(started_match.group(1).strip(), "%a %b %d %H:%M:%S %Y").astimezone()
            ended = max(path.stat().st_mtime for path in log_paths)
            elapsed_text = format_duration(max(0.0, ended - started.timestamp()))
        except ValueError:
            pass

    print("\nPartial synthesis progress:")
    print(f"  Analysis & Synthesis: {'complete' if completed else 'incomplete'}")
    print(f"  Approximate logged runtime: {elapsed_text}")
    print(f"  Parsed entities: {len(entities)}")
    print(f"  Elaborated hierarchy entries: {len(elaborated)}")
    print(f"  Warnings: {warnings}")
    if elaborated:
        print(f"  Last elaborated entity: {elaborated[-1]}")
    if errors:
        print("  Quartus errors:")
        for error in errors[-8:]:
            print(f"    {error}")
    elif not completed:
        print("  Termination: cause unknown; the log ends without a Quartus error or completion record")
    print("  Resource utilization and Fmax are unavailable because mapping did not reach report generation.")
    return True


def vivado_hierarchy(lines: list[str], verbose: bool) -> list[list[str]]:
    headers: list[str] = []
    raw_rows: list[list[str]] = []
    for index, raw in enumerate(lines):
        if re.match(r"\s*\|\s*Instance\s*\|\s*Module\s*\|", raw):
            headers = [cell.strip() for cell in raw.strip().strip("|").split("|")]
            for row_line in lines[index + 1 :]:
                if row_line.lstrip().startswith("+") and raw_rows:
                    break
                if not row_line.lstrip().startswith("|"):
                    continue
                inner = row_line.strip("\r\n").lstrip().strip("|")
                cells = inner.split("|")
                cells = [cells[0].rstrip(), *[cell.strip() for cell in cells[1:]]]
                if len(cells) == len(headers):
                    raw_rows.append(cells)
            break
    if not headers:
        return []
    indices = {header: index for index, header in enumerate(headers)}

    def value(row: list[str], *names: str) -> str:
        for name in names:
            if name in indices:
                return row[indices[name]]
        return ""

    rows = []
    for row in raw_rows:
        instance = row[indices["Instance"]]
        depth = (len(instance) - len(instance.lstrip())) // 2
        if not verbose and depth > 3:
            continue
        bram = "/".join(filter(None, [value(row, "RAMB36"), value(row, "RAMB18")]))
        rows.append(
            [
                f"{'  ' * depth}{instance.strip()}",
                value(row, "Module"),
                value(row, "Total LUTs", "LUTs"),
                value(row, "FFs", "Registers"),
                bram,
                value(row, "DSP Blocks", "DSPs"),
            ]
        )
    return rows


def vivado_synth_report(build_dir: Path, verbose: bool = False) -> bool:
    utilization = report_lines([build_dir / "utilization.rpt"])
    timing = report_lines([build_dir / "timing_summary.rpt"])
    resources = matching_report_rows(
        utilization,
        (
            r"^\|\s*(?:Slice LUTs|LUT as Logic|LUT as Memory|Slice Registers|Block RAM Tile|RAMB\d+|DSPs?)\s*\|",
        ),
    )
    component_rows = vivado_hierarchy(utilization, verbose)
    clocks = matching_report_rows(
        timing,
        (r"WNS\(ns\)", r"^\s*\w+\s+\{[^}]+\}\s+[-\d.]+\s+[-\d.]+", r"Clock Summary", r"Requirement"),
    )
    joined_timing = "\n".join(timing)
    slack_match = re.search(
        r"WNS\(ns\).*?\n[-+\s]*\n?\s*([-+]?\d+(?:\.\d+)?)\s+[-+]?\d",
        joined_timing,
        re.IGNORECASE,
    )
    period_match = re.search(r"Requirement:\s*([0-9]+(?:\.[0-9]+)?)ns", joined_timing, re.IGNORECASE)
    if slack_match and period_match:
        slack = float(slack_match.group(1))
        period = float(period_match.group(1))
        minimum_period = period - slack
        if minimum_period > 0:
            clocks.append(f"Estimated maximum clock: {1000.0 / minimum_period:.3f} MHz (period - WNS)")
    found = bool(resources or clocks or component_rows)
    if not found:
        return False
    resource_rows = []
    for row in resources:
        cells = [cell.strip() for cell in row.strip().strip("|").split("|")]
        resource_rows.append((cells + ["", "", ""])[:4])
    print_table("Device utilization", ["Resource", "Used", "Available", "Use"], resource_rows)
    if clocks:
        print_table("Clock and timing", ["Result"], [[row] for row in clocks[:20]])
    else:
        print_unavailable("Clock and timing", "timing report not generated")
    print_table("Utilization by component", ["Component", "Module", "LUTs", "Registers", "BRAM", "DSP"], component_rows)
    return True


def command_synth_report(args: argparse.Namespace) -> int:
    manifest = load_manifest()
    targets = manifest["synthesis_targets"]
    if args.target:
        if args.target not in targets:
            raise BuildError(f"Unknown synthesis target '{args.target}'")
        target_name = args.target
    else:
        candidates = [
            (path.stat().st_mtime, name)
            for name in targets
            if (path := BUILD_ROOT / name).is_dir()
        ]
        if not candidates:
            raise BuildError("No previous synthesis results found")
        target_name = max(candidates)[1]

    target = targets[target_name]
    build_dir = BUILD_ROOT / target_name
    if not build_dir.is_dir():
        raise BuildError(f"No synthesis results found for target '{target_name}'")
    metadata = load_synth_metadata(build_dir)
    print(f"Synthesis report: {target_name}")
    details = [
        ["Tool", target["tool"]],
        ["Top", target["top"]],
        ["Device", target.get("device", metadata.get("part") if metadata else "unspecified")],
        ["Started", report_timestamp(build_dir, metadata)],
    ]
    if metadata:
        details.append(["Status", str(metadata.get("status", "unknown")).upper()])
        if "elapsed_seconds" in metadata:
            details.append(["Tool time", format_duration(metadata["elapsed_seconds"])])
        print_table("Run", ["Field", "Value"], details)
        stage_rows = []
        for stage in metadata.get("stages", []):
            stage_rows.append(
                [
                    stage["name"],
                    str(stage["status"]).upper(),
                    format_duration(stage["elapsed_seconds"]),
                    str(stage.get("return_code", "")),
                ]
            )
        print_table("Stages", ["Stage", "Status", "Time", "Return code"], stage_rows)
    else:
        details.append(["Status/time", "unavailable (run predates synthesis metadata)"])
        print_table("Run", ["Field", "Value"], details)

    found = (
        quartus_synth_report(build_dir, args.verbose)
        if target["tool"] == "quartus"
        else vivado_synth_report(build_dir, args.verbose)
    )
    partial = False
    if not found and target["tool"] == "quartus":
        partial = quartus_partial_report(build_dir)
    if not found:
        if partial:
            print(f"\n  Build directory: {rel(build_dir)}")
            return 0
        print("\nNo synthesis reports or partial logs were found.")
        print(f"  Build directory: {rel(build_dir)}")
        return 1
    return 0


def synth_quartus(manifest: dict, target_name: str, target: dict, jobs: int | None) -> int:
    parallel_processors = host_parallel_processors() if jobs is None else jobs
    if parallel_processors < 1:
        raise BuildError("--jobs must be at least 1")
    require_tool("quartus_map")
    require_tool("quartus_fit")
    require_tool("quartus_asm")
    require_tool("quartus_sta")
    build_dir = BUILD_ROOT / target_name
    clean_dir(build_dir)
    project = write_quartus_project(manifest, target, build_dir, parallel_processors)
    metadata = begin_synth_metadata(build_dir, target_name, target)
    metadata["parallel_processors"] = parallel_processors
    project_name = project.name
    parallel_arg = f"--parallel={parallel_processors}"
    map_args = [f"--effort={target['map_effort']}"] if "map_effort" in target else []
    fit_args = [f"--effort={target['fit_effort']}"] if "fit_effort" in target else []
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
        code, output, elapsed = run_command(cmd, build_dir, log, live_log=True)
        ok = code == 0 and not re.search(r"\bError \([0-9]+\):", output)
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
            print_failure_excerpt(output)
        failed = failed or not ok
        if not ok:
            break

    finish_synth_metadata(build_dir, metadata, failed)
    for line in collect_quartus_summary(build_dir):
        print(f"  {line}")
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
        raise BuildError("--part is required for vivado-generic")
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
    target = targets[args.target]
    if target["tool"] == "quartus":
        return synth_quartus(manifest, args.target, target, args.jobs)
    if target["tool"] == "vivado":
        return synth_vivado(manifest, args.target, target, args.part)
    raise BuildError(f"Unsupported synthesis tool '{target['tool']}'")


def build_parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(description=__doc__)
    subparsers = parser.add_subparsers(dest="command", required=True)

    list_parser = subparsers.add_parser("list", help="List source sets, tests, synthesis targets, and generated data")
    list_parser.set_defaults(func=command_list)

    validate_parser = subparsers.add_parser("validate", help="Validate the build manifest and referenced files")
    validate_parser.set_defaults(func=command_validate)

    gen_parser = subparsers.add_parser("gen-data", help="Regenerate deterministic RTL data files")
    gen_parser.add_argument("--update", action="store_true", help="Keep regenerated outputs when they differ")
    gen_parser.set_defaults(func=command_gen_data)

    compile_parser = subparsers.add_parser("compile", help="Compile an RTL source set with ModelSim/Questa")
    compile_parser.add_argument("--set", dest="sets", action="append", help="Source set to compile; defaults to portable-rtl")
    compile_parser.set_defaults(func=command_compile)

    test_parser = subparsers.add_parser("test", help="Run SystemVerilog testbenches with ModelSim/Questa")
    test_parser.add_argument("--name", dest="names", action="append", help="Test name to run; defaults to all tests")
    test_parser.add_argument("--jobs", type=int, help="Number of tests to run concurrently; defaults to 1")
    test_parser.set_defaults(func=command_test)

    check_parser = subparsers.add_parser("check", help="Check generated data and run Python and RTL tests")
    check_parser.add_argument("--jobs", type=int, help="Number of RTL tests to run concurrently; defaults to 1")
    check_parser.set_defaults(func=command_check)

    synth_parser = subparsers.add_parser("synth", help="Run a synthesis target")
    synth_parser.add_argument("--target", required=True, help="Synthesis target name")
    synth_parser.add_argument("--part", help="Xilinx part for vivado-generic")
    synth_parser.add_argument("--jobs", type=int, help="Quartus parallel processor limit; defaults to detected CPUs")
    synth_parser.set_defaults(func=command_synth)

    report_parser = subparsers.add_parser("synth-report", help="Print results from the previous synthesis run")
    report_parser.add_argument("--target", help="Synthesis target; defaults to the most recently modified result")
    report_parser.add_argument("--verbose", action="store_true", help="Show the complete component utilization hierarchy")
    report_parser.set_defaults(func=command_synth_report)

    return parser


def main(argv: list[str] | None = None) -> int:
    parser = build_parser()
    args = parser.parse_args(argv)
    try:
        return args.func(args)
    except BuildError as exc:
        print(f"error: {exc}", file=sys.stderr)
        return 2


if __name__ == "__main__":
    raise SystemExit(main())
