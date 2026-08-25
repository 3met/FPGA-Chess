import unittest

from hardware.scripts import generate_zobrist_values as zobrist


class ZobristGenerationTests(unittest.TestCase):
    def test_table_layout_and_disabled_pawn_squares(self):
        turn_value, side_values, tile_values = zobrist.build_values()

        self.assertEqual(zobrist.SEED, "0")
        self.assertEqual(len(side_values), 12)
        self.assertEqual(len(tile_values), 2 * 6 * 64)
        self.assertNotEqual(turn_value, 0)

        expected_zero_indices = {
            color * 6 * 64 + pawn_rank * 8 + file_idx
            for color in range(2)
            for pawn_rank in (0, 7)
            for file_idx in range(8)
        }
        found_zero_indices = {
            index for index, value in enumerate(tile_values) if value == 0
        }
        self.assertEqual(found_zero_indices, expected_zero_indices)

    def test_checked_values_match_tracked_outputs(self):
        turn_value, side_values, tile_values = zobrist.build_values()

        summary = zobrist.validate_values(turn_value, side_values, tile_values)
        self.assertIn("nonzero=749", summary)
        self.assertIn("unique_pair_deltas=280126", summary)
        self.assertEqual(
            zobrist.TILE_OUT_FILE.read_text(encoding="ascii"),
            "".join(f"{value:016X}\n" for value in tile_values),
        )
        self.assertEqual(
            zobrist.EP_OUT_FILE.read_text(encoding="ascii"),
            "".join(f"{value:016X}\n" for value in side_values[4:]),
        )
        self.assertEqual(
            zobrist.SV_OUT_FILE.read_text(encoding="ascii"),
            zobrist.render_sv_package(turn_value, side_values[:4]),
        )


if __name__ == "__main__":
    unittest.main()
