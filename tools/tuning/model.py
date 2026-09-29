"""Trainable material/PST plus hardware-shaped 12x64 NNUE evaluation."""

from __future__ import annotations

import json

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
NNUE_OUTPUT_INPUTS = NNUE_SIDES * NNUE_ACCUMULATORS
NNUE_OUTPUT_BUCKETS = 8
NNUE_ACCUMULATOR_BITS = 5
NNUE_ACCUMULATOR_BIAS_BITS = 4
NNUE_ACCUMULATOR_BIAS_MAX = (1 << NNUE_ACCUMULATOR_BIAS_BITS) - 1
NNUE_CLIPPED_ACCUMULATOR_BITS = NNUE_ACCUMULATOR_BITS - 1
NNUE_CLIPPED_ACCUMULATOR_MAX = (1 << NNUE_CLIPPED_ACCUMULATOR_BITS) - 1
NNUE_ACTIVATION_BITS = 3
NNUE_ACTIVATION_MAX = (1 << NNUE_ACTIVATION_BITS) - 1
NNUE_SCRELU_DIVISOR = 1 << NNUE_ACTIVATION_BITS
NNUE_SCRELU_TOP_CODE = NNUE_ACTIVATION_MAX
NNUE_OUTPUT_WEIGHT_BITS = 3
NNUE_OUTPUT_WEIGHT_MIN = -(1 << (NNUE_OUTPUT_WEIGHT_BITS - 1))
NNUE_OUTPUT_WEIGHT_MAX = (1 << (NNUE_OUTPUT_WEIGHT_BITS - 1)) - 1
NNUE_OUTPUT_BIAS_BITS = 6
NNUE_OUTPUT_BIAS_MAX = (1 << NNUE_OUTPUT_BIAS_BITS) - 1
NNUE_ENGINE_UNIT_CP = 100.0 / 128.0
NNUE_MAX_ENGINE_UNITS = 0x3FFF


def nnue_output_bucket(codes: torch.Tensor, bucket_count: int = NNUE_OUTPUT_BUCKETS) -> torch.Tensor:
    """Map the legal two-piece minimum upward into near-equal phase buckets."""
    piece_count = codes.ne(0).sum(dim=1)
    pieces_per_bucket = 32 // bucket_count
    scaled = piece_count.sub(2).clamp_min(0).div(
        pieces_per_bucket, rounding_mode="floor"
    )
    return scaled.clamp_max(bucket_count - 1).to(torch.long)


def pst_opening_phase(codes: torch.Tensor) -> torch.Tensor:
    """Return the legal two-to-32-piece interpolation numerator."""
    return codes.ne(0).sum(dim=1).sub(2).clamp(0, 30)


def _accumulator_overflow_penalty(accumulators: torch.Tensor) -> torch.Tensor:
    """Penalize wrapped lanes with a quadratic boundary and linear tail."""
    limit = 1 << (NNUE_ACCUMULATOR_BITS - 1)
    excess = (accumulators - accumulators.clamp(-limit, limit - 1)).abs()
    # Twice the unit-width Huber loss matches the old penalty at one code of
    # overflow, while deep wraps cannot dominate quadratically.
    return torch.where(excess <= 1, excess.square(), 2 * excess - 1).mean()


