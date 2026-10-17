import unittest
from itertools import combinations
from random import Random

from hardware.scripts import generate_zobrist as zobrist


class ZobristGenerationTests(unittest.TestCase):
    @staticmethod
    def _rank(rows):
        """Measure binary span without assuming distinct, independent samples."""
        basis = {}
        for row in rows:
            while row:
                pivot = row.bit_length() - 1
                if pivot in basis:
                    row ^= basis[pivot]
                else:
                    basis[pivot] = row
                    break
            if len(basis) == 64:
                break
        return len(basis)

    def test_table_layout_and_disabled_pawn_squares(self):
        turn_value, side_values, tile_values = zobrist.build_values()

        self.assertEqual(len(side_values), 12)
        self.assertEqual(len(tile_values), 2 * 8 * 64)
        self.assertNotEqual(turn_value, 0)

        expected_zero_indices = {
            ((color << 3) | piece_code) * 64 + pos
            for color in range(2)
            for piece_code in range(8)
            for pos in range(64)
            if piece_code in (0, 7) or (piece_code == 1 and pos // 8 in (0, 7))
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
            zobrist.TILE_REFERENCE_FILE.read_text(encoding="ascii"),
            "".join(f"{value:016X}\n" for value in tile_values),
        )
        self.assertEqual(
            zobrist.EP_REFERENCE_FILE.read_text(encoding="ascii"),
            "".join(f"{value:016X}\n" for value in side_values[4:]),
        )
        self.assertEqual(
            zobrist.RTL_OUT_FILE.read_text(encoding="ascii"),
            zobrist.render_sv_package(turn_value, side_values[:4]),
        )

    def test_full_domain_balance_avalanche_and_rank(self):
        """Reject hidden aliases, biased output bits, and reduced XOR entropy."""
        values = zobrist.hash_features()
        self.assertEqual(len(set(values)), len(values))
        width = (len(values) - 1).bit_length()
        for output_bit in range(64):
            population = sum((value >> output_bit) & 1 for value in values)
            self.assertGreaterEqual(population / len(values), 0.4)
            self.assertLessEqual(population / len(values), 0.6)
            for input_bit in range(width):
                flips = sum(((value ^ values[index ^ (1 << input_bit)]) >> output_bit) & 1
                            for index, value in enumerate(values))
                self.assertGreaterEqual(flips / len(values), 0.4)
                self.assertLessEqual(flips / len(values), 0.6)

        # Cover every address difference, including combinations of input bits.
        for difference in range(1, len(values)):
            flips = sum((value ^ values[index ^ difference]).bit_count()
                        for index, value in enumerate(values))
            self.assertGreaterEqual(flips / (64 * len(values)), 0.4)
            self.assertLessEqual(flips / (64 * len(values)), 0.6)

        turn, side, tiles = zobrist.build_values()
        # Tile keys must span all bits without help from fixed side constants.
        for keys in (values, tiles, [turn, *side, *tiles]):
            self.assertEqual(self._rank(keys), 64)

    def test_coordinate_cubes_do_not_cancel(self):
        """Catch structured higher-order XOR relations missed by pair checks."""
        values = zobrist.hash_features()
        width = (len(values) - 1).bit_length()
        for dimension in range(3, 7):
            for axes in combinations(range(width), dimension):
                mask = sum(1 << axis for axis in axes)
                vertices = [0]
                for axis in axes:
                    vertices += [vertex | (1 << axis) for vertex in vertices]
                for origin in range(len(values)):
                    if origin & mask:
                        continue
                    delta = 0
                    for vertex in vertices:
                        delta ^= values[origin | vertex]
                    self.assertNotEqual(delta, 0, (axes, origin))

    def test_every_input_difference_spans_all_hash_bits(self):
        """Reject exact output parity invariants under any input translation."""
        values = zobrist.hash_features()
        for difference in range(1, len(values)):
            rows = (value ^ values[index ^ difference]
                    for index, value in enumerate(values))
            self.assertEqual(self._rank(rows), 64, f"Input difference {difference}")

    def test_generator_rejects_a_linear_feature_hash(self):
        """Unique addresses alone must not qualify as strong feature keys."""
        with self.assertRaisesRegex(RuntimeError, "spans only"):
            zobrist.validate_feature_hash(list(range(1 << 10)))

    def test_second_differences_span_all_hash_bits(self):
        """Exercise translated rectangles beyond the coordinate-bit axes."""
        values = zobrist.hash_features()
        rng = Random(0)
        for _ in range(4096):
            first, second = rng.sample(range(1, len(values)), 2)
            rows = (value ^ values[index ^ first] ^ values[index ^ second]
                    ^ values[index ^ first ^ second]
                    for index, value in enumerate(values))
            self.assertEqual(self._rank(rows), 64, (first, second))

    def test_third_differences_span_all_hash_bits(self):
        """Cover a previously deficient cube and independent random frames."""
        values = zobrist.hash_features()
        rng = Random(1)
        frames = [(841, 474, 980)]
        for _ in range(512):
            first, second, third = rng.sample(range(1, len(values)), 3)
            if first ^ second != third:
                frames.append((first, second, third))
        for first, second, third in frames:
            rows = (value ^ values[index ^ first] ^ values[index ^ second]
                    ^ values[index ^ third] ^ values[index ^ first ^ second]
                    ^ values[index ^ first ^ third] ^ values[index ^ second ^ third]
                    ^ values[index ^ first ^ second ^ third]
                    for index, value in enumerate(values))
            self.assertEqual(self._rank(rows), 64, (first, second, third))

    @staticmethod
    def _walsh_transform(signs):
        """Compute exact Boolean spectra without floating-point roundoff."""
        spectrum = list(signs)
        half = 1
        while half < len(spectrum):
            for start in range(0, len(spectrum), 2 * half):
                for index in range(start, start + half):
                    left, right = spectrum[index], spectrum[index + half]
                    spectrum[index] = left + right
                    spectrum[index + half] = left - right
            half *= 2
        return spectrum

    @classmethod
    def _walsh_peak(cls, signs):
        """Measure correlation with every affine Boolean input function."""
        return max(abs(value) for value in cls._walsh_transform(signs)) / len(signs)

    def test_each_output_bit_responds_to_every_input_difference(self):
        """Bound differential bias even for changes to several address bits."""
        values = zobrist.hash_features()
        for bit in range(64):
            signs = [1 - 2 * ((value >> bit) & 1) for value in values]
            spectrum = self._walsh_transform(signs)
            # Inverse Walsh of squared spectra gives exact autocorrelation.
            # A normalized magnitude <= 1/4 bounds flip rates to 3/8..5/8.
            autocorrelation = self._walsh_transform([value * value for value in spectrum])
            bias = max(abs(value) for value in autocorrelation[1:]) / len(values) ** 2
            self.assertLessEqual(bias, 0.25, bit)

    def test_output_bits_and_pairs_resist_linear_prediction(self):
        """Bound bias for every input mask, including output-bit correlations."""
        values = zobrist.hash_features()
        columns = [[1 - 2 * ((value >> bit) & 1) for value in values]
                   for bit in range(64)]
        for bit, column in enumerate(columns):
            self.assertLessEqual(self._walsh_peak(column), 0.16, bit)
        for first, second in combinations(range(64), 2):
            parity = [a * b for a, b in zip(columns[first], columns[second])]
            self.assertLessEqual(self._walsh_peak(parity), 0.18, (first, second))

    def test_output_combinations_retain_high_algebraic_degree(self):
        """Reject low-degree relations involving any XOR of output bits."""
        coefficients = zobrist.hash_features()
        width = (len(coefficients) - 1).bit_length()
        # The binary Moebius transform gives all algebraic normal form terms.
        for bit in range(width):
            for mask in range(len(coefficients)):
                if mask & (1 << bit):
                    coefficients[mask] ^= coefficients[mask ^ (1 << bit)]
        self.assertEqual(self._rank(row for mask, row in enumerate(coefficients)
                                    if mask.bit_count() >= 7), 64)


if __name__ == "__main__":
    unittest.main()
