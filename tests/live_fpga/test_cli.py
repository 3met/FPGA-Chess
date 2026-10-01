import contextlib
import importlib.util
import io
import unittest
from unittest.mock import MagicMock, patch

from tests.live_fpga.positions import (
    FIFTY_MOVE_CASES,
    PERFT_POSITIONS,
    REPETITION_CASES,
    SANITY_POSITIONS,
)
from tests.live_fpga.cli import (
    SANITY_DEPTH,
    SANITY_FIFTY_MOVE_TIME_MS,
    SANITY_MOVETIME_MS,
    SANITY_MOVETIME_TOLERANCE_MS,
    SANITY_REPETITION_DEPTH,
    _is_legal_repetition_move,
    _run_fifty_move_checks,
    _repetition_position,
    _run_repetition_checks,
    _uci_score,
    main,
    run_sanity,
)
from software.engine.protocol import encode_fen
from software.engine.uci_commands import DEFAULT_MOVE_OVERHEAD_MS


class LiveFPGAPositionTests(unittest.TestCase):
    def test_perft_positions_are_valid_and_unique(self):
        self.assertTrue(PERFT_POSITIONS)
        self.assertEqual(len({case.name for case in PERFT_POSITIONS}), len(PERFT_POSITIONS))
        self.assertEqual(
            len({(case.fen, case.depth) for case in PERFT_POSITIONS}),
            len(PERFT_POSITIONS),
        )
        for case in PERFT_POSITIONS:
            with self.subTest(case=case.name):
                self.assertTrue(case.name)
                self.assertEqual(len(encode_fen(case.fen)), 36)
                self.assertGreaterEqual(case.depth, 0)
                self.assertGreaterEqual(case.nodes, 0)

    @unittest.skipUnless(importlib.util.find_spec("chess"), "python-chess is required for position validation")
    def test_perft_positions_are_legal_standard_chess_positions(self):
        import chess

        for case in PERFT_POSITIONS:
            with self.subTest(case=case.name):
                board = chess.Board(case.fen)
                self.assertTrue(board.is_valid(), f"invalid position status: {board.status()}")

    def test_sanity_positions_are_complete_and_unique(self):
        self.assertTrue(SANITY_POSITIONS)
        self.assertEqual(len({case.name for case in SANITY_POSITIONS}), len(SANITY_POSITIONS))
        self.assertEqual(len({case.fen for case in SANITY_POSITIONS}), len(SANITY_POSITIONS))
        for case in SANITY_POSITIONS:
            self.assertTrue(case.name)
            self.assertEqual(len(case.fen.split()), 6)
            self.assertEqual(len(encode_fen(case.fen)), 36)

    @unittest.skipUnless(importlib.util.find_spec("chess"), "python-chess is required for position validation")
    def test_fifty_move_positions_and_expected_moves_are_legal(self):
        import chess

        self.assertEqual(len({case.name for case in FIFTY_MOVE_CASES}), len(FIFTY_MOVE_CASES))
        self.assertEqual(len({case.fen for case in FIFTY_MOVE_CASES}), len(FIFTY_MOVE_CASES))
        for case in FIFTY_MOVE_CASES:
            with self.subTest(case=case.name):
                board = chess.Board(case.fen)
                self.assertTrue(board.is_valid(), f"invalid position status: {board.status()}")
                self.assertEqual(len(encode_fen(case.fen)), 36)
                self.assertLess(board.halfmove_clock, 100)
                self.assertTrue(case.expected_score)
                self.assertFalse(case.required_move and case.forbidden_move)
                for move in (case.required_move, case.forbidden_move):
                    if move is not None:
                        self.assertIn(chess.Move.from_uci(move), board.legal_moves)

    def test_uci_score_uses_the_last_cp_or_mate_score(self):
        self.assertEqual(_uci_score(["info depth 1 score cp -12", "info depth 2 score cp 34 nodes 8"]), "cp 34")
        self.assertEqual(_uci_score(["info depth 6 score mate -2 nodes 42"]), "mate -2")
        self.assertIsNone(_uci_score(["bestmove e2e4"]))

    @unittest.skipUnless(importlib.util.find_spec("chess"), "python-chess is required for repetition validation")
    def test_repetition_cases_have_one_threefold_move_and_balanced_outcomes(self):
        import chess

        self.assertTrue(REPETITION_CASES)
        self.assertTrue(any(case.should_choose_draw for case in REPETITION_CASES))
        self.assertTrue(any(not case.should_choose_draw for case in REPETITION_CASES))
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
                self.assertTrue(prime.is_valid(), "repetition base position must be legal")
                for move in case.moves_to_candidate_root:
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
                self.assertEqual(case.cycle_moves, case.moves_to_candidate_root + case.draw_line)
                self.assertEqual(case.final_child_moves, case.final_moves + case.draw_line)

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
        expected_seconds = (SANITY_MOVETIME_MS - DEFAULT_MOVE_OVERHEAD_MS) / 1000

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
            return 100 + len(calls), "e2e4", expected_seconds

        with patch("tests.live_fpga.cli.FPGAUCISession", return_value=engine), \
                patch("tests.live_fpga.cli._search", side_effect=search), \
                patch("tests.live_fpga.cli._run_repetition_checks", return_value=[]) as repetition, \
                patch("tests.live_fpga.cli._run_fifty_move_checks", return_value=[]) as fifty_move, \
                contextlib.redirect_stdout(io.StringIO()) as output:
            status = run_sanity(SANITY_DEPTH, 10.0, 120.0, False)

        self.assertEqual(status, 0)
        self.assertEqual(engine.initialize_calls, [10.0])
        self.assertEqual(engine.new_game_calls, [10.0] * len(SANITY_POSITIONS))
        self.assertEqual(len(calls), len(SANITY_POSITIONS))
        repetition.assert_called_once_with(engine, SANITY_REPETITION_DEPTH, 10.0, 120.0)
        fifty_move.assert_called_once_with(engine, SANITY_FIFTY_MOVE_TIME_MS, 10.0, 120.0)
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

    def test_sanity_rejects_search_outside_movetime_tolerance(self):
        engine = MagicMock()
        engine.__enter__.return_value = engine
        expected_ms = SANITY_MOVETIME_MS - DEFAULT_MOVE_OVERHEAD_MS
        late_ms = expected_ms + SANITY_MOVETIME_TOLERANCE_MS + 1
        results = [
            (100 + case_index, "e2e4", (late_ms if case_index == 0 else expected_ms) / 1000)
            for case_index in range(len(SANITY_POSITIONS))
        ]
        output = io.StringIO()

        with patch("tests.live_fpga.cli.FPGAUCISession", return_value=engine), \
                patch("tests.live_fpga.cli._search", side_effect=results), \
                patch("tests.live_fpga.cli._run_repetition_checks", return_value=[]), \
                patch("tests.live_fpga.cli._run_fifty_move_checks", return_value=[]), \
                contextlib.redirect_stdout(output):
            status = run_sanity(SANITY_DEPTH, 10.0, 120.0, False)

        self.assertEqual(status, 1)
        self.assertIn(
            f"FAIL movetime {SANITY_POSITIONS[0].name}: {late_ms:.1f} ms "
            f"(expected {expected_ms} +/- {SANITY_MOVETIME_TOLERANCE_MS} ms)",
            output.getvalue(),
        )
        self.assertIn(f"movetime {len(SANITY_POSITIONS) - 1}/{len(SANITY_POSITIONS)} passed", output.getvalue())


