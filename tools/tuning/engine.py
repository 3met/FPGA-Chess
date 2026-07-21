"""Export trained combined values to engine material and PST sources."""

from __future__ import annotations

import json
import math
import os
import subprocess
import sys
from pathlib import Path

from .config import REPO_ROOT
from .model import PIECE_ORDER, PST_PATH


GENERATED_PATHS = (
    REPO_ROOT / "hardware/data/pst_values/pst_values.hex",
    REPO_ROOT / "hardware/rtl/generated/pst_values_pkg.sv",
    REPO_ROOT / "hardware/rtl/generated/evaluation_parameters.svh",
)
GENERATOR = REPO_ROOT / "hardware/scripts/generate_pst_values.py"
FIXED_MATERIAL_128 = {"pawn": 128, "king": 0}
PST_WORD_BITS = 10
PST_MIN = -(1 << (PST_WORD_BITS - 1))
PST_MAX = (1 << (PST_WORD_BITS - 1)) - 1


def round_half_away(value: float) -> int:
    return math.floor(value + 0.5) if value >= 0 else math.ceil(value - 0.5)


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

    from .model import StaticEvaluationModel

    checkpoint = torch.load(checkpoint_path, map_location="cpu", weights_only=True)
    state = checkpoint["model"]
    if "terms.material_pst" in state:
        return {
            "schema": 1,
            "units": "centipawns",
            "piece_order": list(PIECE_ORDER),
            "combined_pst": state["terms.material_pst"].reshape(6, 64).tolist(),
            "best_step": checkpoint.get("step"),
        }, "legacy best checkpoint"
    model = StaticEvaluationModel()
    model.load_state_dict(state)
    model.project_parameters()
    material = model.material_cp().detach().cpu()
    pst = model.pst_cp().detach().cpu()
    return {
        "schema": 2,
        "units": "centipawns",
        "piece_order": list(PIECE_ORDER),
        "material": {piece: float(material[index]) for index, piece in enumerate(PIECE_ORDER)},
        "pst": {piece: pst[index].tolist() for index, piece in enumerate(PIECE_ORDER)},
        "combined_pst": model.combined_cp().detach().cpu().tolist(),
        "best_step": checkpoint.get("step"),
    }, "best checkpoint"


def commit_parameters(run: Path, dry_run: bool = False) -> None:
    parameters, source = load_run_parameters(run)
    material, pst = export_values(parameters)
    print(f"Run: {run.name} ({source})")
    print("Material (pawn/128): " + ", ".join(
        f"{piece}={value}" for piece, value in zip(PIECE_ORDER, material)
    ))
    if dry_run:
        print("Dry run; engine files were not changed.")
        return
    pst_document = json.loads(PST_PATH.read_text(encoding="utf-8"))
    pst_document["material"] = dict(zip(PIECE_ORDER, material))
    pst_document["pst"] = pst
    new_pst = json.dumps(pst_document, indent=2) + "\n"
    paths = (PST_PATH, *GENERATED_PATHS)
    before = {path: path.read_bytes() for path in paths}
    try:
        _atomic_text(PST_PATH, new_pst)
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
            os.replace(temporary, path)
        raise
    print("Updated evaluation parameter JSON, PST HEX, and generated SystemVerilog files.")


def _atomic_text(path: Path, contents: str) -> None:
    temporary = path.with_suffix(path.suffix + ".tmp")
    temporary.write_text(contents, encoding="utf-8")
    os.replace(temporary, path)
