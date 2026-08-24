"""Vivado synthesis-report parsing."""

import re
from pathlib import Path

from .report_common import matching_report_rows, print_table, print_unavailable, report_lines

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
    print_table("Utilization by component", ["Component", "Module", "LUTs", "Registers", "BRAMs", "DSP"], component_rows)
    return True
