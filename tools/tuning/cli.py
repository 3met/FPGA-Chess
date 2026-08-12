"""Train and export FPGA Chess static-evaluation parameters."""

from __future__ import annotations

import argparse
import os
import sys
from pathlib import Path

from .config import ConfigError, load_config
from .data import build_cache
from .engine import commit_parameters
from .quantization import analyze_quantization, print_quantization_report
from .reporting import print_report, resolve_run, run_status
from .training import train


def build_parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(description=__doc__)
    subparsers = parser.add_subparsers(dest="command", required=True)
    for name, help_text in (
        ("train", "Train static-evaluation parameters"),
        ("view-report", "Print the latest or selected run report"),
        ("quantization-report", "Profile trained NNUE integer ranges"),
        ("engine-commit", "Write trained parameters to engine source files"),
    ):
        subparser = subparsers.add_parser(name, help=help_text)
        subparser.add_argument("--config", help="JSON config path; defaults to the checked-in config")
        if name != "train":
            subparser.add_argument("--run", help="Run ID or path; defaults to the latest applicable run")
        else:
            source = subparser.add_mutually_exclusive_group()
            source.add_argument("--resume", help="Resume a run ID or path from its latest checkpoint")
            source.add_argument(
                "--initialize",
                help="Start a new run from another run's best model with a fresh optimizer",
            )
        if name == "engine-commit":
            subparser.add_argument("--dry-run", action="store_true", help="Show exported material without changing files")
        if name == "quantization-report":
            subparser.add_argument(
                "--sample-positions", type=int, default=131_072,
                help="Number of validation positions to profile (default: 131072)",
            )
    return parser


def main(argv: list[str] | None = None) -> int:
    args = build_parser().parse_args(argv)
    try:
        config = load_config(args.config)
        root = Path(config["output"]["root"])
        if args.command == "train":
            os.environ.setdefault("WANDB_SILENT", "true")
            cache = build_cache(config)
            resume_run = resolve_run(root, args.resume) if args.resume else None
            initialize_run = resolve_run(root, args.initialize) if args.initialize else None
            train(config, cache, resume_run=resume_run, initialize_run=initialize_run)
            return 0
        if args.command == "view-report":
            print_report(resolve_run(root, args.run))
            return 0
        if args.command == "quantization-report":
            report = analyze_quantization(
                config, resolve_run(root, args.run), args.sample_positions
            )
            print_quantization_report(report)
            return 0
        run = resolve_run(root, args.run)
        if args.run is None and run_status(run) != "complete":
            raise ValueError(
                f"latest run {run.name} is {run_status(run)!r}; resume it or pass --run explicitly "
                "to export its best checkpoint"
            )
        commit_parameters(run, args.dry_run)
        return 0
    except KeyboardInterrupt:
        print("Interrupted.", file=sys.stderr)
        return 130
    except (ConfigError, FileNotFoundError, RuntimeError, ValueError, OSError) as exc:
        print(f"error: {exc}", file=sys.stderr)
        return 2
if __name__ == "__main__":
    raise SystemExit(main())
