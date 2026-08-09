"""Export trained combined values to engine material and PST sources."""

from __future__ import annotations

import json
import math
import subprocess
import sys
from pathlib import Path

from tools.common.files import atomic_write_text

from .config import REPO_ROOT
from .model import (
    EvaluationModel,
    NNUE_ACCUMULATORS,
    NNUE_FEATURE_COUNT,
    NNUE_MODEL_VERSION,
    PIECE_ORDER,
    PST_PATH,
)


GENERATED_PATHS = (
    REPO_ROOT / "hardware/data/pst_values/pst_values.hex",
    REPO_ROOT / "hardware/rtl/generated/evaluation_parameters.svh",
)
NNUE_FEATURE_PATH = REPO_ROOT / "hardware/data/nnue/feature_transformer.hex"
NNUE_OUTPUT_PATH = REPO_ROOT / "hardware/data/nnue/output_weights.hex"
NNUE_BIAS_PATH = REPO_ROOT / "hardware/data/nnue/accumulator_bias.hex"
NNUE_OUTPUT_MAC_LANES = 128
GENERATOR = REPO_ROOT / "hardware/scripts/generate_pst_values.py"
FIXED_MATERIAL_128 = {"pawn": 128, "king": 0}
PST_WORD_BITS = 10
PST_MIN = -(1 << (PST_WORD_BITS - 1))
PST_MAX = (1 << (PST_WORD_BITS - 1)) - 1


def round_half_away(value: float) -> int:
    return math.floor(value + 0.5) if value >= 0 else math.ceil(value - 0.5)


def round_ties_to_even(value: float) -> int:
    """Match torch.round used by the quantization-aware NNUE forward pass."""
    return round(value)


def validate_export_ranges(material: list[int], pst: dict[str, list[int]]) -> None:
    """Ensure exported values fit their distinct hardware storage widths."""
    if any(not -32768 <= value <= 32767 for value in material):
        raise ValueError("exported material exceeds signed 16-bit range")
    if any(not PST_MIN <= value <= PST_MAX for table in pst.values() for value in table):
        raise ValueError(f"exported PST exceeds signed {PST_WORD_BITS}-bit range")


def decompose(combined_cp: list[list[float]]) -> tuple[list[int], dict[str, list[int]]]:
    """Split legacy combined values without changing any reachable square score."""
    if len(combined_cp) != 6 or any(len(table) != 64 for table in combined_cp):
        raise ValueError("combined_pst must contain six 64-entry tables")
    combined = [[round_half_away(value * 128.0 / 100.0) for value in table] for table in combined_cp]
    material: list[int] = []
    pst: dict[str, list[int]] = {}
    for piece_index, piece in enumerate(PIECE_ORDER):
        reachable = list(range(8, 56)) if piece == "pawn" else list(range(64))
        midpoint = FIXED_MATERIAL_128.get(piece)
        if midpoint is None:
            low = min(combined[piece_index][square] for square in reachable)
            high = max(combined[piece_index][square] for square in reachable)
            midpoint = (low + high + 1) // 2
        offsets = [value - midpoint for value in combined[piece_index]]
        if piece == "pawn":
            for square in (*range(8), *range(56, 64)):
                offsets[square] = 0
        material.append(midpoint)
        pst[piece] = offsets
        for square in reachable:
            if midpoint + offsets[square] != combined[piece_index][square]:
                raise AssertionError("combined evaluation changed during decomposition")
    validate_export_ranges(material, pst)
    return material, pst