class LiveFPGACliTests(unittest.TestCase):
    def test_default_runs_both_suites_and_reports_either_failure(self):
        for sanity_status, perft_status in ((0, 0), (1, 0), (0, 1), (1, 1)):
            with self.subTest(sanity=sanity_status, perft=perft_status), \
                    patch("tests.live_fpga.cli.run_sanity", return_value=sanity_status) as sanity, \
                    patch("tests.live_fpga.cli.run_perft", return_value=perft_status) as perft:
                self.assertEqual(main([]), int(bool(sanity_status or perft_status)))

            sanity.assert_called_once()
            perft.assert_called_once_with(*sanity.call_args.args[1:])

    def test_options_apply_to_both_suites(self):
        with patch("tests.live_fpga.cli.run_sanity", return_value=0) as sanity, \
                patch("tests.live_fpga.cli.run_perft", return_value=0) as perft:
            status = main([
                "--depth", "12", "--port", "COM5", "--startup-timeout", "7",
                "--search-timeout", "45", "--verbose",
            ])

        self.assertEqual(status, 0)
        sanity.assert_called_once_with(12, 7.0, 45.0, True, "COM5")
        perft.assert_called_once_with(7.0, 45.0, True, "COM5")


@unittest.skipUnless(importlib.util.find_spec("chess"), "python-chess is required for move validation")
class FiftyMoveSanityTests(unittest.TestCase):
    @staticmethod
    def _passing_results():
        import chess

        results = []
        for case in FIFTY_MOVE_CASES:
            board = chess.Board(case.fen)
            move = case.required_move or next(
                candidate.uci()
                for candidate in board.legal_moves
                if candidate.uci() != case.forbidden_move
            )
            results.append((100, move, 0.0, case.expected_score))
        return results

    def test_fifty_move_checks_search_each_position(self):
        engine = MagicMock()
        with patch("tests.live_fpga.cli._search_position", side_effect=self._passing_results()) as search:
            failures = _run_fifty_move_checks(engine, SANITY_FIFTY_MOVE_TIME_MS, 10.0, 120.0)

        self.assertEqual(failures, [])
        self.assertEqual(engine.new_game.call_count, len(FIFTY_MOVE_CASES))
        for case, call in zip(FIFTY_MOVE_CASES, search.call_args_list):
            self.assertEqual(call.args, (engine, "fen " + case.fen, f"go movetime {SANITY_FIFTY_MOVE_TIME_MS}", 120.0))

    def test_fifty_move_checks_report_wrong_score_and_move(self):
        results = self._passing_results()
        first = results[0]
        results[0] = (first[0], first[1], first[2], "cp 0")
        last = results[-1]
        results[-1] = (last[0], FIFTY_MOVE_CASES[-1].forbidden_move, last[2], last[3])

        with patch("tests.live_fpga.cli._search_position", side_effect=results):
            failures = _run_fifty_move_checks(MagicMock(), SANITY_FIFTY_MOVE_TIME_MS, 10.0, 120.0)

        self.assertEqual([case for case, _ in failures], [FIFTY_MOVE_CASES[0], FIFTY_MOVE_CASES[-1]])
        self.assertIn("expected score", failures[0][1])
        self.assertIn("must avoid", failures[1][1])


