import contextlib
import importlib.util
import io
import tempfile
import unittest
from pathlib import Path
from unittest.mock import MagicMock, patch

from software.benchmarks.positions import PERFT_POSITIONS, REPETITION_CASES, SANITY_POSITIONS
from software.benchmarks.cli import (
    SANITY_DEPTH,
    SANITY_MOVETIME_MS,
    SANITY_MOVETIME_TOLERANCE_MS,
    SANITY_REPETITION_DEPTH,
    Puzzle,
    _repetition_position,
    _run_repetition_checks,
    _uci_score,
    estimate_rating,
    load_puzzles,
    main,
    run_rate,
    run_sanity,
)
from software.benchmarks.session import FPGAUCISession
from software.engine.protocol import encode_fen


class BenchmarkPositionTests(unittest.TestCase):
    def test_each_position_has_complete_expected_data(self):
        self.assertGreaterEqual(len(PERFT_POSITIONS), 5)
        for case in PERFT_POSITIONS:
            self.assertTrue(case.name)
            self.assertIn(len(case.fen.split()), (4, 6))
            self.assertGreaterEqual(case.depth, 0)
            self.assertGreaterEqual(case.nodes, 0)

    def test_sanity_positions_are_complete_and_unique(self):
        self.assertEqual(len(SANITY_POSITIONS), 16)
        self.assertEqual(len({case.name for case in SANITY_POSITIONS}), len(SANITY_POSITIONS))
        self.assertEqual(len({case.fen for case in SANITY_POSITIONS}), len(SANITY_POSITIONS))
        for case in SANITY_POSITIONS:
            self.assertTrue(case.name)
            self.assertEqual(len(case.fen.split()), 6)
            self.assertEqual(len(encode_fen(case.fen)), 36)

    def test_sanity_search_parameters(self):
        self.assertEqual(SANITY_DEPTH, 6)
        self.assertEqual(SANITY_REPETITION_DEPTH, 8)
        self.assertEqual(SANITY_MOVETIME_MS, 250)
        self.assertEqual(SANITY_MOVETIME_TOLERANCE_MS, 5)

    def test_uci_score_uses_the_last_cp_or_mate_score(self):
        self.assertEqual(_uci_score(["info depth 1 score cp -12", "info depth 2 score cp 34 nodes 8"]), "cp 34")
        self.assertEqual(_uci_score(["info depth 6 score mate -2 nodes 42"]), "mate -2")
        self.assertIsNone(_uci_score(["bestmove e2e4"]))

    @unittest.skipUnless(importlib.util.find_spec("chess"), "python-chess is required for repetition validation")
    def test_repetition_cases_have_one_threefold_move_and_balanced_outcomes(self):
        import chess

        self.assertEqual(len(REPETITION_CASES), 10)
        self.assertEqual(sum(case.should_choose_draw for case in REPETITION_CASES), 5)
        self.assertEqual(len({case.name for case in REPETITION_CASES}), len(REPETITION_CASES))
        piece_values = {
            chess.PAWN: 1,
            chess.KNIGHT: 3,
            chess.BISHOP: 3,
            chess.ROOK: 5,
            chess.QUEEN: 9,
            chess.KING: 0,
        }

        for case in REPETITION_CASES:
            with self.subTest(case=case.name):
                self.assertEqual(len(encode_fen(case.base_fen)), 36)
                prime = chess.Board(case.base_fen)
                for move in case.return_moves:
                    prime.push_uci(move)
                primed_child = prime.copy()
                for move in case.draw_line:
                    primed_child.push_uci(move)
                self.assertTrue(primed_child.is_repetition(2))
                self.assertFalse(primed_child.is_repetition(3))

                final = chess.Board(case.base_fen)
                for move in case.final_moves:
                    final.push_uci(move)
                self.assertEqual(prime.fen().split()[:4], final.fen().split()[:4])
                self.assertGreater(final.halfmove_clock, 4)
                self.assertFalse(final.is_repetition(3))
                drawing_child = final.copy()
                for move in case.draw_line:
                    drawing_child.push_uci(move)
                self.assertTrue(drawing_child.is_repetition(3))

                material = sum(
                    (1 if piece.color == final.turn else -1) * piece_values[piece.piece_type]
                    for piece in final.piece_map().values()
                )
                # Synthetic cases use an overwhelming material edge; real-game
                # regressions include positional and tactical winning advantages.
                if not case.name.startswith("lichess-"):
                    self.assertEqual(material < 0, case.should_choose_draw)


