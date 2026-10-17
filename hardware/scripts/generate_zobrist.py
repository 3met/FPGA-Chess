#!/usr/bin/env python3
"""Emit RTL, fixed side keys, and simulation references from the selected hash circuit."""

from __future__ import annotations

import hashlib
import json
from pathlib import Path
from typing import Iterable


ROOT = Path(__file__).resolve().parents[2]
TILE_REFERENCE_FILE = ROOT / "hardware" / "tb" / "board_update_pipeline" / "data" / "zobrist_tile_reference.hex"
EP_REFERENCE_FILE = ROOT / "hardware" / "tb" / "board_update_pipeline" / "data" / "zobrist_ep_reference.hex"
RTL_OUT_FILE = ROOT / "hardware" / "rtl" / "generated" / "zobrist_hash_pkg.sv"
NETWORK_FILE = ROOT / "hardware" / "data" / "zobrist" / "hash_network.json"
SIDE_KEY_SEED = "0"

COLORS = ("white", "black")
CASTLE_NAMES = (
    "white_kingside",
    "white_queenside",
    "black_kingside",
    "black_queenside",
)

# These broad checks catch broken derivation, truncation, biased feature keys,
# and short XOR relations that would cause systematic position collisions.
MIN_KEY_WEIGHT = 16
MAX_KEY_WEIGHT = 48
MIN_PAIRWISE_DISTANCE = 12
MIN_BIT_COUNT = 300
MAX_BIT_COUNT = 450


def derive_key(label: str) -> int:
    """Derive one stable 64-bit key from a domain-separated semantic label."""
    digest = hashlib.sha256(f"{SIDE_KEY_SEED}|{label}".encode("ascii")).digest()
    words = (
        int.from_bytes(digest[offset:offset + 8], "big")
        for offset in range(0, len(digest), 8)
    )
    value = 0
    for word in words:
        value ^= word
    return value


def load_network() -> list[list[tuple[list[int], int]]]:
    """Read the offline-selected circuit; each node fits a logic LUT."""
    network = json.loads(NETWORK_FILE.read_text(encoding="ascii"))
    layers = []
    width = network["input_bits"]
    if width != 10:
        raise RuntimeError("Feature addresses must contain ten bits")
    for layer in network["layers"]:
        nodes = []
        for node in layer:
            inputs, truth = node["inputs"], int(node["truth"], 16)
            if not 1 <= len(inputs) <= 6 or len(set(inputs)) != len(inputs) or not all(0 <= bit < width for bit in inputs):
                raise RuntimeError("Invalid feature-hash LUT inputs")
            if not 0 <= truth < 1 << (1 << len(inputs)):
                raise RuntimeError("Invalid feature-hash LUT truth table")
            nodes.append((inputs, truth))
        layers.append(nodes)
        width = len(nodes)
    if len(layers) != 2 or width != 64:
        raise RuntimeError("Feature hash must have two layers and a 64-bit result")
    return layers


def hash_features() -> list[int]:
    """Evaluate every input independently of the generated SystemVerilog."""
    values = [
        sum((((value >> bit) ^ (value >> ((bit + 1) % 10))
              ^ (value >> ((bit + 3) % 10))) & 1) << bit for bit in range(10))
        for value in range(1 << 10)
    ]
    if len(set(values)) != len(values):
        raise RuntimeError("Feature-address diffusion must be invertible")
    for layer in load_network():
        values = [
            sum(((truth >> sum(((value >> bit) & 1) << index
                              for index, bit in enumerate(inputs))) & 1) << output
                for output, (inputs, truth) in enumerate(layer))
            for value in values
        ]
    return values


def build_values() -> tuple[int, list[int], list[int]]:
    """Return the turn key, castling/EP keys, and the piece-square table."""
    side_values = [derive_key(f"castle:{name}") for name in CASTLE_NAMES]
    feature_values = hash_features()
    # EP occupies unused white-empty-tile addresses, disjoint from all pieces.
    side_values.extend(feature_values[:8])

    tile_values: list[int] = []
    for color in COLORS:
        for piece_code in range(8):
            for pos in range(64):
                rank = pos // 8
                # Standard-chess pawns cannot occupy their first or eighth rank.
                tile_values.append(
                    0 if piece_code in (0, 7) or (piece_code == 1 and rank in (0, 7))
                    else feature_values[len(tile_values)]
                )

    return derive_key("turn:black"), side_values, tile_values


def validate_feature_hash(values: list[int]) -> None:
    """Reject output parity invariants for every nonzero input difference."""
    if len(values) != 1 << 10 or len(set(values)) != len(values):
        raise RuntimeError("Feature hash must distinguish every address")
    for difference in range(1, len(values)):
        basis: dict[int, int] = {}
        for index, value in enumerate(values):
            row = value ^ values[index ^ difference]
            while row:
                pivot = row.bit_length() - 1
                if pivot in basis:
                    row ^= basis[pivot]
                else:
                    basis[pivot] = row
                    break
            if len(basis) == 64:
                break
        if len(basis) != 64:
            raise RuntimeError(
                f"Feature-hash difference {difference} spans only {len(basis)} bits"
            )


