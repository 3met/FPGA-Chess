
# By Emet Behrendt

# Converts a JSON piece-square table to a hex file suitable for FPGA initialization

import json
from pathlib import Path

PST_WORD_BITS = 16 # ENSURE THIS IS CORRECT!!!!

PST_JSON_PATH = Path(__file__).parent.parent / "hardware" / "data" / "pst_values" / "pst_values.json"
PST_HEX_PATH  = Path(__file__).parent.parent / "hardware" / "data" / "pst_values" / "pst_values.hex"
PST_MIF_PATH  = Path(__file__).parent.parent / "hardware" / "data" / "pst_values" / "pst_values.mif"

# Writes a HEX file
def pst_to_hex(json_path, out_path, word_bits=PST_WORD_BITS):
    with open(json_path) as f:
        data = json.load(f)

    pst = data["pst"]
    mem = [0] * (6 * 64)  # 8 pieces × 64 squares

    PIECE_ORDER = ["pawn", "knight", "bishop", "rook", "queen", "king"]

    for piece_idx, piece in enumerate(PIECE_ORDER):
        table = pst[piece]
        for sq in range(64):
            addr = (piece_idx << 6) | sq
            mem[addr] = table[sq]

    hex_digits = (word_bits + 3) // 4
    with open(out_path, "w") as f:
        for word in mem:
            f.write(f"{word & ((1 << word_bits)-1):0{hex_digits}X}\n")


# Writes a Memory Initialization File (MIF)
def pst_to_mif(json_path, out_path, word_bits=PST_WORD_BITS):
    with open(json_path) as f:
        data = json.load(f)

    pst = data["pst"]
    mem = [0] * (6 * 64)  # 8 pieces × 64 squares

    PIECE_ORDER = ["pawn", "knight", "bishop", "rook", "queen", "king"]

    for piece_idx, piece in enumerate(PIECE_ORDER):
        table = pst[piece]
        for sq in range(64):
            addr = (piece_idx << 6) | sq
            mem[addr] = table[sq]

    hex_digits = (word_bits + 3) // 4
    with open(out_path, "w") as f:
        f.write(f"DEPTH = {len(mem)};\n")
        f.write(f"WIDTH = {word_bits};\n")
        f.write("ADDRESS_RADIX = HEX;\n")
        f.write("DATA_RADIX = HEX;\n")
        f.write("CONTENT BEGIN\n")
        for addr, word in enumerate(mem):
            f.write(f"{addr:02X} : {word & ((1 << word_bits)-1):0{hex_digits}X};\n")
        f.write("END;\n")


# Run the conversion when this script is executed
if __name__ == "__main__":
    pst_to_hex(PST_JSON_PATH, PST_HEX_PATH)
    print(f"Wrote PST HEX to {PST_HEX_PATH}")
    pst_to_mif(PST_JSON_PATH, PST_MIF_PATH)
    print(f"Wrote PST MIF to {PST_MIF_PATH}")