class SanitySuiteTests(unittest.TestCase):
    def test_sanity_resets_before_each_movetime_search(self):
        calls = []
        events = []

        class Engine:
            def __init__(self, **_kwargs):
                self.initialize_calls = []
                self.new_game_calls = []

            def __enter__(self):
                return self

            def __exit__(self, *_args):
                return False

            def initialize(self, timeout):
                self.initialize_calls.append(timeout)
                events.append(("initialize", timeout))

            def new_game(self, timeout):
                self.new_game_calls.append(timeout)
                events.append(("new_game", timeout))

        engine = Engine()

        def search(_engine, fen, go, timeout):
            calls.append((fen, go, timeout))
            events.append(("search", fen, go, timeout))
            return 100 + len(calls), "e2e4", 0.250

        with patch("software.benchmarks.cli.FPGAUCISession", return_value=engine), \
                patch("software.benchmarks.cli._search", side_effect=search), \
                patch("software.benchmarks.cli._run_repetition_checks", return_value=[]) as repetition, \
                contextlib.redirect_stdout(io.StringIO()) as output:
            status = run_sanity(SANITY_DEPTH, 10.0, 120.0, False)

        self.assertEqual(status, 0)
        self.assertEqual(engine.initialize_calls, [10.0])
        self.assertEqual(engine.new_game_calls, [10.0] * len(SANITY_POSITIONS))
        self.assertEqual(len(calls), len(SANITY_POSITIONS))
        repetition.assert_called_once_with(engine, SANITY_REPETITION_DEPTH, 10.0, 120.0)
        self.assertEqual(events[0], ("initialize", 10.0))
        for index, case in enumerate(SANITY_POSITIONS):
            timed = calls[index]
            self.assertEqual(timed, (case.fen, f"go movetime {SANITY_MOVETIME_MS}", 120.0))
            self.assertEqual(
                events[1 + index * 2:1 + index * 2 + 2],
                [
                    ("new_game", 10.0),
                    ("search", *timed),
                ],
            )
        self.assertIn("reset determinism disabled", output.getvalue())

    def test_sanity_cli_uses_depth_six_by_default(self):
        with patch("software.benchmarks.cli.run_sanity", return_value=0) as sanity:
            self.assertEqual(main(["sanity"]), 0)

        sanity.assert_called_once_with(SANITY_DEPTH, 10.0, 120.0, False, None)

    def test_sanity_rejects_search_outside_movetime_tolerance(self):
        engine = MagicMock()
        engine.__enter__.return_value = engine
        results = [
            (100 + case_index, "e2e4", 0.256 if case_index == 0 else 0.250)
            for case_index in range(len(SANITY_POSITIONS))
        ]
        output = io.StringIO()

        with patch("software.benchmarks.cli.FPGAUCISession", return_value=engine), \
                patch("software.benchmarks.cli._search", side_effect=results), \
                patch("software.benchmarks.cli._run_repetition_checks", return_value=[]), \
                contextlib.redirect_stdout(output):
            status = run_sanity(SANITY_DEPTH, 10.0, 120.0, False)

        self.assertEqual(status, 1)
        self.assertIn("FAIL movetime open-game: 256.0 ms (expected 250 +/- 5 ms)", output.getvalue())
        self.assertIn("movetime 15/16 passed", output.getvalue())


class RepetitionSanityTests(unittest.TestCase):
    def test_repetition_checks_prime_and_reload_every_case(self):
        engine = MagicMock()
        results = []
        for case in REPETITION_CASES:
            results.extend([
                (100, case.draw_move, 0.0, "cp 20"),
                (100, case.draw_move if case.should_choose_draw else "b1b2", 0.0, "cp 0"),
            ])

        with patch("software.benchmarks.cli._search_position", side_effect=results) as search:
            failures = _run_repetition_checks(engine, SANITY_REPETITION_DEPTH, 10.0, 120.0)

        self.assertEqual(failures, [])
        self.assertEqual(engine.new_game.call_count, len(REPETITION_CASES))
        self.assertEqual(search.call_count, 2 * len(REPETITION_CASES))
        for index, case in enumerate(REPETITION_CASES):
            prime_call, final_call = search.call_args_list[index * 2:index * 2 + 2]
            self.assertEqual(prime_call.args[1], _repetition_position(case, case.return_moves))
            self.assertEqual(final_call.args[1], _repetition_position(case, case.final_moves))
            self.assertEqual(prime_call.args[2:], (f"go depth {SANITY_REPETITION_DEPTH}", 120.0))
            self.assertEqual(final_call.args[2:], (f"go depth {SANITY_REPETITION_DEPTH}", 120.0))

    def test_repetition_checks_report_the_wrong_policy(self):
        engine = MagicMock()
        results = []
        for index, case in enumerate(REPETITION_CASES):
            final_move = case.draw_move if case.should_choose_draw else "b1b2"
            if index == 0:
                final_move = case.draw_move
            results.extend([(100, case.draw_move, 0.0, "cp -120"), (100, final_move, 0.0, "cp 0")])

        with patch("software.benchmarks.cli._search_position", side_effect=results):
            failures = _run_repetition_checks(engine, SANITY_REPETITION_DEPTH, 10.0, 120.0)

        self.assertEqual(len(failures), 1)
        self.assertEqual(failures[0][0], REPETITION_CASES[0])
        self.assertIn(
            f"prime={REPETITION_CASES[0].draw_move} score=cp -120 nodes=100, "
            f"final={REPETITION_CASES[0].draw_move} score=cp 0 nodes=100",
            failures[0][1],
        )
        self.assertIn("expected to avoid drawing move", failures[0][1])


