#!/usr/bin/env python3
"""Generate deterministic, uniformly distributed Zobrist keys for FPGA-Chess."""

from __future__ import annotations

import hashlib
from pathlib import Path
from typing import Iterable


ROOT = Path(__file__).resolve().parents[2]
TILE_OUT_FILE = ROOT / "hardware" / "data" / "zobrist" / "zobrist_tile_values.hex"
EP_OUT_FILE = ROOT / "hardware" / "data" / "zobrist" / "zobrist_ep_values.hex"
SV_OUT_FILE = ROOT / "hardware" / "rtl" / "generated" / "zobrist_values_pkg.sv"
SEED = "0"

COLORS = ("white", "black")
PIECES = ("pawn", "knight", "bishop", "rook", "queen", "king")
CASTLE_NAMES = (
    "white_kingside",
    "white_queenside",
    "black_kingside",
    "black_queenside",
)

# These broad checks catch broken derivation, truncation, and badly biased tables
# without conditioning otherwise uniform SHA-256 output on arbitrary bit patterns.
MIN_KEY_WEIGHT = 16
MAX_KEY_WEIGHT = 48
MIN_PAIRWISE_DISTANCE = 10
MIN_BIT_COUNT = 300
MAX_BIT_COUNT = 450


def derive_key(label: str) -> int:
    """Derive one stable 64-bit key from a domain-separated semantic label."""
    digest = hashlib.sha256(f"{SEED}|{label}".encode("ascii")).digest()
    words = (
        int.from_bytes(digest[offset:offset + 8], "big")
        for offset in range(0, len(digest), 8)
    )
    value = 0
    for word in words:
        value ^= word
    return value


def build_values() -> tuple[int, list[int], list[int]]:
    """Return the turn key, castling/EP keys, and the piece-square table."""
    side_values = [derive_key(f"castle:{name}") for name in CASTLE_NAMES]
    side_values.extend(derive_key(f"ep_file:{file_idx}") for file_idx in range(8))

    tile_values: list[int] = []
    for color in COLORS:
        for piece in PIECES:
            for pos in range(64):
                rank = pos // 8
                # Standard-chess pawns cannot occupy their first or eighth rank.
                tile_values.append(
                    0 if piece == "pawn" and rank in (0, 7)
                    else derive_key(f"tile:{color}:{piece}:{pos}")
                )

    return derive_key("turn:black"), side_values, tile_values


def validate_values(turn_value: int, side_values: list[int], tile_values: list[int]) -> str:
    """Validate table shape, distribution, and low-order XOR independence."""
    if len(side_values) != 12 or len(tile_values) != 2 * 6 * 64:
        raise RuntimeError("Generated Zobrist table has an unexpected shape")

    nonzero_values = [turn_value, *side_values, *(value for value in tile_values if value)]
    if any(value == 0 for value in nonzero_values):
        raise RuntimeError("Generated an enabled zero Zobrist key")
    if len(nonzero_values) != len(set(nonzero_values)):
        raise RuntimeError("Generated duplicate Zobrist keys")

    weights = [value.bit_count() for value in nonzero_values]
    min_distance = 64
    value_set = set(nonzero_values)
    pair_deltas: set[int] = set()
    # A pair delta equal to a key or another pair delta exposes an avoidable
    # three- or four-feature XOR cancellation, respectively.
    for i, value in enumerate(nonzero_values):
        for j in range(i):
            delta = value ^ nonzero_values[j]
            min_distance = min(min_distance, delta.bit_count())
            if delta in value_set:
                raise RuntimeError("Generated a three-key zero-XOR relation")
            if delta in pair_deltas:
                raise RuntimeError("Generated a four-key zero-XOR relation")
            pair_deltas.add(delta)

    bit_counts = [
        sum((value >> bit_idx) & 1 for value in nonzero_values)
        for bit_idx in range(64)
    ]
    if min(weights) < MIN_KEY_WEIGHT or max(weights) > MAX_KEY_WEIGHT:
        raise RuntimeError(
            f"Generated key weight range {min(weights)}..{max(weights)} is outside "
            f"{MIN_KEY_WEIGHT}..{MAX_KEY_WEIGHT}"
        )
    if min_distance < MIN_PAIRWISE_DISTANCE:
        raise RuntimeError(
            f"Generated minimum pairwise distance {min_distance} is below "
            f"{MIN_PAIRWISE_DISTANCE}"
        )
    if min(bit_counts) < MIN_BIT_COUNT or max(bit_counts) > MAX_BIT_COUNT:
        raise RuntimeError(
            f"Generated per-bit population {min(bit_counts)}..{max(bit_counts)} is outside "
            f"{MIN_BIT_COUNT}..{MAX_BIT_COUNT}"
        )

    return (
        f"nonzero={len(nonzero_values)} zero={tile_values.count(0)} "
        f"weight_range={min(weights)}..{max(weights)} "
        f"min_pairwise_distance={min_distance} "
        f"bit_count_range={min(bit_counts)}..{max(bit_counts)} "
        f"unique_pair_deltas={len(pair_deltas)}"
    )


def write_hex(path: Path, values: Iterable[int]) -> None:
    """Write one readmemh-compatible 64-bit value per line."""
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text("".join(f"{value:016X}\n" for value in values), encoding="ascii")


def render_sv_package(turn_value: int, castle_values: list[int]) -> str:
    """Emit only the fixed side-state constants needed directly by RTL."""
    constant_values = [("TURN_BLACK", turn_value)]
    constant_values.extend(
        (name.upper(), value)
        for name, value in zip(CASTLE_NAMES, castle_values)
    )
    lines = [
        "// Generated by hardware/scripts/generate_zobrist_values.py; do not edit by hand.",
        "",
        "package zobrist_values_pkg;",
        "",
        "    import chess_defs::*;",
        "",
    ]
    lines.extend(
        f"    localparam ZobristKey ZOBRIST_{name}_VALUE = ZobristKey'(64'h{value:016X});"
        for name, value in constant_values
    )
    lines.extend(("", "endpackage : zobrist_values_pkg", ""))
    return "\n".join(lines)


def main() -> None:
    turn_value, side_values, tile_values = build_values()
    summary = validate_values(turn_value, side_values, tile_values)

    castle_values = side_values[:4]
    ep_values = side_values[4:]
    write_hex(TILE_OUT_FILE, tile_values)
    write_hex(EP_OUT_FILE, ep_values)
    SV_OUT_FILE.parent.mkdir(parents=True, exist_ok=True)
    SV_OUT_FILE.write_text(
        render_sv_package(turn_value, castle_values), encoding="ascii"
    )

    print(f"wrote {TILE_OUT_FILE}")
    print(f"wrote {EP_OUT_FILE}")
    print(f"wrote {SV_OUT_FILE}")
    print(summary)


if __name__ == "__main__":
    main()
