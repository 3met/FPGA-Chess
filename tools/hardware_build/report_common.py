"""Shared synthesis-report parsing and display helpers."""

import json
import re
from datetime import datetime
from pathlib import Path

from .common import SYNTH_METADATA

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