class PuzzleAndRatingTests(unittest.TestCase):
    def test_rate_cli_forwards_an_explicit_port(self):
        with patch("software.benchmarks.cli.run_rate", return_value=0) as rate:
            self.assertEqual(main(["rate", "--port", "/dev/ttyUSB0"]), 0)

        rate.assert_called_once_with(
            Path("puzzles/lichess_db_puzzle.csv"), 100, 0, 100, 1000.0,
            10.0, 120.0, False, "/dev/ttyUSB0",
        )

    def test_session_passes_an_explicit_port_to_the_uci_host(self):
        session = FPGAUCISession(port="COM42")

        self.assertEqual(session.command[-2:], ["--port", "COM42"])

    def test_logistic_rating_and_boundaries(self):
        rating, interval = estimate_rating([(1200, False), (1800, True), (2200, True)])
        self.assertGreater(rating, 1800)
        self.assertIsNotNone(interval)
        self.assertIsNone(estimate_rating([(1500, False)])[1])
        self.assertIsNone(estimate_rating([(1500, True)])[1])

    def test_load_puzzles_is_deterministic(self):
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory) / "puzzles.csv"
            path.write_text("FEN,Moves,Rating\n8/8/8/8/8/8/8/K6k w - - 0 1,a1a2 h1h2,1200\n8/8/8/8/8/8/8/K6k w - - 0 1,a1a2 h1h2,999\ninvalid,x,wat\n", encoding="utf-8")
            puzzles, malformed = load_puzzles(path, 1, 0)
        self.assertEqual(puzzles[0].rating, 1200)
        self.assertEqual(malformed, 1)

    def test_load_puzzles_uses_a_rating_filter_and_cache(self):
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory) / "puzzles.csv"
            path.write_text("FEN,Moves,Rating\n8/8/8/8/8/8/8/K6k w - - 0 1,a1a2 h1h2,1000\n8/8/8/8/8/8/8/K6k w - - 0 1,a1a2 h1h2,1200\n", encoding="utf-8")
            first, _ = load_puzzles(path, 2, 7, 1000)
            second, _ = load_puzzles(path, 2, 7, 1000)
        self.assertEqual(first, second)
        self.assertTrue(all(puzzle.rating >= 1000 for puzzle in first))

    def test_rate_resets_the_game_before_each_puzzle(self):
        puzzles = [
            Puzzle("8/8/8/8/8/8/8/K6k w - - 0 1", ("a1a2", "h1h2"), 1200),
            Puzzle("8/8/8/8/8/8/8/K6k w - - 0 1", ("a1a2", "h1h2"), 1400),
        ]

        class Engine:
            instances: list["Engine"] = []

            def __init__(self, **kwargs):
                self.initialize_calls = 0
                self.new_game_calls = 0
                self.port = kwargs.get("port")
                Engine.instances.append(self)

            def __enter__(self):
                return self

            def __exit__(self, *_args):
                return False

            def initialize(self, _timeout):
                self.initialize_calls += 1

            def new_game(self, _timeout):
                self.new_game_calls += 1

        with patch("software.benchmarks.cli.load_puzzles", return_value=(puzzles, 0)), \
                patch("software.benchmarks.cli.FPGAUCISession", Engine), \
                patch("software.benchmarks.cli.solve_puzzle", return_value=True), \
                contextlib.redirect_stdout(io.StringIO()):
            self.assertEqual(run_rate(Path("unused.csv"), 2, 0, 50, 1000, 1.0, 1.0, False, "/dev/ttyUSB0"), 0)

        self.assertEqual(Engine.instances[0].initialize_calls, 1)
        self.assertEqual(Engine.instances[0].new_game_calls, len(puzzles))
        self.assertEqual(Engine.instances[0].port, "/dev/ttyUSB0")


if __name__ == "__main__":
    unittest.main()