def validate_values(turn_value: int, side_values: list[int], tile_values: list[int]) -> str:
    """Validate table shape, distribution, and low-order XOR independence."""
    if len(side_values) != 12 or len(tile_values) != 2 * 8 * 64:
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
    """Emit fixed side keys and a portable combinational, LUT-sized circuit."""
    constant_values = [("TURN_BLACK", turn_value)]
    constant_values.extend(
        (name.upper(), value)
        for name, value in zip(CASTLE_NAMES, castle_values)
    )
    lines = [
        "// Generated by hardware/scripts/generate_zobrist.py; do not edit by hand.",
        "",
        "package zobrist_hash_pkg;",
        "",
        "    import chess_defs::*;",
        "    import zobrist_defs::*;",
        "",
    ]
    lines.extend(
        f"    localparam ZobristKey ZOBRIST_{name}_VALUE = ZobristKey'(64'h{value:016X});"
        for name, value in constant_values
    )
    layers = load_network()
    lines.extend((
        "",
        "    // Each constant truth table maps to a logic LUT, with no block memory.",
        "    function automatic logic zobrist_lut(input logic [63:0] truth, input logic [5:0] index);",
        "        return truth[index];",
        "    endfunction",
        "",
        "    // Diffuse the feature encoding, then apply two layers of nonlinear Boolean functions.",
        "    function automatic ZobristKey zobrist_feature_key(input ZobristFeature feature);",
        "        ZobristFeature mixed;",
        f"        logic [{len(layers[0]) - 1}:0] hidden;",
        "        ZobristKey key;",
    ))
    for bit in range(10):
        lines.append(f"        mixed[{bit}] = feature[{bit}] ^ feature[{(bit + 1) % 10}] ^ feature[{(bit + 3) % 10}];")
    for layer, source, dest in zip(layers, ("mixed", "hidden"), ("hidden", "key")):
        for output, (inputs, truth) in enumerate(layer):
            parts = ([f"{6 - len(inputs)}'b0"] if len(inputs) < 6 else [])
            parts.extend(f"{source}[{bit}]" for bit in reversed(inputs))
            index = ", ".join(parts)
            lines.append(f"        {dest}[{output}] = zobrist_lut(64'h{truth:016X}, {{{index}}});")
    lines.extend((
        "        return key;",
        "    endfunction",
        "",
        "    // EP uses unused empty-tile addresses, disjoint from enabled piece keys.",
        "    function automatic ZobristKey zobrist_ep_key(input BoardFile file_index);",
        "        unique case (file_index)",
    ))
    feature_values = hash_features()
    for index, key in enumerate(feature_values[:8]):
        lines.append(f"            3'd{index}: return 64'h{key:016X};")
    lines.extend((
        "            default: return 'x;",
        "        endcase",
        "    endfunction",
        "",
        "    // Standard castling has four rook XOR deltas, identical for push and reversal.",
        "    function automatic ZobristKey zobrist_castle_rook_delta(input logic [1:0] selector);",
        "        unique case (selector)",
    ))
    for color in range(2):
        for kingside in range(2):
            selector = (color << 1) | kingside
            base_address = ((color << 3) | 4) * 64 + color * 56
            source_file, destination_file = (7, 5) if kingside else (0, 3)
            delta = feature_values[base_address + source_file] ^ feature_values[base_address + destination_file]
            lines.append(f"            2'd{selector}: return 64'h{delta:016X};")
    lines.extend((
        "            default: return 'x;",
        "        endcase",
        "    endfunction",
        "",
        "endpackage : zobrist_hash_pkg", "",
    ))
    return "\n".join(lines)


def main() -> None:
    validate_feature_hash(hash_features())
    turn_value, side_values, tile_values = build_values()
    summary = validate_values(turn_value, side_values, tile_values)

    castle_values = side_values[:4]
    ep_values = side_values[4:]
    write_hex(TILE_REFERENCE_FILE, tile_values)
    write_hex(EP_REFERENCE_FILE, ep_values)
    RTL_OUT_FILE.parent.mkdir(parents=True, exist_ok=True)
    RTL_OUT_FILE.write_text(
        render_sv_package(turn_value, castle_values), encoding="ascii"
    )

    print(f"wrote {TILE_REFERENCE_FILE}")
    print(f"wrote {EP_REFERENCE_FILE}")
    print(f"wrote {RTL_OUT_FILE}")
    print(summary)


if __name__ == "__main__":
    main()
