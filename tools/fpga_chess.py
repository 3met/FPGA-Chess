#!/usr/bin/env python3
"""Unified build, test, and synthesis entrypoint for FPGA-Chess."""

from __future__ import annotations

import argparse
import json
import os
import re
import shutil
import subprocess
import sys
import time
from pathlib import Path


REPO_ROOT = Path(__file__).resolve().parents[1]
MANIFEST_PATH = REPO_ROOT / "hardware" / "build" / "manifest.json"
BUILD_ROOT = REPO_ROOT / "work" / "build"


class BuildError(RuntimeError):
    pass


def rel(path: Path) -> str:
    return path.relative_to(REPO_ROOT).as_posix()


def load_manifest() -> dict:
    with MANIFEST_PATH.open(encoding="utf-8") as f:
        return json.load(f)


def repo_path(value: str) -> Path:
    return (REPO_ROOT / value).resolve()


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


def run_command(cmd: list[str], cwd: Path, log_path: Path | None = None) -> tuple[int, str, float]:
    start = time.monotonic()
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
            "log": compile_log,
            "message": "vlib failed",
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
    ok = code == 0 and not has_sim_errors(transcript) and (fail_count is None or fail_count == 0)
    return {
        "name": name,
        "ok": ok,
        "elapsed": elapsed,
        "log": run_log if run_log.exists() else run_dir / "vsim.stdout.log",
        "message": "passed" if ok else "failed",
        "pass_count": pass_count,
        "fail_count": fail_count,
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
        failures += 0 if result["ok"] else 1

    return 1 if failures else 0


def command_test(args: argparse.Namespace) -> int:
    manifest = load_manifest()
    sim_config = manifest["simulator"]["modelsim"]
    test_names = args.names or sorted(manifest["tests"])
    unknown = [name for name in test_names if name not in manifest["tests"]]
    if unknown:
        raise BuildError("Unknown test(s): " + ", ".join(unknown))

    failures = 0
    for name in test_names:
        test = manifest["tests"][name]
        sources = expand_source_set(manifest, test["source_set"]) + [repo_path(test["testbench"])]
        run_dir = BUILD_ROOT / "sim" / name
        compile_result = compile_modelsim(name, sources, run_dir, sim_config)
        compile_status = "PASS" if compile_result["ok"] else "FAIL"
        print(f"[{compile_status}] compile {name}: {compile_result['message']} ({compile_result['elapsed']:.2f}s)")
        print(f"  compile log: {rel(compile_result['log'])}")
        if not compile_result["ok"]:
            failures += 1
            continue

        run_result = run_modelsim_top(name, test["top"], compile_result["lib_dir"], run_dir, sim_config)
        run_status = "PASS" if run_result["ok"] else "FAIL"
        counts = []
        if run_result["pass_count"] is not None:
            counts.append(f"pass={run_result['pass_count']}")
        if run_result["fail_count"] is not None:
            counts.append(f"fail={run_result['fail_count']}")
        count_text = f" ({', '.join(counts)})" if counts else ""
        print(f"[{run_status}] run {name}: {run_result['message']}{count_text} ({run_result['elapsed']:.2f}s)")
        print(f"  transcript: {rel(run_result['log'])}")
        failures += 0 if run_result["ok"] else 1

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
        'QUARTUS_VERSION = "23.1"\nPROJECT_REVISION = "fpga_chess"\n',
        encoding="utf-8",
    )

    lines = [
        f'set_global_assignment -name FAMILY "{target["family"]}"',
        f'set_global_assignment -name DEVICE {target["device"]}',
        f'set_global_assignment -name TOP_LEVEL_ENTITY {target["top"]}',
        f"set_global_assignment -name NUM_PARALLEL_PROCESSORS {parallel_processors}",
        f'set_global_assignment -name SDC_FILE "{quote_tcl_path(repo_path(target["sdc"]))}"',
    ]
    lines.extend(qsf_assignment_for_source(source) for source in sources)
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


def synth_quartus(manifest: dict, target_name: str, target: dict) -> int:
    require_tool("quartus_map")
    require_tool("quartus_fit")
    require_tool("quartus_sta")
    build_dir = BUILD_ROOT / target_name
    clean_dir(build_dir)
    parallel_processors = host_parallel_processors()
    project = write_quartus_project(manifest, target, build_dir, parallel_processors)
    project_name = project.name
    parallel_arg = f"--parallel={parallel_processors}"
    map_args = [f"--effort={target['map_effort']}"] if "map_effort" in target else []
    fit_args = [f"--effort={target['fit_effort']}"] if "fit_effort" in target else []
    commands = [
        ["quartus_map", project_name, parallel_arg, *map_args],
        ["quartus_fit", project_name, parallel_arg, *fit_args],
        ["quartus_sta", project_name, parallel_arg],
    ]
    failed = False
    print(f"Quartus parallel processors: {parallel_processors}")
    for cmd in commands:
        log = build_dir / f"{cmd[0]}.log"
        print(f"Running {' '.join(cmd)}...")
        code, output, elapsed = run_command(cmd, build_dir, log)
        ok = code == 0 and not re.search(r"\bError \([0-9]+\):", output)
        status = "PASS" if ok else "FAIL"
        print(f"[{status}] {cmd[0]} ({elapsed:.2f}s)")
        print(f"  log: {rel(log)}")
        failed = failed or not ok
        if not ok:
            break

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
            f"report_utilization -file {{{quote_tcl_path(build_dir / 'utilization.rpt')}}}",
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
    log = build_dir / "vivado.log"
    cmd = ["vivado", "-mode", "batch", "-source", str(tcl)]
    print(f"Running Vivado synthesis for part {part}...")
    code, output, elapsed = run_command(cmd, REPO_ROOT, log)
    ok = code == 0 and not re.search(r"\bERROR:", output)
    status = "PASS" if ok else "FAIL"
    print(f"[{status}] vivado synth ({elapsed:.2f}s)")
    print(f"  log: {rel(log)}")
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
        return synth_quartus(manifest, args.target, target)
    if target["tool"] == "vivado":
        return synth_vivado(manifest, args.target, target, args.part)
    raise BuildError(f"Unsupported synthesis tool '{target['tool']}'")


def build_parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(description=__doc__)
    subparsers = parser.add_subparsers(dest="command", required=True)

    list_parser = subparsers.add_parser("list", help="List source sets, tests, synthesis targets, and generated data")
    list_parser.set_defaults(func=command_list)

    gen_parser = subparsers.add_parser("gen-data", help="Regenerate deterministic RTL data files")
    gen_parser.add_argument("--update", action="store_true", help="Keep regenerated outputs when they differ")
    gen_parser.set_defaults(func=command_gen_data)

    compile_parser = subparsers.add_parser("compile", help="Compile an RTL source set with ModelSim/Questa")
    compile_parser.add_argument("--set", dest="sets", action="append", help="Source set to compile; defaults to portable-rtl")
    compile_parser.set_defaults(func=command_compile)

    test_parser = subparsers.add_parser("test", help="Run SystemVerilog testbenches with ModelSim/Questa")
    test_parser.add_argument("--name", dest="names", action="append", help="Test name to run; defaults to all tests")
    test_parser.set_defaults(func=command_test)

    synth_parser = subparsers.add_parser("synth", help="Run a synthesis target")
    synth_parser.add_argument("--target", required=True, help="Synthesis target name")
    synth_parser.add_argument("--part", help="Xilinx part for vivado-generic")
    synth_parser.set_defaults(func=command_synth)

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
