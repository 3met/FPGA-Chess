"""FPGA UCI sanity checks and perft regressions."""

from __future__ import annotations

import argparse
import re
import sys
from typing import Iterable, Sequence

from software.benchmarks.positions import (
    PERFT_POSITIONS,
    REPETITION_CASES,
    SANITY_POSITIONS,
    RepetitionCase,
)
from software.benchmarks.session import FPGAUCISession, FPGAUCIError

NODES_RE = re.compile(r"\bnodes\s+(\d+)\b")
SCORE_RE = re.compile(r"\bscore\s+(cp|mate)\s+(-?\d+)\b")
PERFT_RE = re.compile(r"(?:Nodes searched:\s*|\bnodes\s+)(\d+)\b", re.IGNORECASE)
MOVE_RE = re.compile(r"^(?:[a-h][1-8][a-h][1-8][qrbn]?|0000)$")


FAST_PERFT = PERFT_POSITIONS
SANITY_DEPTH = 6
SANITY_REPETITION_DEPTH = 8
SANITY_MOVETIME_MS = 250
SANITY_MOVETIME_TOLERANCE_MS = 5
def _node_count(lines: Iterable[str]) -> int | None:
    result = None
    for line in lines:
        match = NODES_RE.search(line)
        if match:
            result = int(match.group(1))
    return result


def _bestmove(lines: Iterable[str]) -> str | None:
    for line in reversed(list(lines)):
        parts = line.split()
        if len(parts) >= 2 and parts[0] == "bestmove" and MOVE_RE.fullmatch(parts[1]):
            return parts[1]
    return None


def _uci_score(lines: Iterable[str]) -> str | None:
    """Return the last centipawn or mate score from UCI search output."""
    result = None
    for line in lines:
        match = SCORE_RE.search(line)
        if match:
            result = f"{match.group(1)} {int(match.group(2))}"
    return result


def _search_position(engine: FPGAUCISession, position: str, go: str, timeout: float) -> tuple[int, str, float, str]:
    """Search one complete set of UCI position arguments."""
    engine.send("position " + position)
    engine.send(go)
    result = engine.wait_for(lambda line: line.startswith("bestmove "), timeout, "bestmove")
    nodes, move, score = _node_count(result.lines), _bestmove(result.lines), _uci_score(result.lines)
    if nodes is None or move is None or score is None:
        raise FPGAUCIError("search response did not contain nodes, a UCI score, and a parseable bestmove")
    return nodes, move, result.elapsed_seconds, score


def _search(engine: FPGAUCISession, fen: str, go: str, timeout: float) -> tuple[int, str, float]:
    nodes, move, elapsed_seconds, _ = _search_position(engine, "fen " + fen, go, timeout)
    return nodes, move, elapsed_seconds


def _repetition_position(case: RepetitionCase, moves: Sequence[str]) -> str:
    return f"fen {case.base_fen} moves {' '.join(moves)}"


def _is_legal_repetition_move(case: RepetitionCase, moves: Sequence[str], move: str) -> bool:
    """Return whether a non-null bestmove is legal after the supplied history."""
    import chess

    if move == "0000":
        return False
    board = chess.Board(case.base_fen)
    for history_move in moves:
        board.push_uci(history_move)
    try:
        return chess.Move.from_uci(move) in board.legal_moves
    except ValueError:
        return False