def export_values(parameters: dict) -> tuple[list[int], dict[str, list[int]]]:
    """Convert explicit or legacy run parameters to signed engine units."""
    if "material" not in parameters or "pst" not in parameters:
        return decompose(parameters["combined_pst"])
    if (
        set(parameters["material"]) != set(PIECE_ORDER)
        or set(parameters["pst"]) != set(PIECE_ORDER)
    ):
        raise ValueError("parameters must define material and PST values for all six pieces")
    material = [
        round_half_away(float(parameters["material"][piece]) * 128.0 / 100.0)
        for piece in PIECE_ORDER
    ]
    material[0] = FIXED_MATERIAL_128["pawn"]
    material[5] = FIXED_MATERIAL_128["king"]
    pst = {}
    for piece in PIECE_ORDER:
        table = parameters["pst"][piece]
        if len(table) != 64:
            raise ValueError(f"PST for {piece} must contain 64 entries")
        pst[piece] = [round_half_away(float(value) * 128.0 / 100.0) for value in table]
    for square in (*range(8), *range(56, 64)):
        pst["pawn"][square] = 0
    validate_export_ranges(material, pst)
    return material, pst


def load_run_parameters(run: Path) -> tuple[dict, str]:
    """Load exported parameters or recover them from a run's best checkpoint."""
    parameter_path = run / "parameters.json"
    if parameter_path.is_file():
        return json.loads(parameter_path.read_text(encoding="utf-8")), "exported parameters"
    checkpoint_path = run / "best.pt"
    if not checkpoint_path.is_file():
        raise FileNotFoundError(f"run has neither parameters.json nor best.pt: {run.name}")
    import torch

    checkpoint = torch.load(checkpoint_path, map_location="cpu", weights_only=True)
    state = checkpoint["model"]
    if "terms.material_pst" in state:
        return {
            "units": "centipawns",
            "piece_order": list(PIECE_ORDER),
            "combined_pst": state["terms.material_pst"].reshape(6, 64).tolist(),
            "best_step": checkpoint.get("step"),
        }, "legacy best checkpoint"
    if checkpoint.get("nnue_model_version") != NNUE_MODEL_VERSION:
        raise ValueError(
            "checkpoint predates the current single-head NNUE model and cannot be exported"
        )
    model = EvaluationModel()
    model.load_state_dict(state)
    model.project_parameters()
    material = model.material_cp().detach().cpu()
    pst = model.pst_cp().detach().cpu()
    return {
        "units": "centipawns",
        "piece_order": list(PIECE_ORDER),
        "material": {piece: float(material[index]) for index, piece in enumerate(PIECE_ORDER)},
        "pst": {piece: pst[index].tolist() for index, piece in enumerate(PIECE_ORDER)},
        "combined_pst": model.combined_cp().detach().cpu().tolist(),
        "nnue": {
            "model_version": NNUE_MODEL_VERSION,
            "encoding": "relative-2x6x64",
            "output_units": "pawn/128",
            "accumulator_bias": model.accumulator_bias.detach().cpu().tolist(),
            "feature_weights": model.feature_weights.detach().cpu().round()
                .clamp(-1, 1).to(torch.int8).tolist(),
            "output_weights": model.output_weights.detach().cpu().tolist(),
        },
        "best_step": checkpoint.get("step"),
    }, "best checkpoint"


def _clamp_int4(value: float) -> int:
    return max(-8, min(7, round_ties_to_even(value)))


def _pack_ternary_row(row: list[int]) -> str:
    """Pack four signed two-bit ternary transformer weights per byte."""
    if len(row) != NNUE_ACCUMULATORS:
        raise ValueError(f"each NNUE feature row must contain {NNUE_ACCUMULATORS} weights")
    encoded = bytearray()
    for offset in range(0, NNUE_ACCUMULATORS, 4):
        value = 0
        for index, weight in enumerate(row[offset:offset + 4]):
            integer = int(weight)
            if integer not in (-1, 0, 1):
                raise ValueError("NNUE feature weights must be ternary")
            value |= ({0: 0, 1: 1, -1: 3}[integer]) << (2 * index)
        encoded.append(value)
    # readmemh maps the leftmost digits to the most-significant byte.
    return bytes(reversed(encoded)).hex()


