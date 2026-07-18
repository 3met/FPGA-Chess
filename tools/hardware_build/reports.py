"""Synthesis-result and timing-path report parsing and display."""

import argparse
import json
import re
from datetime import datetime, timezone
from pathlib import Path

from .common import BUILD_ROOT, BuildError, QUARTUS_ERROR_RE, REPO_ROOT, SYNTH_METADATA, quote_tcl_path, rel, require_tool, run_command
from .manifest import load_manifest


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


def quartus_report_table(lines: list[str], title: str) -> tuple[list[str], list[list[str]]]:
    """Return the first semicolon-delimited Quartus table following *title*."""
    for index, raw in enumerate(lines):
        if title not in raw or not raw.strip().startswith(";"):
            continue
        headers: list[str] = []
        rows: list[list[str]] = []
        for table_line in lines[index + 1 :]:
            stripped = table_line.strip()
            if not headers:
                if stripped.startswith(";") and ";" in stripped:
                    headers = [cell.strip() for cell in stripped.strip(";").split(";")]
                continue
            if stripped.startswith("+"):
                if rows:
                    return headers, rows
                continue
            if not stripped.startswith(";"):
                continue
            cells = [cell.strip() for cell in stripped.strip(";").split(";")]
            if len(cells) == len(headers):
                rows.append(cells)
        if headers:
            return headers, rows
    return [], []


def quartus_multicorner_timing(lines: list[str]) -> tuple[dict[str, list[str]], dict[str, list[str]]]:
    """Return per-clock worst slack and TNS rows from Quartus's combined table."""
    headers, rows = quartus_report_table(lines, "Multicorner Timing Analysis Summary")
    if not headers:
        return {}, {}
    name_index = headers.index("Clock")
    slack_rows: dict[str, list[str]] = {}
    tns_rows: dict[str, list[str]] = {}
    current: dict[str, list[str]] | None = None
    for row in rows:
        name = row[name_index]
        if name == "Worst-case Slack":
            current = slack_rows
        elif name == "Design-wide TNS":
            current = tns_rows
        elif current is not None and name:
            current[name] = row
    return slack_rows, tns_rows


def short_quartus_clock_name(name: str) -> str:
    """Convert implementation-specific PLL names into stable report labels."""
    if name == "CLOCK_50":
        return name
    if "PLL_OUTPUT_COUNTER|divclk" in name:
        return "PLL engine clock"
    if "FRACTIONAL_PLL|vcoph" in name:
        return "PLL VCO clock"
    return name


def quartus_timing_summary(lines: list[str]) -> tuple[str, list[list[str]]]:
    """Extract a compact per-clock timing summary from Quartus STA output."""
    clock_headers, clock_rows = quartus_report_table(lines, "Clocks")
    fmax_headers, fmax_rows = quartus_report_table(lines, "Slow 1100mV 85C Model Fmax Summary")
    slack_rows, tns_rows = quartus_multicorner_timing(lines)
    if not (clock_headers and slack_rows):
        return "", []

    def column(headers: list[str], name: str) -> int | None:
        try:
            return headers.index(name)
        except ValueError:
            return None

    clock_name = column(clock_headers, "Clock Name")
    frequency = column(clock_headers, "Frequency")
    setup = 1
    hold = 2
    fmax_name = column(fmax_headers, "Clock Name")
    fmax = column(fmax_headers, "Fmax")
    if None in (clock_name, frequency):
        return "", []

    frequencies = {row[clock_name]: row[frequency] for row in clock_rows}
    fmax_values = (
        {row[fmax_name]: row[fmax] for row in fmax_rows}
        if fmax_name is not None and fmax is not None
        else {}
    )
    timing_rows: list[list[str]] = []
    worst_setup: float | None = None
    worst_tns = "N/A"
    for name, row in slack_rows.items():
        if name not in frequencies:
            continue
        setup_slack = row[setup]
        # Internal PLL VCO clocks only participate in pulse-width analysis.
        # Omit them from this setup/hold-oriented summary.
        if setup_slack == "N/A" and row[hold] == "N/A":
            continue
        try:
            setup_value = float(setup_slack)
            if worst_setup is None or setup_value < worst_setup:
                worst_setup = setup_value
                worst_tns = tns_rows.get(name, ["", "N/A"])[setup]
        except ValueError:
            pass
        timing_rows.append(
            [
                short_quartus_clock_name(name),
                frequencies[name],
                fmax_values.get(name, "N/A"),
                setup_slack,
                tns_rows.get(name, ["", "N/A"])[setup],
                row[hold],
            ]
        )
    if worst_setup is None:
        return "", []
    status = "PASS" if worst_setup >= 0 else "FAIL"
    return f"{status} (worst setup slack {worst_setup:.3f} ns; TNS {worst_tns} ns)", timing_rows


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
    timing_status, timing_rows = quartus_timing_summary(timing)
    fit_lines = report_lines(fit_paths)
    components = quartus_hierarchy(fit_lines, True, verbose)
    if not components:
        components = quartus_hierarchy(report_lines(map_paths), False, verbose)
    found = bool(resources or timing_rows or components)
    if not found:
        return False
    print_table("Device utilization", ["Resource", "Used", "Available", "Use"], resources)
    if timing_rows:
        print(f"\nClock and timing: {timing_status}")
        print("  Fmax is reported for the slow 1100mV 85C corner; slack and TNS are worst-case across corners.")
        print_table("Clock summary", ["Clock", "Target", "Fmax", "Setup WNS", "Setup TNS", "Hold WNS"], timing_rows)
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

    errors = [line.strip() for line in lines if QUARTUS_ERROR_RE.search(line)]
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
        if "seed" in metadata:
            details.append(["Seed", str(metadata["seed"])])
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