def _run_repetition_checks(
    engine: FPGAUCISession,
    depth: int,
    startup_timeout: float,
    search_timeout: float,
) -> list[tuple[RepetitionCase, str]]:
    """Test direct repetition detection separately from draw-move policy."""
    failures: list[tuple[RepetitionCase, str]] = []
    for case in REPETITION_CASES:
        # First prove that the same child changes from playable at occurrence
        # two to an immediate draw at occurrence three, with its TT entry warm.
        engine.new_game(startup_timeout)
        twofold_nodes, twofold_move, _, twofold_score = _search_position(
            engine,
            _repetition_position(case, case.cycle_moves),
            f"go depth {depth}",
            search_timeout,
        )
        threefold_nodes, threefold_move, _, threefold_score = _search_position(
            engine,
            _repetition_position(case, case.final_child_moves),
            f"go depth {depth}",
            search_timeout,
        )
        direct_searches = (
            f"twofold={twofold_move} score={twofold_score} nodes={twofold_nodes}, "
            f"threefold={threefold_move} score={threefold_score} nodes={threefold_nodes}"
        )
        if twofold_move == "0000":
            failures.append((case, f"{direct_searches}, twofold child was incorrectly terminal"))
        elif not _is_legal_repetition_move(case, case.cycle_moves, twofold_move):
            failures.append((case, f"{direct_searches}, twofold child returned illegal move {twofold_move}"))
        if threefold_move != "0000" or threefold_score != "cp 0":
            failures.append((case, f"{direct_searches}, threefold child did not return a terminal draw"))

        # Then test whether search chooses or avoids the now-proven draw based
        # on the fixture's policy, preserving TT state only within this phase.
        engine.new_game(startup_timeout)
        primed_nodes, primed_move, _, primed_score = _search_position(
            engine,
            _repetition_position(case, case.moves_to_candidate_root),
            f"go depth {depth}",
            search_timeout,
        )
        # Reload the longer history without New Game so TT and move-ordering state remain warm.
        actual_nodes, actual_move, _, actual_score = _search_position(
            engine,
            _repetition_position(case, case.final_moves),
            f"go depth {depth}",
            search_timeout,
        )
        chose_draw = actual_move == case.draw_move
        searches = (
            f"prime={primed_move} score={primed_score} nodes={primed_nodes}, "
            f"final={actual_move} score={actual_score} nodes={actual_nodes}"
        )
        if primed_move == "0000":
            detail = f"{searches}, priming search returned null move"
        elif not _is_legal_repetition_move(case, case.moves_to_candidate_root, primed_move):
            detail = f"{searches}, priming search returned illegal move {primed_move}"
        elif actual_move == "0000":
            detail = f"{searches}, final search returned null move"
        elif not _is_legal_repetition_move(case, case.final_moves, actual_move):
            detail = f"{searches}, final search returned illegal move {actual_move}"
        elif chose_draw != case.should_choose_draw:
            expectation = (
                f"play drawing move {case.draw_move}"
                if case.should_choose_draw
                else f"avoid drawing move {case.draw_move}"
            )
            detail = f"{searches}, expected to {expectation}"
        else:
            continue
        failures.append((case, detail))
    return failures


def run_sanity(depth: int, startup_timeout: float, search_timeout: float, verbose: bool, port: str | None = None) -> int:
    """Exercise the checked-in FPGA UCI host and its connected hardware."""
    timing_failures: list[str] = []
    with FPGAUCISession(port=port, verbose=verbose) as engine:
        engine.initialize(startup_timeout)
        for case in SANITY_POSITIONS:
            # Isolate timing cases while fixed-depth determinism awaits a UCI
            # capability query that can confirm a single search thread.
            engine.new_game(startup_timeout)
            _, _, elapsed_seconds = _search(engine, case.fen, f"go movetime {SANITY_MOVETIME_MS}", search_timeout)
            elapsed_ms = elapsed_seconds * 1000
            if abs(elapsed_ms - SANITY_MOVETIME_MS) > SANITY_MOVETIME_TOLERANCE_MS:
                timing_failures.append(
                    f"{case.name}: {elapsed_ms:.1f} ms "
                    f"(expected {SANITY_MOVETIME_MS} +/- {SANITY_MOVETIME_TOLERANCE_MS} ms)"
                )
        repetition_failures = _run_repetition_checks(
            engine,
            max(depth, SANITY_REPETITION_DEPTH),
            startup_timeout,
            search_timeout,
        )
    for failure in timing_failures:
        print(f"FAIL movetime {failure}")
    for case, detail in repetition_failures:
        print(f"FAIL repetition {case.name}: {detail}")
    timing_passes = len(SANITY_POSITIONS) - len(timing_failures)
    repetition_failure_names = {case.name for case, _ in repetition_failures}
    winning_cases = [case for case in REPETITION_CASES if not case.should_choose_draw]
    losing_cases = [case for case in REPETITION_CASES if case.should_choose_draw]
    winning_passes = sum(case.name not in repetition_failure_names for case in winning_cases)
    losing_passes = sum(case.name not in repetition_failure_names for case in losing_cases)
    print(
        f"sanity: movetime {timing_passes}/{len(SANITY_POSITIONS)} passed; "
        f"repetition avoid {winning_passes}/{len(winning_cases)} passed; "
        f"repetition take {losing_passes}/{len(losing_cases)} passed; "
        "reset determinism disabled"
    )
    return 1 if timing_failures or repetition_failures else 0


