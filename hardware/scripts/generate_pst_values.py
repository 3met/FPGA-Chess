# By Emet Behrendt

"""Generate the PST readmemh file used by RTL and test benches."""

import json
from pathlib import Path


ROOT = Path(__file__).resolve().parents[2]
PST_WORD_BITS = 16
PST_JSON_PATH = ROOT / "hardware" / "data" / "pst_values" / "pst_values.json"
PST_HEX_PATH = ROOT / "hardware" / "data" / "pst_values" / "pst_values.hex"
PIECE_ORDER = ["pawn", "knight", "bishop", "rook", "queen", "king"]


def load_pst_words(json_path):
    with json_path.open() as f:
        data = json.load(f)

    pst = data["pst"]
    mem = [0] * (len(PIECE_ORDER) * 64)

    for piece_idx, piece in enumerate(PIECE_ORDER):
        table = pst[piece]
        if len(table) != 64:
            raise ValueError(f"PST for {piece} has {len(table)} entries, expected 64")

        for square, value in enumerate(table):
            mem[(piece_idx << 6) | square] = value

    return mem


def write_readmemh(words, out_path, word_bits=PST_WORD_BITS):
    hex_digits = (word_bits + 3) // 4
    mask = (1 << word_bits) - 1

    with out_path.open("w") as f:
        for word in words:
            f.write(f"{word & mask:0{hex_digits}X}\n")


def main():
    words = load_pst_words(PST_JSON_PATH)
    write_readmemh(words, PST_HEX_PATH)
    print(f"Wrote PST HEX to {PST_HEX_PATH}")


if __name__ == "__main__":
    main()
