"""Trainable material/PST plus hardware-shaped 12x64 NNUE evaluation."""

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
NNUE_SIDES = 2
NNUE_PIECE_CATEGORIES = 6
NNUE_FEATURE_COUNT = NNUE_SIDES * NNUE_PIECE_CATEGORIES * 64
NNUE_ACCUMULATORS = 256
NNUE_ENGINE_UNIT_CP = 100.0 / 128.0
NNUE_MODEL_VERSION = 7


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


class EvaluationModel(nn.Module):
    """Material/PST base evaluation with a quantization-aware 12x64 correction."""

    def __init__(
        self,
        initial_combined_cp: torch.Tensor | None = None,
    ):
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
        # Pair-identical sparse ternary channels cancel against the alternating
        # head at startup, while every quantized parameter still has a gradient.
        pair_rows = torch.arange(NNUE_FEATURE_COUNT, dtype=torch.int64)[:, None]
        pair_lanes = torch.arange(NNUE_ACCUMULATORS // 2, dtype=torch.int64)[None, :]
        pair_codes = (pair_rows * 37 + pair_lanes * 19) % 10
        pair_weights = torch.where(pair_codes == 0, 1.0,
            torch.where(pair_codes == 1, -1.0, 0.0))
        self.feature_weights = nn.Parameter(pair_weights.repeat_interleave(2, dim=1))
        # A positive activation and alternating nonzero output lanes preserve
        # an exact zero correction while avoiding dead quantized parameters.
        self.accumulator_bias = nn.Parameter(torch.ones(NNUE_ACCUMULATORS))
        initial_output = torch.tensor([1.0, -1.0]).repeat(NNUE_ACCUMULATORS // 2)
        self.output_weights = nn.Parameter(initial_output)
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

    @staticmethod
    def _ternary(values: torch.Tensor) -> torch.Tensor:
        """Use ternary values in the forward pass and a straight-through gradient."""
        quantized = values.round().clamp(-1, 1)
        return values + (quantized - values).detach()

    @staticmethod
    def _int4(values: torch.Tensor) -> torch.Tensor:
        """Quantize output weights to the deployed signed int4 representation."""
        quantized = values.round().clamp(-8, 7)
        return values + (quantized - values).detach()

    @staticmethod
    def _accumulator_bias_int3(values: torch.Tensor) -> torch.Tensor:
        """Quantize the trained bias to its deployed signed three-bit range."""
        quantized = values.round().clamp(-4, 3)
        return values + (quantized - values).detach()

    @staticmethod
    def nnue_indices(codes: torch.Tensor) -> tuple[torch.Tensor, torch.Tensor, torch.Tensor]:
        """Return 2-side x 6-piece x 64 indices for both board perspectives."""
        mask = codes != 0
        absolute = codes.abs().to(torch.long).sub(1).clamp_min(0)
        piece = absolute.div(64, rounding_mode="floor")
        oriented_square = absolute.remainder(64)
        is_white = codes > 0
        actual_square = torch.where(is_white, oriented_square, oriented_square ^ 56)

        relative_square = torch.stack((actual_square, actual_square ^ 56), dim=1)
        relative_color = torch.stack((is_white, ~is_white), dim=1)
        category = torch.where(relative_color, piece[:, None, :], piece[:, None, :] + 6)
        valid = mask[:, None, :].expand(-1, 2, -1)
        indices = category * 64 + relative_square
        return indices, valid, mask

    def nnue_correction(self, codes: torch.Tensor) -> torch.Tensor:
        """Evaluate bias, clipped ReLU, and the direct output layer."""
        indices, valid, _ = self.nnue_indices(codes)
        ternary = self._ternary(self.feature_weights)
        # Embedding-bag fuses the feature gather and 32-piece reduction, avoiding
        # a batch-by-perspective-by-piece-by-channel temporary tensor.
        padded_weights = torch.cat((ternary.new_zeros((1, NNUE_ACCUMULATORS)), ternary))
        bag_indices = torch.where(valid, indices + 1, torch.zeros_like(indices))
        accumulators = torch.nn.functional.embedding_bag(
            bag_indices.reshape(-1, bag_indices.shape[-1]), padded_weights, mode="sum"
        ).reshape(codes.shape[0], 2, NNUE_ACCUMULATORS) + self._accumulator_bias_int3(
            self.accumulator_bias
        )
        # Hardware retains the low six bits so add/remove deltas remain exact
        # inverses even in the extremely rare event of an overflow.
        accumulators = torch.remainder(accumulators + 32, 64) - 32
        activations = accumulators.clamp(0, 31)
        weights = self._int4(self.output_weights)
        # A single head consumes the difference between color-relative
        # perspectives, making the deployed correction exactly antisymmetric.
        engine_units = ((activations[:, 0] - activations[:, 1]) * weights).sum(dim=1)
        return engine_units.clamp(-30999, 30999) * NNUE_ENGINE_UNIT_CP

    def forward(self, codes: torch.Tensor) -> torch.Tensor:
        mask = codes != 0
        indices = codes.abs().to(torch.long).sub(1).clamp_min(0)
        signs = codes.sign().to(self.terms["pst"].dtype)
        values = self.combined_cp().reshape(FEATURE_COUNT)[indices] * signs * mask
        return values.sum(dim=1) + self.nnue_correction(codes)
