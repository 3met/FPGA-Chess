"""Extensible PyTorch representation of static evaluation."""

from __future__ import annotations

import json
from pathlib import Path

import torch
from torch import nn

from .config import REPO_ROOT
from .data import FEATURE_COUNT


PIECE_ORDER = ("pawn", "knight", "bishop", "rook", "queen", "king")
PST_PATH = REPO_ROOT / "hardware/data/pst_values/pst_values.json"
FIXED_MATERIAL_CP = {"pawn": 100.0, "king": 0.0}


def engine_parameters_cp() -> tuple[torch.Tensor, torch.Tensor]:
    """Load canonical material and PST values in centipawns."""
    parameters = json.loads(PST_PATH.read_text(encoding="utf-8"))
    scale = 100.0 / 128.0
    material = torch.tensor(
        [parameters["material"][piece] * scale for piece in PIECE_ORDER],
        dtype=torch.float32,
    )
    pst = torch.tensor(
        [[value * scale for value in parameters["pst"][piece]] for piece in PIECE_ORDER],
        dtype=torch.float32,
    )
    return material, pst


def engine_combined_cp() -> torch.Tensor:
    """Load the current material-plus-PST table in centipawns."""
    material, pst = engine_parameters_cp()
    return (material[:, None] + pst).reshape(FEATURE_COUNT)


class StaticEvaluationModel(nn.Module):
    """Static evaluation with identifiable material and PST parameter groups."""

    def __init__(self, initial_combined_cp: torch.Tensor | None = None):
        super().__init__()
        if initial_combined_cp is None:
            material = torch.zeros(6, dtype=torch.float32)
            material[0] = FIXED_MATERIAL_CP["pawn"]
            pst = torch.zeros((6, 64), dtype=torch.float32)
        else:
            if initial_combined_cp.numel() != FEATURE_COUNT:
                raise ValueError(f"expected {FEATURE_COUNT} combined PST values")
            combined = initial_combined_cp.reshape(6, 64).detach().clone()
            material_values = [FIXED_MATERIAL_CP["pawn"]]
            for piece_index in range(1, 5):
                table = combined[piece_index]
                material_values.append(float((table.min() + table.max()) / 2.0))
            material_values.append(FIXED_MATERIAL_CP["king"])
            material = torch.tensor(material_values, dtype=combined.dtype)
            pst = combined - material[:, None]
        self.terms = nn.ParameterDict({
            "material": nn.Parameter(material[1:5].clone()),
            "pst": nn.Parameter(pst.reshape(FEATURE_COUNT).clone()),
        })
        pst_mask = torch.ones((6, 64), dtype=pst.dtype)
        pst_mask[0, :8] = 0
        pst_mask[0, 56:] = 0
        self.register_buffer("_pst_mask", pst_mask)
        self.project_parameters()

    def material_cp(self) -> torch.Tensor:
        """Return all six material values, including fixed pawn and king."""
        fixed = self.terms["material"].new_tensor
        return torch.cat((
            fixed([FIXED_MATERIAL_CP["pawn"]]),
            self.terms["material"],
            fixed([FIXED_MATERIAL_CP["king"]]),
        ))

    def pst_cp(self) -> torch.Tensor:
        """Return the effective PST with unreachable pawn entries fixed at zero."""
        return self.terms["pst"].reshape(6, 64) * self._pst_mask

    def combined_cp(self) -> torch.Tensor:
        """Return the effective combined material-plus-PST table."""
        return self.material_cp()[:, None] + self.pst_cp()

    @torch.no_grad()
    def project_parameters(self) -> None:
        """Remove PST offset ambiguity without changing reachable combined scores."""
        pst = self.terms["pst"].reshape(6, 64)
        pst[0, :8] = 0
        pst[0, 56:] = 0
        for piece_index in range(1, 5):
            center = (pst[piece_index].min() + pst[piece_index].max()) / 2.0
            pst[piece_index].sub_(center)
            self.terms["material"][piece_index - 1].add_(center)
        king_center = (pst[5].min() + pst[5].max()) / 2.0
        pst[5].sub_(king_center)

    def forward(self, codes: torch.Tensor) -> torch.Tensor:
        mask = codes != 0
        indices = codes.abs().to(torch.long).sub(1).clamp_min(0)
        signs = codes.sign().to(self.terms["pst"].dtype)
        values = self.combined_cp().reshape(FEATURE_COUNT)[indices] * signs * mask
        return values.sum(dim=1)