def command_timing_paths(args: argparse.Namespace) -> int:
    """Run TimeQuest and print failing paths, or tightest passing paths when clean."""
    if args.limit < 1:
        raise BuildError("--limit must be at least 1")
    manifest = load_manifest()
    targets = manifest["synthesis_targets"]
    if args.target not in targets:
        raise BuildError(f"Unknown synthesis target '{args.target}'")
    target = targets[args.target]
    if target["tool"] != "quartus":
        raise BuildError("timing-paths currently supports Quartus targets only")
    build_dir = BUILD_ROOT / args.target
    project = build_dir / "fpga_chess.qpf"
    if not project.exists():
        raise BuildError(f"No Quartus project found for target '{args.target}'")

    require_tool("quartus_sta")
    failing_report = build_dir / "failing_setup_paths.rpt"
    tightest_report = build_dir / "tightest_setup_paths.rpt"
    script = build_dir / "report_failing_paths.tcl"
    script.write_text(
        "\n".join(
            [
                "project_open fpga_chess -revision fpga_chess",
                "create_timing_netlist",
                "read_sdc",
                "update_timing_netlist",
                # Keep the reports separate so passing paths are never presented
                # as failures when the design meets all setup requirements.
                f"report_timing -setup -less_than_slack 0.0 -npaths {args.limit} -nworst 1 -detail summary -file {{{quote_tcl_path(failing_report)}}}",
                f"report_timing -setup -npaths {args.limit} -nworst 1 -detail summary -file {{{quote_tcl_path(tightest_report)}}}",
                "delete_timing_netlist",
                "project_close",
                "",
            ]
        ),
        encoding="utf-8",
    )
    log = build_dir / "quartus_timing_paths.log"
    code, output, elapsed = run_command(["quartus_sta", "-t", str(script)], build_dir, log)
    if code != 0 or QUARTUS_ERROR_RE.search(output):
        raise BuildError(f"Quartus timing-path analysis failed; see {rel(log)}")
    if not failing_report.exists() or not tightest_report.exists():
        raise BuildError("Quartus did not produce one or more timing-path reports")
    failing_text = failing_report.read_text(encoding="utf-8", errors="replace").strip()
    headers, rows = quartus_report_table(failing_text.splitlines(), "Report Timing")
    if rows:
        report = failing_report
        heading = f"Worst failing setup paths (up to {args.limit}; {elapsed:.2f}s):"
    else:
        report = tightest_report
        passing_text = tightest_report.read_text(encoding="utf-8", errors="replace").strip()
        headers, rows = quartus_report_table(passing_text.splitlines(), "Report Timing")
        heading = f"Timing met: tightest passing setup paths (up to {args.limit}; {elapsed:.2f}s):"
    print(f"\n{heading}")
    if rows:
        indices = {header: index for index, header in enumerate(headers)}
        columns = [
            ("Slack (ns)", "Slack"),
            ("From node", "From Node"),
            ("To node", "To Node"),
            ("Required (ns)", "Relationship"),
            ("Skew (ns)", "Clock Skew"),
            ("Delay (ns)", "Data Delay"),
        ]
        compact_rows = [[row[indices[source]] for _, source in columns] for row in rows]
        print_table("Path summary", [display for display, _ in columns], compact_rows)
    elif report == tightest_report:
        print("  No setup paths were reported.")
    print(f"\n  Report: {rel(report)}")
    return 0
