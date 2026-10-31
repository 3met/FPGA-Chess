"""Export trained parameters as complete quantized evaluation models."""

from __future__ import annotations

import json
import math
import re
from pathlib import Path

from tools.common.files import atomic_write_text
from tools.evaluation_model import EVALUATION_ROOT, architecture, decode_model, format_model, tensor, pack_values

from .config import REPO_ROOT
from .model import (
    EvaluationModel,
    ENGINE_EVAL_BITS,
    ENGINE_MAX_MATE_DISTANCE,
    NNUE_ACCUMULATORS,
    NNUE_ACTIVATION_BITS,
    NNUE_ACCUMULATOR_BITS,
    NNUE_ACCUMULATOR_BIAS_BITS,
    NNUE_ACCUMULATOR_BIAS_MAX,
    NNUE_ACCUMULATOR_BIAS_MIN,
    NNUE_FEATURE_COUNT,
    NNUE_OUTPUT_BIAS_BITS,
    NNUE_OUTPUT_BIAS_MAX,
    NNUE_OUTPUT_BUCKETS,
    NNUE_OUTPUT_INPUTS,
    NNUE_OUTPUT_WEIGHT_BITS,
    NNUE_OUTPUT_WEIGHT_MAX,
    NNUE_OUTPUT_WEIGHT_MIN,
    PIECE_ORDER,
)


NNUE_OUTPUT_MAC_LANES = 256
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


def export_values(parameters: dict, suffix: str = "") -> tuple[list[int], dict[str, list[int]]]:
    """Convert separate material and PST parameters to signed engine units."""
    material_key, pst_key = f"material{suffix}", f"pst{suffix}"
    if material_key not in parameters or pst_key not in parameters:
        raise ValueError(f"parameters must contain {material_key} and {pst_key} tables")
    if (
        set(parameters[material_key]) != set(PIECE_ORDER)
        or set(parameters[pst_key]) != set(PIECE_ORDER)
    ):
        raise ValueError("parameters must define material and PST values for all six pieces")
    material = [
        round_half_away(float(parameters[material_key][piece]) * 128.0 / 100.0)
        for piece in PIECE_ORDER
    ]
    material[0] = FIXED_MATERIAL_128["pawn"]
    material[5] = FIXED_MATERIAL_128["king"]
    pst = {}
    for piece in PIECE_ORDER:
        table = parameters[pst_key][piece]
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
    output_buckets = int(state["output_weights"].shape[0])
    model = EvaluationModel(output_buckets=output_buckets)
    model.load_state_dict(state)
    model.project_parameters()
    material = model.material_cp().detach().cpu()
    pst = model.pst_cp().detach().cpu()
    endgame_material = model.material_endgame_cp().detach().cpu()
    endgame_pst = model.pst_endgame_cp().detach().cpu()
    return {
        "units": "centipawns",
        "piece_order": list(PIECE_ORDER),
        "material": {piece: float(material[index]) for index, piece in enumerate(PIECE_ORDER)},
        "pst": {piece: pst[index].tolist() for index, piece in enumerate(PIECE_ORDER)},
        "material_endgame": {
            piece: float(endgame_material[index]) for index, piece in enumerate(PIECE_ORDER)
        },
        "pst_endgame": {
            piece: endgame_pst[index].tolist() for index, piece in enumerate(PIECE_ORDER)
        },
        "nnue": {
            "encoding": "relative-2x6x64",
            "output_units": "pawn/128",
            "output_buckets": output_buckets,
            "accumulator_bias": model.accumulator_bias.detach().cpu().tolist(),
            "feature_weights": model.feature_weights.detach().cpu().round()
                .clamp(-2, 1).to(torch.int8).tolist(),
            "output_weights": model.output_weights.detach().cpu().tolist(),
            "output_bias": model.output_bias.detach().cpu().tolist(),
        },
        "best_step": checkpoint.get("step"),
    }, "best checkpoint"


def _clamp_output_weight(value: float) -> int:
    return max(NNUE_OUTPUT_WEIGHT_MIN, min(NNUE_OUTPUT_WEIGHT_MAX, round_ties_to_even(value)))


def _pack_output_row(row: list[float]) -> str:
    """Pack one output row with the training target's signed weight width."""
    if len(row) != NNUE_OUTPUT_MAC_LANES:
        raise ValueError(f"each NNUE output row must contain {NNUE_OUTPUT_MAC_LANES} weights")
    packed = 0
    for lane, weight in enumerate(row):
        packed |= (_clamp_output_weight(weight) & ((1 << NNUE_OUTPUT_WEIGHT_BITS) - 1)) << (
            lane * NNUE_OUTPUT_WEIGHT_BITS
        )
    digits = (NNUE_OUTPUT_MAC_LANES * NNUE_OUTPUT_WEIGHT_BITS + 3) // 4
    return f"{packed:0{digits}x}"