def export_nnue(parameters: dict) -> tuple[str, str, str]:
    """Create packed feature, output-row, and accumulator-bias ROM images."""
    nnue = parameters.get("nnue")
    if nnue is None:
        return (
            ("00" * (NNUE_ACCUMULATORS // 4) + "\n") * NNUE_FEATURE_COUNT,
            ("0" * NNUE_OUTPUT_MAC_LANES + "\n")
                * (NNUE_ACCUMULATORS // NNUE_OUTPUT_MAC_LANES),
            "0\n" * NNUE_ACCUMULATORS,
        )
    rows = nnue["feature_weights"]
    if len(rows) != NNUE_FEATURE_COUNT:
        raise ValueError(
            f"NNUE feature transformer must contain {NNUE_FEATURE_COUNT} rows"
        )
    if nnue.get("output_units") != "pawn/128":
        raise ValueError("NNUE output parameters must use pawn/128 hardware score units")
    feature_text = "\n".join(_pack_ternary_row(row) for row in rows) + "\n"
    weights = nnue["output_weights"]
    if len(weights) != NNUE_ACCUMULATORS:
        raise ValueError(f"NNUE output layer must contain {NNUE_ACCUMULATORS} weights")
    output_lines = []
    for offset in range(0, NNUE_ACCUMULATORS, NNUE_OUTPUT_MAC_LANES):
        # readmemh maps the rightmost nibble to lane zero.
        output_lines.append("".join(
            f"{_clamp_int4(value) & 0xf:x}"
            for value in reversed(weights[offset:offset + NNUE_OUTPUT_MAC_LANES])
        ))
    biases = nnue["accumulator_bias"]
    if len(biases) != NNUE_ACCUMULATORS:
        raise ValueError(f"NNUE accumulator bias must contain {NNUE_ACCUMULATORS} values")
    bias_text = "\n".join(
        f"{max(-4, min(3, round_ties_to_even(value))) & 0x7:x}" for value in biases
    ) + "\n"
    return feature_text, "\n".join(output_lines) + "\n", bias_text


def commit_parameters(run: Path, dry_run: bool = False) -> None:
    parameters, source = load_run_parameters(run)
    material, pst = export_values(parameters)
    print(f"Run: {run.name} ({source})")
    print("Material (pawn/128): " + ", ".join(
        f"{piece}={value}" for piece, value in zip(PIECE_ORDER, material)
    ))
    if dry_run:
        if "nnue" in parameters:
            export_nnue(parameters)
        print("Dry run; engine files were not changed.")
        return
    pst_document = json.loads(PST_PATH.read_text(encoding="utf-8"))
    pst_document["material"] = dict(zip(PIECE_ORDER, material))
    pst_document["pst"] = pst
    new_pst = json.dumps(pst_document, indent=2) + "\n"
    nnue_feature, nnue_output, nnue_bias = export_nnue(parameters)
    paths = (
        PST_PATH, *GENERATED_PATHS, NNUE_FEATURE_PATH, NNUE_OUTPUT_PATH,
        NNUE_BIAS_PATH,
    )
    before = {path: path.read_bytes() for path in paths}
    try:
        atomic_write_text(PST_PATH, new_pst)
        atomic_write_text(NNUE_FEATURE_PATH, nnue_feature)
        atomic_write_text(NNUE_OUTPUT_PATH, nnue_output)
        atomic_write_text(NNUE_BIAS_PATH, nnue_bias)
        result = subprocess.run(
            [sys.executable, str(GENERATOR)],
            cwd=REPO_ROOT,
            text=True,
            stdout=subprocess.PIPE,
            stderr=subprocess.STDOUT,
            check=False,
        )
        if result.returncode:
            raise RuntimeError(result.stdout.strip() or f"generator exited {result.returncode}")
    except BaseException:
        for path, contents in before.items():
            temporary = path.with_suffix(path.suffix + ".restore")
            temporary.write_bytes(contents)
            temporary.replace(path)
        raise
    print("Updated material/PST data and packed NNUE feature/output ROM images.")
