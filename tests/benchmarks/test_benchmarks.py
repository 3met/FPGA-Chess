import contextlib
import io
import tempfile
import unittest
from pathlib import Path
from unittest.mock import patch

from software.benchmarks.positions import PERFT_POSITIONS, SANITY_POSITIONS
from software.benchmarks.cli import Puzzle, estimate_rating, load_puzzles, run_rate


class PerftPositionTests(unittest.TestCase):
    def test_each_position_has_complete_expected_data(self):
        self.assertGreaterEqual(len(PERFT_POSITIONS), 5)
        for case in PERFT_POSITIONS:
            self.assertTrue(case.name)
            self.assertIn(len(case.fen.split()), (4, 6))
            self.assertGreaterEqual(case.depth, 0)
            self.assertGreaterEqual(case.nodes, 0)

    def test_sanity_positions_are_named_midgames(self):
        self.assertEqual(len(SANITY_POSITIONS), 3)
        for case in SANITY_POSITIONS:
            self.assertTrue(case.name)
            self.assertEqual(len(case.fen.split()), 6)


class PuzzleAndRatingTests(unittest.TestCase):
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

            def __init__(self, **_kwargs):
                self.initialize_calls = 0
                self.new_game_calls = 0
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
            self.assertEqual(run_rate(Path("unused.csv"), 2, 0, 50, 1000, 1.0, 1.0, False), 0)

        self.assertEqual(Engine.instances[0].initialize_calls, 1)
        self.assertEqual(Engine.instances[0].new_game_calls, len(puzzles))


if __name__ == "__main__":
    unittest.main()