def _pack_feature_row(row: list[int]) -> str:
    """Pack four signed two-bit transformer weights per byte."""
    if len(row) != NNUE_ACCUMULATORS:
        raise ValueError(f"each NNUE feature row must contain {NNUE_ACCUMULATORS} weights")
    encoded = bytearray()
    for offset in range(0, NNUE_ACCUMULATORS, 4):
        value = 0
        for index, weight in enumerate(row[offset:offset + 4]):
            integer = int(weight)
            if integer < -2 or integer > 1:
                raise ValueError("NNUE feature weights must fit signed two-bit range")
            value |= (integer & 0x3) << (2 * index)
        encoded.append(value)
    # readmemh maps the leftmost digits to the most-significant byte.
    return bytes(reversed(encoded)).hex()


def export_nnue(parameters: dict) -> tuple[str, str, str, str]:
    """Create packed feature, output, and accumulator-bias ROM images."""
    nnue = parameters.get("nnue")
    if nnue is None:
        raise ValueError("parameters must contain NNUE weights and biases")
    rows = nnue["feature_weights"]
    if len(rows) != NNUE_FEATURE_COUNT:
        raise ValueError(
            f"NNUE feature transformer must contain {NNUE_FEATURE_COUNT} rows"
        )
    if nnue.get("output_units") != "pawn/128":
        raise ValueError("NNUE output parameters must use pawn/128 hardware score units")
    if nnue.get("output_buckets") != NNUE_OUTPUT_BUCKETS:
        raise ValueError(f"NNUE output layer must contain {NNUE_OUTPUT_BUCKETS} buckets")
    # Spare hardware ports read unreachable pawn end-rank rows.
    feature_text = "\n".join(
        _pack_feature_row([0] * NNUE_ACCUMULATORS
            if feature // 64 in (0, 6) and feature % 64 // 8 in (0, 7) else row)
        for feature, row in enumerate(rows)
    ) + "\n"
    weights = nnue["output_weights"]
    if len(weights) != NNUE_OUTPUT_BUCKETS or any(
        len(bucket) != NNUE_OUTPUT_INPUTS for bucket in weights
    ):
        raise ValueError(
            f"NNUE output layer must contain {NNUE_OUTPUT_BUCKETS}x{NNUE_OUTPUT_INPUTS} weights"
        )
    output_lines = []
    for bucket in weights:
        for offset in range(0, NNUE_OUTPUT_INPUTS, NNUE_OUTPUT_MAC_LANES):
            output_lines.append(_pack_output_row(
                bucket[offset:offset + NNUE_OUTPUT_MAC_LANES]
            ))
    biases = nnue["accumulator_bias"]
    if len(biases) != NNUE_ACCUMULATORS:
        raise ValueError(f"NNUE accumulator bias must contain {NNUE_ACCUMULATORS} values")
    # BRAM initialization stores signed biases as two's-complement codes.
    bias_values = [
        max(NNUE_ACCUMULATOR_BIAS_MIN,
            min(NNUE_ACCUMULATOR_BIAS_MAX, round_ties_to_even(value)))
        for value in biases
    ]
    bias_mask = (1 << NNUE_ACCUMULATOR_BIAS_BITS) - 1
    bias_text = "\n".join(f"{value & bias_mask:x}" for value in bias_values) + "\n"
    output_bias = nnue["output_bias"]
    if len(output_bias) != NNUE_OUTPUT_BUCKETS:
        raise ValueError(f"NNUE output bias must contain {NNUE_OUTPUT_BUCKETS} values")
    output_bias_values = [
        max(0, min(NNUE_OUTPUT_BIAS_MAX, round_ties_to_even(value)))
        for value in output_bias
    ]
    output_bias_text = "".join(
        f"{value:02x}\n"
        for value in output_bias_values
    )
    return feature_text, "\n".join(output_lines) + "\n", output_bias_text, bias_text


def _require_matching_rtl() -> None:
    """Reject ROM export if the training widths diverge from deployed RTL."""
    rtl = (REPO_ROOT / "hardware/rtl/nnue/defs.sv").read_text(encoding="utf-8")
    expected = {
        "NNUE_OUTPUT_MAC_LANES": NNUE_OUTPUT_MAC_LANES,
        "NNUE_ACCUMULATOR_BITS": NNUE_ACCUMULATOR_BITS,
        "NNUE_ACCUMULATOR_BIAS_BITS": NNUE_ACCUMULATOR_BIAS_BITS,
        "NNUE_ACTIVATION_BITS": NNUE_ACTIVATION_BITS,
        "NNUE_OUTPUT_WEIGHT_BITS": NNUE_OUTPUT_WEIGHT_BITS,
        "NNUE_OUTPUT_BIAS_BITS": NNUE_OUTPUT_BIAS_BITS,
    }
    for name, value in expected.items():
        match = re.search(rf"\b(?:localparam|parameter)\s+int\s+{name}\s*=\s*(\d+)\s*;", rtl)
        if match is None or int(match.group(1)) != value:
            raise RuntimeError(
                f"{name} differs from RTL; update RTL or training configuration before engine-commit"
            )
    # Keep training's finite-score band aligned with the search score encoding.
    chess_rtl = (REPO_ROOT / "hardware/rtl/chess_defs.sv").read_text(encoding="utf-8")
    score = re.search(r"typedef\s+logic\s+signed\s*\[\s*(\d+)\s*:\s*0\s*\]\s*EvalScore\s*;", chess_rtl)
    mate = re.search(r"localparam\s+int\s+MAX_MATE_DISTANCE\s*=\s*(\d+)\s*;", chess_rtl)
    if (score is None or int(score.group(1)) + 1 != ENGINE_EVAL_BITS
            or mate is None or int(mate.group(1)) != ENGINE_MAX_MATE_DISTANCE):
        raise RuntimeError("Score limits differ from RTL; update RTL or training configuration before engine-commit")


def export_model(parameters: dict, name: str) -> dict:
    """Quantize training outputs once into a self-contained deployment model."""
    feature, output, output_bias, bias = export_nnue(parameters)
    def words(text, bits, width, signed=True):
        """Recover quantized lane values from the shared training export arithmetic."""
        values = []
        for row in text.splitlines():
            packed = int(row, 16)
            for lane in range(width):
                value = (packed >> (bits * lane)) & ((1 << bits) - 1)
                values.append(value - (1 << bits) if signed and value >= 1 << (bits - 1) else value)
        return values
    # Match training's piece-count bucket mapping, including the final count.
    ranges = []
    for count in range(2, 33):
        bucket = min(NNUE_OUTPUT_BUCKETS - 1, (count - 2) * NNUE_OUTPUT_BUCKETS // 32)
        if len(ranges) <= bucket:
            ranges.append([count, count])
        else:
            ranges[bucket][1] = count
    document = {
        "metadata": {"name": name, "training_run": name, "best_step": parameters.get("best_step")},
        "architecture": architecture(NNUE_ACCUMULATORS, ranges),
        "weights": {
            "accumulator": {"weights": tensor(words(feature, 2, NNUE_ACCUMULATORS), 2),
                            "biases": tensor(words(bias, 6, 1), 6)},
            "output": {"weights": tensor(words(output, 4, NNUE_OUTPUT_MAC_LANES), 4),
                       "biases": tensor(words(output_bias, 6, 1, False), 6, False)}},
        "material": {"dtype": "int16"}, "pst": {"dtype": "int10", "encoding": "base64"}}
    for phase, suffix in (("opening", ""), ("endgame", "_endgame")):
        material, pst = export_values(parameters, suffix)
        document["material"][phase] = dict(zip(PIECE_ORDER, material))
        document["pst"][phase] = {piece: pack_values(pst[piece], 10) for piece in PIECE_ORDER}
    decode_model(document)
    return document


def commit_parameters(run: Path, dry_run: bool = False, output: Path | None = None) -> None:
    """Save one validated deployment file without changing FPGA model selection."""
    parameters, source = load_run_parameters(run)
    _require_matching_rtl()
    document = export_model(parameters, run.name)
    destination = Path(output) if output is not None else EVALUATION_ROOT / f"{run.name}.nnue.json"
    if not destination.name.endswith(".nnue.json"):
        raise ValueError("evaluation output path must end in .nnue.json")
    print(f"Run: {run.name} ({source})")
    print(f"Evaluation file: {destination}")
    for phase in ("opening", "endgame"):
        print(phase.capitalize() + " material (pawn/128): " + ", ".join(
            f"{piece}={value}" for piece, value in document["material"][phase].items()))
    if dry_run:
        print("Dry run; no files were changed.")
        return
    destination.parent.mkdir(parents=True, exist_ok=True)
    atomic_write_text(destination, format_model(document))
    print("Saved quantized evaluation model; select it with evaluation_file in the FPGA configuration.")
