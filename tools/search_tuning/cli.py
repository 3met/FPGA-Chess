"""Command-line interface for synthesized search-parameter tuning."""

from __future__ import annotations

import argparse
import sys
from pathlib import Path

from tools.hardware_build.common import REPO_ROOT

from .workflow import Runner, TuningError, install_signal_handlers


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("command", nargs="?", choices=("run", "status"), default="run")
    parser.add_argument(
        "--config", default=str(REPO_ROOT / "tools/search_tuning/default_config.json"),
        help="Tuning configuration JSON",
    )
    parser.add_argument(
        "--dry-run", action="store_true",
        help="Create/inspect the next candidate without synthesizing, flashing, or benchmarking",
    )
    parser.add_argument(
        "--clean", action="store_true",
        help="Archive the existing output and start a fresh tuning experiment",
    )
    args = parser.parse_args(argv)
    try:
        runner = Runner(Path(args.config))
        install_signal_handlers()
        if args.command == "status":
            if args.dry_run:
                parser.error("--dry-run applies only to run")
            if args.clean:
                parser.error("--clean applies only to run")
            runner.status()
        else:
            runner.run(args.dry_run, clean=args.clean)
        return 0
    except KeyboardInterrupt:
        print("\nInterrupted. Progress is checkpointed; run the same command to resume.", file=sys.stderr)
        return 130
    except (TuningError, ValueError, RuntimeError, OSError) as exc:
        print(f"error: {exc}", file=sys.stderr)
        return 2