def _wrap_accumulators(accumulators: torch.Tensor) -> torch.Tensor:
    """Wrap accumulator sums using floor arithmetic with a unit straight-through gradient."""
    modulus = 1 << NNUE_ACCUMULATOR_BITS
    return accumulators - modulus * torch.floor((accumulators + modulus // 2) / modulus)


def _squared_clipped_activation(accumulators: torch.Tensor) -> torch.Tensor:
    """Apply the integer SCReLU lookup while retaining a useful QAT gradient."""
    clipped = accumulators.clamp(0, NNUE_CLIPPED_ACCUMULATOR_MAX)
    scaled = clipped.square().div(NNUE_SCRELU_DIVISOR).clamp_max(NNUE_ACTIVATION_MAX)
    return scaled + (scaled.floor() - scaled).detach()


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
        output_buckets: int = NNUE_OUTPUT_BUCKETS,
    ):
        super().__init__()
        if output_buckets < 1 or output_buckets > 32 or 32 % output_buckets:
            raise ValueError("NNUE output bucket count must divide 32")
        self.output_buckets = output_buckets
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
            "material_endgame": nn.Parameter(material[1:5].clone()),
            "pst_endgame": nn.Parameter(pst.reshape(FEATURE_COUNT).clone()),
        })
        # Pair-identical sparse channels cancel against the alternating
        # head at startup, while every quantized parameter still has a gradient.
        pair_rows = torch.arange(NNUE_FEATURE_COUNT, dtype=torch.int64)[:, None]
        pair_lanes = torch.arange(NNUE_ACCUMULATORS // 2, dtype=torch.int64)[None, :]
        pair_codes = (pair_rows * 37 + pair_lanes * 19) % 10
        pair_weights = torch.where(pair_codes == 0, 1.0,
            torch.where(pair_codes == 1, -1.0, 0.0))
        self.feature_weights = nn.Parameter(pair_weights.repeat_interleave(2, dim=1))
        # Center most sparse sums inside the clipped activation's live range;
        # alternating nonzero output lanes still give an exact zero correction.
        self.accumulator_bias = nn.Parameter(torch.full((NNUE_ACCUMULATORS,), 2.0))
        initial_output = torch.tensor([1.0, -1.0]).repeat(NNUE_OUTPUT_INPUTS // 2)
        self.output_weights = nn.Parameter(initial_output.repeat(output_buckets, 1))
        self.output_bias = nn.Parameter(torch.zeros(output_buckets))
        pst_mask = torch.ones((6, 64), dtype=pst.dtype)
        pst_mask[0, :8] = 0
        pst_mask[0, 56:] = 0
        self.register_buffer("_pst_mask", pst_mask)
        # Decode direct piece-square codes once; this table moves with the model
        # and is derived data rather than a checkpoint parameter.
        codes = torch.arange(-FEATURE_COUNT, FEATURE_COUNT + 1, dtype=torch.int16)
        index_lut = self.nnue_indices(codes[:, None])[0][:, :, 0]
        self.register_buffer("_nnue_index_lut", index_lut, persistent=False)
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

    def material_endgame_cp(self) -> torch.Tensor:
        """Return endgame material values with fixed pawn and king terms."""
        fixed = self.terms["material_endgame"].new_tensor
        return torch.cat((
            fixed([FIXED_MATERIAL_CP["pawn"]]),
            self.terms["material_endgame"],
            fixed([FIXED_MATERIAL_CP["king"]]),
        ))

    def pst_endgame_cp(self) -> torch.Tensor:
        """Return the endgame PST with unreachable pawn entries fixed at zero."""
        return self.terms["pst_endgame"].reshape(6, 64) * self._pst_mask

    def combined_endgame_cp(self) -> torch.Tensor:
        """Return the effective endgame material-plus-PST table."""
        return self.material_endgame_cp()[:, None] + self.pst_endgame_cp()

    def combined_cp(self) -> torch.Tensor:
        """Return the effective combined material-plus-PST table."""
        return self.material_cp()[:, None] + self.pst_cp()

    @torch.no_grad()
    def project_parameters(self) -> None:
        """Keep identifiable PST values and latent QAT parameters in their legal ranges."""
        for suffix in ("", "_endgame"):
            pst = self.terms[f"pst{suffix}"].reshape(6, 64)
            pst[0, :8] = 0
            pst[0, 56:] = 0
            for piece_index in range(1, 5):
                center = (pst[piece_index].min() + pst[piece_index].max()) / 2.0
                pst[piece_index].sub_(center)
                self.terms[f"material{suffix}"][piece_index - 1].add_(center)
            king_center = (pst[5].min() + pst[5].max()) / 2.0
            pst[5].sub_(king_center)
        # Projecting the latent values prevents straight-through gradients from
        # stranding parameters far beyond a deployable quantization bin.
        self.feature_weights.clamp_(-2, 1)
        self.accumulator_bias.clamp_(0, NNUE_ACCUMULATOR_BIAS_MAX)
        self.output_weights.clamp_(NNUE_OUTPUT_WEIGHT_MIN, NNUE_OUTPUT_WEIGHT_MAX)
        self.output_bias.clamp_(0, NNUE_OUTPUT_BIAS_MAX)

    @staticmethod
    def _feature_int2(values: torch.Tensor) -> torch.Tensor:
        """Use every signed two-bit feature code with a straight-through gradient."""
        quantized = values.round().clamp(-2, 1)
        return values + (quantized - values).detach()

    @staticmethod
    def _output_weight_quantized(values: torch.Tensor) -> torch.Tensor:
        """Quantize output weights to the target signed range."""
        quantized = values.round().clamp(NNUE_OUTPUT_WEIGHT_MIN, NNUE_OUTPUT_WEIGHT_MAX)
        return values + (quantized - values).detach()

    @staticmethod
    def _accumulator_bias_quantized(values: torch.Tensor) -> torch.Tensor:
        """Quantize the trained accumulator bias to its target unsigned range."""
        quantized = values.round().clamp(0, NNUE_ACCUMULATOR_BIAS_MAX)
        return values + (quantized - values).detach()

    @staticmethod
    def _output_bias_quantized(value: torch.Tensor) -> torch.Tensor:
        """Quantize the output bias to its deployed unsigned range."""
        quantized = value.round().clamp(0, NNUE_OUTPUT_BIAS_MAX)
        return value + (quantized - value).detach()

    @staticmethod
    def _engine_units(values: torch.Tensor) -> torch.Tensor:
        """Round material/PST shadows as export does, retaining their gradients."""
        scaled = values / NNUE_ENGINE_UNIT_CP
        quantized = scaled.sign() * torch.floor(scaled.abs() + 0.5)
        return scaled + (quantized - scaled).detach()

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

    def _nnue_correction(
        self,
        codes: torch.Tensor,
        white_to_move: torch.Tensor,
        phase: torch.Tensor | None = None,
    ) -> tuple[torch.Tensor, torch.Tensor]:
        """Evaluate the correction and a differentiable accumulator overflow penalty."""
        indices = self._nnue_index_lut[
            codes.to(torch.long) + FEATURE_COUNT
        ].permute(0, 2, 1)
        valid = codes.ne(0)[:, None, :]
        feature_weights = self._feature_int2(self.feature_weights)
        # Embedding-bag fuses the feature gather and 32-piece reduction, avoiding
        # a batch-by-perspective-by-piece-by-channel temporary tensor.
        padded_weights = torch.cat((
            feature_weights.new_zeros((1, NNUE_ACCUMULATORS)), feature_weights
        ))
        bag_indices = torch.where(valid, indices + 1, torch.zeros_like(indices))
        accumulators = torch.nn.functional.embedding_bag(
            bag_indices.reshape(-1, bag_indices.shape[-1]), padded_weights, mode="sum"
        ).reshape(codes.shape[0], 2, NNUE_ACCUMULATORS) + self._accumulator_bias_quantized(
            self.accumulator_bias
        )
        # Modular add/remove deltas remain exact inverses even across a wrap.
        overflow_penalty = _accumulator_overflow_penalty(accumulators)
        accumulators = _wrap_accumulators(accumulators)
        activations = _squared_clipped_activation(accumulators)
        white_to_move = white_to_move.to(device=codes.device, dtype=torch.bool)
        first = torch.where(white_to_move[:, None], activations[:, 0], activations[:, 1])
        second = torch.where(white_to_move[:, None], activations[:, 1], activations[:, 0])
        ordered_activations = torch.cat((first, second), dim=1)
        if phase is None:
            phase = pst_opening_phase(codes)
        buckets = phase.div(32 // self.output_buckets, rounding_mode="floor")
        buckets = buckets.clamp_max(self.output_buckets - 1).to(torch.long)
        weights = self._output_weight_quantized(self.output_weights)[buckets]
        # Ordering by side to move makes color-flipped positions share exactly
        # the same output without constraining the two halves of the head.
        output_bias = self._output_bias_quantized(self.output_bias)[buckets]
        engine_units = (ordered_activations * weights).sum(dim=1) + output_bias
        correction = engine_units.clamp(
            -NNUE_MAX_ENGINE_UNITS, NNUE_MAX_ENGINE_UNITS
        ) * NNUE_ENGINE_UNIT_CP
        return correction, overflow_penalty

    def nnue_correction(
        self,
        codes: torch.Tensor,
        white_to_move: torch.Tensor,
    ) -> torch.Tensor:
        """Evaluate the deployed side-to-move-relative NNUE correction."""
        return self._nnue_correction(codes, white_to_move)[0]

    def forward(
        self,
        codes: torch.Tensor,
        white_to_move: torch.Tensor,
        return_overflow_penalty: bool = False,
    ) -> torch.Tensor | tuple[torch.Tensor, torch.Tensor]:
        """Evaluate a position and optionally return the QAT overflow penalty."""
        # Zero codes may index the final table entry: their zero sign removes
        # both the value and its gradient without a separate mask operation.
        indices = codes.abs().to(torch.long).sub(1)
        signs = codes.sign().to(self.terms["pst"].dtype)
        opening_table = (
            self._engine_units(self.material_cp())[:, None]
            + self._engine_units(self.pst_cp())
        ).reshape(FEATURE_COUNT)
        endgame_table = (
            self._engine_units(self.material_endgame_cp())[:, None]
            + self._engine_units(self.pst_endgame_cp())
        ).reshape(FEATURE_COUNT)
        opening = opening_table[indices] * signs
        endgame = endgame_table[indices] * signs
        opening_sum = opening.sum(dim=1)
        endgame_sum = endgame.sum(dim=1)
        phase = pst_opening_phase(codes).to(opening_sum.dtype)
        blended = (opening_sum * phase + endgame_sum * (30.0 - phase)) / 30.0
        # RTL truncates the signed blend toward zero after accumulating integer scores.
        white_relative = blended + (torch.trunc(blended) - blended).detach()
        stm_sign = torch.where(
            white_to_move.to(device=codes.device, dtype=torch.bool),
            white_relative.new_tensor(1.0),
            white_relative.new_tensor(-1.0),
        )
        correction, overflow_penalty = self._nnue_correction(codes, white_to_move, phase)
        prediction = white_relative * NNUE_ENGINE_UNIT_CP + stm_sign * correction
        if return_overflow_penalty:
            return prediction, overflow_penalty
        return prediction