@unittest.skipUnless(importlib.util.find_spec("chess"), "python-chess is required for repetition validation")
class RepetitionSanityTests(unittest.TestCase):
    @staticmethod
    def _legal_move(case, moves, excluded=()):
        import chess

        board = chess.Board(case.base_fen)
        for move in moves:
            board.push_uci(move)
        return next(move.uci() for move in board.legal_moves if move.uci() not in excluded)

    def _passing_results(self):
        results = []
        for case in REPETITION_CASES:
            twofold_move = self._legal_move(case, case.cycle_moves)
            primed_move = self._legal_move(case, case.moves_to_candidate_root)
            final_move = case.draw_move
            if not case.should_choose_draw:
                final_move = self._legal_move(case, case.final_moves, (case.draw_move,))
            results.extend([
                (100, twofold_move, 0.0, "cp 20"),
                (0, "0000", 0.0, "cp 0"),
                (100, primed_move, 0.0, "cp 20"),
                (100, final_move, 0.0, "cp 0"),
            ])
        return results

    def test_repetition_checks_detection_and_policy_separately(self):
        engine = MagicMock()

        with patch("tests.live_fpga.cli._search_position", side_effect=self._passing_results()) as search:
            failures = _run_repetition_checks(engine, SANITY_REPETITION_DEPTH, 10.0, 120.0)

        self.assertEqual(failures, [])
        self.assertEqual(engine.new_game.call_count, 2 * len(REPETITION_CASES))
        self.assertEqual(search.call_count, 4 * len(REPETITION_CASES))
        for index, case in enumerate(REPETITION_CASES):
            twofold_call, threefold_call, prime_call, final_call = search.call_args_list[index * 4:index * 4 + 4]
            self.assertEqual(twofold_call.args[1], _repetition_position(case, case.cycle_moves))
            self.assertEqual(threefold_call.args[1], _repetition_position(case, case.final_child_moves))
            self.assertEqual(prime_call.args[1], _repetition_position(case, case.moves_to_candidate_root))
            self.assertEqual(final_call.args[1], _repetition_position(case, case.final_moves))
            for call in (twofold_call, threefold_call, prime_call, final_call):
                self.assertEqual(call.args[2:], (f"go depth {SANITY_REPETITION_DEPTH}", 120.0))

    def test_repetition_move_legality_uses_the_historical_position(self):
        case = REPETITION_CASES[0]
        move = self._legal_move(case, case.final_moves)

        self.assertTrue(_is_legal_repetition_move(case, case.final_moves, move))
        self.assertFalse(_is_legal_repetition_move(case, case.final_moves, "0000"))
        self.assertFalse(_is_legal_repetition_move(case, case.final_moves, "e2e5"))

    def test_repetition_checks_report_an_illegal_bestmove(self):
        case = REPETITION_CASES[0]
        results = self._passing_results()[:4]
        results[-1] = (100, "e2e5", 0.0, "cp 0")

        with patch("tests.live_fpga.cli.REPETITION_CASES", (case,)), \
                patch("tests.live_fpga.cli._search_position", side_effect=results):
            failures = _run_repetition_checks(MagicMock(), SANITY_REPETITION_DEPTH, 10.0, 120.0)

        self.assertEqual(len(failures), 1)
        self.assertIn("final search returned illegal move e2e5", failures[0][1])

    def test_repetition_checks_report_the_wrong_policy(self):
        case = REPETITION_CASES[0]
        results = self._passing_results()[:4]
        results[-1] = (100, case.draw_move, 0.0, "cp 0")

        with patch("tests.live_fpga.cli.REPETITION_CASES", (case,)), \
                patch("tests.live_fpga.cli._search_position", side_effect=results):
            failures = _run_repetition_checks(MagicMock(), SANITY_REPETITION_DEPTH, 10.0, 120.0)

        self.assertEqual(len(failures), 1)
        self.assertEqual(failures[0][0], case)
        self.assertIn(f"final={case.draw_move} score=cp 0 nodes=100", failures[0][1])
        self.assertIn("expected to avoid drawing move", failures[0][1])


if __name__ == "__main__":
    unittest.main()
