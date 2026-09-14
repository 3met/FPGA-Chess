"""Tracked, cross-platform Fastchess runner used by search tuning."""

from __future__ import annotations

import argparse
import subprocess
import sys
from datetime import datetime, timezone
from pathlib import Path


def fresh_command(args: argparse.Namespace, run_dir: Path) -> list[str]:
    """Build the reproducible FPGA-versus-Stockfish Fastchess command."""
    sprt = []
    if args.sprt_elo0 is not None:
        sprt = [
            "-sprt", f"elo0={args.sprt_elo0}", f"elo1={args.sprt_elo1}",
            f"alpha={args.sprt_alpha}", f"beta={args.sprt_beta}", "model=logistic",
        ]
    return [
        str(args.fastchess),
        "-engine", f"name=FPGA-{args.label}", f"cmd={sys.executable}",
        "args=-m software.engine", f"dir={args.repo_root}", f"tc={args.fpga_tc}",
        "timemargin=1000",
        "-engine", f"name=Stockfish-{args.stockfish_elo}", f"cmd={args.stockfish}",
        f"tc={args.stockfish_tc}", "option.UCI_LimitStrength=true",
        f"option.UCI_Elo={args.stockfish_elo}", f"option.Threads={args.stockfish_threads}",
        f"option.Hash={args.stockfish_hash}", "option.Ponder=false",
        "-openings", f"file={args.book}", "format=epd", "order=sequential",
        f"start={args.opening_start}", *sprt,
        "-rounds", str(args.rounds), "-repeat", "-concurrency", "1", "-recover",
        "-report", "penta=true", "-ratinginterval", "10", "-autosaveinterval", "10",
        "-config", f"outname={run_dir / 'state.json'}",
        "-event", f"FPGA search tuning {args.label}",
        "-pgnout", f"file={run_dir / 'games.pgn'}", "append=false",
        "-log", f"file={run_dir / 'fastchess.log'}", "level=info", "append=false", "engine=false",
    ]


def resume_command(fastchess: Path, run_dir: Path) -> list[str]:
    """Resume exactly the autosaved Fastchess tournament configuration."""
    return [
        str(fastchess), "-config", f"file={run_dir / 'state.json'}",
        f"outname={run_dir / 'state.json'}", "-log", f"file={run_dir / 'fastchess.log'}",
        "level=info", "append=true", "engine=false",
    ]


def stream_tournament(command: list[str], run_dir: Path) -> int:
    """Persist complete output while forwarding it to the tuner's quiet filter."""
    raw_path = run_dir / "raw-output.txt"
    summary_path = run_dir / "summary.txt"
    with raw_path.open("a", encoding="utf-8", newline="\n") as raw, \
            summary_path.open("a", encoding="utf-8", newline="\n") as summary:
        process = subprocess.Popen(
            command, stdout=subprocess.PIPE, stderr=subprocess.STDOUT,
            text=True, encoding="utf-8", errors="replace", bufsize=1,
        )
        assert process.stdout is not None
        for line in process.stdout:
            raw.write(line)
            raw.flush()
            if line.startswith(("Elo:", "Games:", "SPRT ", "Warning;", "Error;", "Fatal;", "Tournament ")):
                summary.write(line)
                summary.flush()
                print(line, end="", flush=True)
        return process.wait()


def parser() -> argparse.ArgumentParser:
    result = argparse.ArgumentParser(description=__doc__)
    result.add_argument("--fastchess", type=Path, required=True)
    result.add_argument("--resume", type=Path)
    result.add_argument("--results-root", type=Path)
    result.add_argument("--label")
    result.add_argument("--rounds", type=int)
    result.add_argument("--repo-root", type=Path)
    result.add_argument("--stockfish", type=Path)
    result.add_argument("--book", type=Path)
    result.add_argument("--opening-start", type=int)
    result.add_argument("--fpga-tc", default="2+0.02")
    result.add_argument("--stockfish-tc", default="0.2+0.002")
    result.add_argument("--stockfish-elo", type=int, default=3100)
    result.add_argument("--stockfish-threads", type=int, default=1)
    result.add_argument("--stockfish-hash", type=int, default=256)
    result.add_argument("--sprt-elo0", type=float)
    result.add_argument("--sprt-elo1", type=float)
    result.add_argument("--sprt-alpha", type=float, default=0.10)
    result.add_argument("--sprt-beta", type=float, default=0.02)
    return result


def main(argv: list[str] | None = None) -> int:
    args = parser().parse_args(argv)
    args.fastchess = args.fastchess.resolve()
    if args.resume is not None:
        run_dir = args.resume.resolve()
        if not (run_dir / "state.json").is_file():
            raise SystemExit(f"saved tournament state does not exist: {run_dir / 'state.json'}")
        print(f"Results: {run_dir}", flush=True)
        return stream_tournament(resume_command(args.fastchess, run_dir), run_dir)

    required = ("results_root", "label", "rounds", "repo_root", "stockfish", "book", "opening_start")
    if any(getattr(args, name) is None for name in required):
        raise SystemExit("a fresh tournament requires results, engine, book, label, rounds, and opening arguments")
    if args.rounds < 1 or args.opening_start < 1:
        raise SystemExit("rounds and opening start must be positive")
    if (args.sprt_elo0 is None) != (args.sprt_elo1 is None):
        raise SystemExit("both SPRT bounds must be specified together")
    args.results_root = args.results_root.resolve()
    args.repo_root = args.repo_root.resolve()
    args.stockfish = args.stockfish.resolve()
    args.book = args.book.resolve()
    timestamp = datetime.now(timezone.utc).strftime("%Y%m%d-%H%M%S-%f")
    run_dir = args.results_root / f"{args.label}-{timestamp}"
    run_dir.mkdir(parents=True)
    print(f"Results: {run_dir}", flush=True)
    return stream_tournament(fresh_command(args, run_dir), run_dir)


if __name__ == "__main__":
    raise SystemExit(main())
