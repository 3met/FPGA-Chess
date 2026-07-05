"""Estimate a UCI engine rating from a Lichess puzzle CSV."""

from __future__ import annotations

import argparse
import os
import shutil
import sys
from datetime import datetime
from pathlib import Path
from typing import Any


DEFAULT_PUZZLE_PATH = Path("puzzles") / "lichess_db_puzzle.csv"


def _default_engine_path() -> str:
    return os.environ.get("FPGA_CHESS_RATING_ENGINE") or shutil.which("stockfish") or "stockfish"


def solve_puzzle(engine: Any, chess: Any, fen: str, moves: list[str], move_time: float) -> bool:
    board = chess.Board(fen=fen)
    board.push_uci(moves[0])

    for solution in moves[1:]:
        result = engine.play(board, chess.engine.Limit(time=move_time), game=solution)
        engine_guess = result.move.uci()
        board.push(result.move)

        if engine_guess == solution:
            continue
        return solution == moves[-1] and board.is_checkmate()

    return True


def run_rating(
    engine_path: str,
    puzzle_path: Path,
    puzzle_limit: int,
    move_time: float,
    target_rd: float,
) -> int:
    try:
        import chess
        import chess.engine
        import glicko2
        import pandas as pd
    except ImportError as exc:
        print(f"error: missing dependency: {exc.name}", file=sys.stderr)
        return 2

    puzzles = pd.read_csv(puzzle_path, nrows=puzzle_limit)
    puzzles.drop(["Popularity", "NbPlays", "OpeningTags"], axis=1, inplace=True, errors="ignore")
    puzzles["Moves"] = puzzles["Moves"].str.split()

    opponent_ratings: list[float] = []
    opponent_rds: list[float] = []
    outcomes: list[int] = []

    start_time = datetime.now()
    engine = chess.engine.SimpleEngine.popen_uci(engine_path)
    try:
        for idx, row in enumerate(puzzles.itertuples(index=False)):
            score = 1 if solve_puzzle(engine, chess, row.FEN, row.Moves, move_time) else 0
            opponent_ratings.append(row.Rating)
            opponent_rds.append(row.RatingDeviation)
            outcomes.append(score)

            if idx % 32 == 0:
                temp_player = glicko2.Player()
                temp_player.update_player(opponent_ratings, opponent_rds, outcomes)
                if temp_player.getRd() < target_rd:
                    break
                print(f"rating status: {temp_player.getRating():.1f} +- {temp_player.getRd():.1f}")
    finally:
        engine.quit()

    engine_player = glicko2.Player()
    engine_player.update_player(opponent_ratings, opponent_rds, outcomes)
    run_time = datetime.now() - start_time

    print(f"\nscore: {sum(outcomes)}/{len(outcomes)} ({sum(outcomes) / len(outcomes) * 100:.1f}%)")
    print(f"final rating: {engine_player.getRating():.1f} +- {engine_player.getRd():.1f}")
    print(f"runtime: {run_time}")
    return 0


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description="Estimate a UCI engine rating from Lichess puzzles.")
    parser.add_argument("--engine", default=_default_engine_path(), help="UCI engine executable. Defaults to FPGA_CHESS_RATING_ENGINE or stockfish on PATH.")
    parser.add_argument("--puzzles", type=Path, default=DEFAULT_PUZZLE_PATH, help="Path to lichess_db_puzzle.csv.")
    parser.add_argument("--limit", type=int, default=10_000, help="Maximum number of puzzles to load.")
    parser.add_argument("--move-time", type=float, default=0.1, help="Engine time per puzzle move in seconds.")
    parser.add_argument("--target-rd", type=float, default=20.0, help="Stop once estimated rating deviation is below this value.")
    args = parser.parse_args(argv)

    if args.limit <= 0:
        print("error: --limit must be positive", file=sys.stderr)
        return 2
    if args.move_time <= 0:
        print("error: --move-time must be positive", file=sys.stderr)
        return 2
    if args.target_rd <= 0:
        print("error: --target-rd must be positive", file=sys.stderr)
        return 2
    if not args.puzzles.exists():
        print(f"error: puzzle file not found: {args.puzzles}", file=sys.stderr)
        return 2

    return run_rating(args.engine, args.puzzles, args.limit, args.move_time, args.target_rd)


if __name__ == "__main__":
    raise SystemExit(main())
