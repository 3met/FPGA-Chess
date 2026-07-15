import tempfile
import unittest
from pathlib import Path

from software.benchmarks.positions import PERFT_POSITIONS, SANITY_POSITIONS
from software.benchmarks.cli import estimate_rating, load_puzzles


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


if __name__ == "__main__":
    unittest.main()