def run_perft(startup_timeout: float, search_timeout: float, verbose: bool, port: str | None = None) -> int:
    failures = 0
    with FPGAUCISession(port=port, verbose=verbose) as engine:
        engine.initialize(startup_timeout)
        for case in FAST_PERFT:
            engine.send("position fen " + case.fen)
            engine.send(f"go perft {case.depth}")
            result = engine.wait_for(lambda line: line.lower().startswith("nodes searched:"), search_timeout, f"perft {case.name}")
            actual = None
            for line in result.lines:
                match = PERFT_RE.search(line)
                if match:
                    actual = int(match.group(1))
            passed = actual == case.nodes
            if not passed:
                print(f"FAIL {case.name}: got {actual}, expected {case.nodes}")
            failures += not passed
    print(f"perft: {len(FAST_PERFT) - failures}/{len(FAST_PERFT)} passed")
    return 1 if failures else 0


def _add_common(parser: argparse.ArgumentParser) -> None:
    parser.add_argument("--port", help="Serial port, for example COM5 or /dev/ttyUSB0. Defaults to FPGA_CHESS_PORT or USB UART auto-detection.")
    parser.add_argument("--startup-timeout", type=float, default=10.0)
    parser.add_argument("--search-timeout", type=float, default=120.0)
    parser.add_argument("--verbose", action="store_true")


def main(argv: Sequence[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    sub = parser.add_subparsers(dest="suite", required=True)

    sanity = sub.add_parser("sanity")
    sanity.add_argument("--depth", type=int, default=SANITY_DEPTH)
    _add_common(sanity)

    perft = sub.add_parser("perft")
    perft.add_argument("--profile", choices=["fast"], default="fast")
    perft.add_argument("--list", action="store_true", help="Print named FEN/depth/node cases without contacting the FPGA.")
    _add_common(perft)

    all_suite = sub.add_parser("all")
    all_suite.add_argument("--depth", type=int, default=SANITY_DEPTH)
    _add_common(all_suite)
    args = parser.parse_args(argv)
    if args.startup_timeout <= 0 or args.search_timeout <= 0:
        parser.error("timeouts must be positive")
    try:
        if args.suite == "sanity": return run_sanity(args.depth, args.startup_timeout, args.search_timeout, args.verbose, args.port)
        if args.suite == "perft":
            if args.list:
                for case in FAST_PERFT:
                    print(f"{case.name}: FEN={case.fen}; depth={case.depth}; nodes={case.nodes}")
                return 0
            return run_perft(args.startup_timeout, args.search_timeout, args.verbose, args.port)
        sanity_status = run_sanity(args.depth, args.startup_timeout, args.search_timeout, args.verbose, args.port)
        perft_status = run_perft(args.startup_timeout, args.search_timeout, args.verbose, args.port)
        return 1 if sanity_status or perft_status else 0
    except (OSError, FPGAUCIError, ValueError) as exc:
        print(f"error: {exc}", file=sys.stderr)
        return 2


if __name__ == "__main__":
    raise SystemExit(main())
