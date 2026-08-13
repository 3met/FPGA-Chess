"""Generate deterministic zero-correction NNUE memories."""

from pathlib import Path


ROOT = Path(__file__).resolve().parents[2]
DATA = ROOT / "hardware/data/nnue"
ACCUMULATOR_COUNT = 256
FEATURE_COUNT = 2 * 6 * 64
FEATURE_ROW_BYTES = ACCUMULATOR_COUNT * 2 // 8
OUTPUT_MAC_LANES = 128
OUTPUT_WEIGHT_BITS = 3
OUTPUT_ROWS = 2 * ACCUMULATOR_COUNT // OUTPUT_MAC_LANES
OUTPUT_BUCKETS = 8
OUTPUT_ROW_HEX_DIGITS = (OUTPUT_MAC_LANES * OUTPUT_WEIGHT_BITS + 3) // 4


def has_geometry(path: Path, expected_lines: list[str]) -> bool:
    """Check row count, width, and hexadecimal encoding without changing a trained image."""
    if not path.exists():
        return False
    lines = path.read_text(encoding="ascii").splitlines()
    return (
        len(lines) == len(expected_lines)
        and all(len(line) == len(expected_lines[0]) for line in lines)
        and all(all(character in "0123456789abcdefABCDEF" for character in line) for line in lines)
    )


def main() -> None:
    """Create legal empty memories without overwriting an exported trained model."""
    DATA.mkdir(parents=True, exist_ok=True)
    defaults = {
        "feature_transformer.hex": ("00" * FEATURE_ROW_BYTES + "\n") * FEATURE_COUNT,
        "output_weights.hex": ("0" * OUTPUT_ROW_HEX_DIGITS + "\n")
        * OUTPUT_ROWS * OUTPUT_BUCKETS,
        "output_bias.hex": "00\n" * OUTPUT_BUCKETS,
        "accumulator_bias.hex": "0\n" * ACCUMULATOR_COUNT,
    }
    for name, contents in defaults.items():
        path = DATA / name
        # Replace only an image whose geometry is obsolete, preserving a
        # trained image when its current architecture layout already matches.
        expected_lines = contents.splitlines()
        if not has_geometry(path, expected_lines):
            path.write_text(contents, encoding="ascii")


if __name__ == "__main__":
    main()
