"""Named profile artifacts and read-only inspection of completed runs."""

import argparse
import json
import re
import shutil
from datetime import datetime, timezone
from pathlib import Path

from .common import BUILD_ROOT, BuildError
from .profile_format import PROFILE_TOPICS, format_profile_topics


def _validate_run_name(name: str) -> str:
    """Keep run names portable and confined to one directory component."""
    reserved = {"CON", "PRN", "AUX", "NUL", "COMPILE"} | {
        f"{prefix}{number}" for prefix in ("COM", "LPT") for number in range(1, 10)
    }
    if (not re.fullmatch(r"[A-Za-z0-9][A-Za-z0-9_.-]*", name)
            or name.endswith(".") or name.split(".")[0].upper() in reserved):
        raise BuildError("Run names must start with a letter or digit and contain only letters, digits, _, -, or .; reserved names (including compile) are not allowed")
    return name


def _read_json(path: Path) -> dict:
    """Turn unavailable or malformed saved artifacts into a CLI error."""
    try:
        value = json.loads(path.read_text(encoding="utf-8"))
        if not isinstance(value, dict):
            raise ValueError("expected a JSON object")
        return value
    except (OSError, ValueError) as exc:
        raise BuildError(f"Cannot read {path}: {exc}") from exc


def profile_output_dir(args: argparse.Namespace) -> Path:
    """Resolve a named run or explicit directory without modifying it."""
    if args.replace and not (args.name or args.output):
        raise BuildError("--replace requires --name or --output")
    if args.output:
        path = Path(args.output).expanduser().absolute()
    else:
        name = _validate_run_name(args.name) if args.name else datetime.now().astimezone().strftime("%Y%m%d-%H%M%S-%f")
        path = BUILD_ROOT / "profile" / name
    _check_destination(path, args.replace)
    return path.resolve()


def _check_destination(path: Path, replace: bool) -> None:
    """Protect existing artifacts and unrelated directories during replacement."""
    root = (BUILD_ROOT / "profile").resolve()
    cache = root / "compile"
    resolved = path.resolve()
    if root.is_relative_to(resolved) or resolved.is_relative_to(cache):
        raise BuildError(f"Profile output overlaps the profiler root or simulator cache: {path}")
    if path.is_symlink():
        raise BuildError(f"Profile directory must not be a symbolic link: {path}")
    if path.exists():
        if not replace:
            raise BuildError(f"Profile run already exists: {path}. Choose another name or use --replace")
        # Only a directory allocated by this profiler may be cleared.
        metadata = _read_json(path / "run.json")
        if metadata.get("name") != path.name or metadata.get("status") not in ("running", "complete"):
            raise BuildError(f"Refusing to replace a directory without profile-run metadata: {path}")


def prepare_profile_run(path: Path, replace: bool) -> None:
    """Reserve the directory and mark the run incomplete before simulator work."""
    _check_destination(path, replace)
    if replace and path.exists():
        shutil.rmtree(path)
    path.mkdir(parents=True, exist_ok=False)
    (path / "run.json").write_text(
        json.dumps({"name": path.name, "status": "running"}, indent=2) + "\n", encoding="utf-8",
    )


def write_profile_reports(path: Path, report: dict) -> None:
    """Save every topic and publish the complete machine-readable measurements last."""
    topic_dir = path / "reports"
    topic_dir.mkdir(exist_ok=True)
    for topic in PROFILE_TOPICS:
        (topic_dir / f"{topic}.txt").write_text(format_profile_topics(report, [topic]), encoding="utf-8")
    (path / "report.json").write_text(json.dumps(report, indent=2) + "\n", encoding="utf-8")


def complete_profile_run(path: Path) -> None:
    """Mark success only after all positions and reports have been saved."""
    (path / "run.json").write_text(
        json.dumps({"name": path.name, "status": "complete", "completed_at": datetime.now(timezone.utc).isoformat()}, indent=2) + "\n",
        encoding="utf-8",
    )


def _completed_runs() -> list[tuple[Path, dict]]:
    """Discover successful runs, ignoring interrupted and unrelated directories."""
    root = BUILD_ROOT / "profile"
    runs = []
    if root.is_dir():
        for path in root.iterdir():
            if not path.is_dir() or path.is_symlink():
                continue
            try:
                metadata = _read_json(path / "run.json")
                if metadata.get("status") == "complete" and (path / "report.json").is_file():
                    runs.append((path, metadata))
            except BuildError:
                continue
    return sorted(runs, key=lambda item: item[1].get("completed_at", ""), reverse=True)


def command_profile_view(args: argparse.Namespace) -> int:
    """View selected saved topics without invoking or compiling a simulator."""
    if args.name and args.run:
        raise BuildError("Choose a run name or --run directory, not both")
    if args.list_topics:
        for topic, description in PROFILE_TOPICS.items():
            print(f"{topic:<12} {description}")
        print(f"{'all':<12} Every topic")
        return 0
    if args.list_runs:
        runs = _completed_runs()
        for path, metadata in runs:
            print(f"{path.name}  {metadata.get('completed_at', '')}")
        if not runs:
            print("No completed profiling runs")
        return 0
    if args.run:
        path = Path(args.run).expanduser().resolve()
    elif args.name:
        path = BUILD_ROOT / "profile" / _validate_run_name(args.name)
    else:
        runs = _completed_runs()
        if not runs:
            raise BuildError("No completed profiling runs; run profile first")
        path = runs[0][0]
    metadata = _read_json(path / "run.json")
    if metadata.get("status") != "complete":
        raise BuildError(f"Profiling run is incomplete: {path}")
    report = _read_json(path / "report.json")
    try:
        if args.position:
            names = [position["name"] for position in report.get("positions", [])]
            if args.position not in names:
                raise BuildError(f"Unknown position {args.position!r}. Available positions: {', '.join(names) or '(single-position run)'}")
            _validate_run_name(args.position)
            report = _read_json(path / "positions" / args.position / "report.json")
        text = format_profile_topics(report, args.topic)
    except (KeyError, TypeError, ValueError, AttributeError) as exc:
        raise BuildError(f"Invalid profiling report in {path}: {exc}") from exc
    print(f"Run: {path.name} ({path})")
    if args.position:
        print(f"Position: {args.position}")
    print(text, end="")
    return 0
