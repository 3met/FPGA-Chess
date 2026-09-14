"""Mixed, quantized search-parameter space and JSON conversion helpers."""

from __future__ import annotations

import copy
import hashlib
import json
import math
from dataclasses import dataclass
from fractions import Fraction
from typing import Any


@dataclass(frozen=True)
class Parameter:
    """One scalar optimizer coordinate backed by a JSON leaf."""

    path: str
    low: float
    high: float
    kind: str = "int"
    step: float = 1.0
    maximum_denominator: int = 20

    def values(self) -> list[Any] | None:
        if self.kind != "fraction":
            return None
        values = {
            Fraction(numerator, denominator)
            for denominator in range(1, self.maximum_denominator + 1)
            for numerator in range(0, denominator + 1)
            if self.low <= numerator / denominator <= self.high
        }
        return [[value.numerator, value.denominator] for value in sorted(values)]

    def encode(self, value: Any) -> float:
        if self.kind == "fraction":
            value = value[0] / value[1]
        return min(1.0, max(0.0, (float(value) - self.low) / (self.high - self.low)))

    def decode(self, coordinate: float) -> Any:
        raw = self.low + min(1.0, max(0.0, coordinate)) * (self.high - self.low)
        if self.kind == "fraction":
            choices = self.values() or []
            return min(choices, key=lambda item: abs(item[0] / item[1] - raw))
        quantized = self.low + round((raw - self.low) / self.step) * self.step
        quantized = min(self.high, max(self.low, quantized))
        if self.kind == "int":
            return int(round(quantized))
        return float(round(quantized, 10))


# These bounds are deliberately local around a good engine while still spanning
# conservative through aggressive settings. Fixed-point fields use their exact
# hardware quantization so two optimizer points never synthesize identically.
DEFAULT_PARAMETERS = [
    Parameter("aspiration.starting_delta", 16, 256, step=8),
    Parameter("aspiration.delta_multiplier", 1.125, 3.0, "float", 0.125),
    Parameter("lmr.base", 0.25, 1.5, "float", 1 / 256),
    Parameter("lmr.divisor", 0.75, 5.0, "float", 1 / 256),
    Parameter("lmr.minimum_depth", 2, 7),
    Parameter("lmr.minimum_move_number", 2, 10),
    Parameter("null_move.minimum_depth", 2, 7),
    Parameter("null_move.deep_depth_threshold", 4, 14),
    Parameter("null_move.shallow_reduction", 1, 5),
    Parameter("null_move.deep_reduction", 2, 7),
    Parameter("rfp.base_margin", 0, 384, step=8),
    Parameter("rfp.margin_per_depth", 32, 320, step=8),
    Parameter("rfp.maximum_depth", 1, 9),
    Parameter("futility.base_margin", 32, 512, step=8),
    Parameter("futility.margin_per_depth", 32, 384, step=8),
    Parameter("futility.maximum_depth", 1, 7),
    Parameter("qsearch_delta_pruning.margin", 128, 768, step=8),
    Parameter("time_management.moves_to_go_buffer", 0, 6),
    Parameter("time_management.default_moves_divisor", 10, 40),
    Parameter("time_management.increment_fraction", 0.4, 1.0, "fraction", maximum_denominator=20),
    Parameter("time_management.hard_base_multiplier", 2, 8),
    Parameter("time_management.hard_time_fraction", 0.4, 1.0, "fraction", maximum_denominator=20),
    Parameter("time_management.soft_factor_default", 2, 8),
    Parameter("time_management.soft_factor_minimum", 1, 6),
    Parameter("time_management.soft_factor_maximum", 4, 14),
    Parameter("time_management.stable_depth_threshold", 1, 7),
    Parameter("time_management.score_drop_evalscore", 16, 192, step=8),
    Parameter("time_management.next_depth_fraction", 0.25, 0.9, "fraction", maximum_denominator=20),
    Parameter("time_management.single_legal_move_ms", 0, 40),
    Parameter("history.reward_per_depth", 1, 6),
    Parameter("history.maximum_reward", 15, 63),
    Parameter("history.malus_divisor", 1, 6),
    Parameter("history.quiet_bucket_thresholds.0", -32, 32, step=2),
    Parameter("history.quiet_bucket_thresholds.1", 8, 72, step=2),
    Parameter("history.quiet_bucket_thresholds.2", 32, 112, step=2),
    Parameter("history.castling_bonus", 0, 32),
    Parameter("transposition_table.history_validation_minimum_depth", 3, 14),
    Parameter("transposition_table.history_validation_bypass_halfmoves", 0, 12),
    Parameter("transposition_table.stale_entry_depth_tolerance", 0, 10),
]


def _parts(path: str) -> list[str | int]:
    return [int(part) if part.isdigit() else part for part in path.split(".")]


def get_path(value: dict, path: str) -> Any:
    current: Any = value
    for part in _parts(path):
        current = current[part]
    return current


def set_path(value: dict, path: str, item: Any) -> None:
    current: Any = value
    parts = _parts(path)
    for part in parts[:-1]:
        current = current[part]
    current[parts[-1]] = item


def configured_parameters(config: dict) -> list[Parameter]:
    """Apply optional enable/override configuration to the built-in safe space."""
    section = config.get("parameters", {})
    if not isinstance(section, dict):
        raise ValueError("parameters must be an object")
    enabled = section.get("enabled", ["*"])
    overrides = section.get("overrides", {})
    if not isinstance(enabled, list) or not all(isinstance(path, str) for path in enabled):
        raise ValueError("parameters.enabled must be a list of paths")
    if not isinstance(overrides, dict) or not all(
        isinstance(path, str) and isinstance(value, dict) for path, value in overrides.items()
    ):
        raise ValueError("parameters.overrides must map paths to objects")
    known = {parameter.path for parameter in DEFAULT_PARAMETERS}
    selected = known if enabled == ["*"] else set(enabled)
    unknown = (selected | set(overrides)) - known
    if unknown:
        raise ValueError("unknown parameter paths: " + ", ".join(sorted(unknown)))
    result = []
    for parameter in DEFAULT_PARAMETERS:
        if parameter.path not in selected:
            continue
        values = dict(parameter.__dict__)
        values.update(overrides.get(parameter.path, {}))
        try:
            candidate = Parameter(**values)
        except TypeError as exc:
            raise ValueError(f"invalid override for {parameter.path}: {exc}") from exc
        if (
            candidate.kind not in {"int", "float", "fraction"}
            or not all(math.isfinite(value) for value in (candidate.low, candidate.high, candidate.step))
            or not candidate.low < candidate.high
            or candidate.step <= 0
            or isinstance(candidate.maximum_denominator, bool)
            or not isinstance(candidate.maximum_denominator, int)
            or candidate.maximum_denominator < 1
            or (candidate.kind == "fraction" and not candidate.values())
        ):
            raise ValueError(f"invalid range for {candidate.path}")
        result.append(candidate)
    if not result:
        raise ValueError("at least one parameter must be enabled")
    return result


def vector_from_json(value: dict, parameters: list[Parameter]) -> list[float]:
    return [parameter.encode(get_path(value, parameter.path)) for parameter in parameters]


def json_from_vector(base: dict, vector: list[float], parameters: list[Parameter]) -> dict:
    """Decode and repair the few cross-field ordering constraints."""
    result = copy.deepcopy(base)
    for parameter, coordinate in zip(parameters, vector, strict=True):
        set_path(result, parameter.path, parameter.decode(coordinate))

    timing = result["time_management"]
    soft = sorted((timing["soft_factor_minimum"], timing["soft_factor_default"], timing["soft_factor_maximum"]))
    timing["soft_factor_minimum"], timing["soft_factor_default"], timing["soft_factor_maximum"] = soft

    thresholds = sorted(result["history"]["quiet_bucket_thresholds"])
    for index in range(1, len(thresholds)):
        thresholds[index] = max(thresholds[index], thresholds[index - 1] + 1)
    result["history"]["quiet_bucket_thresholds"] = thresholds

    null = result["null_move"]
    null["minimum_depth"] = max(null["minimum_depth"], null["shallow_reduction"] + 1)
    null["deep_depth_threshold"] = max(
        null["deep_depth_threshold"], null["minimum_depth"], null["deep_reduction"] + 1
    )
    return result


def parameter_hash(value: dict) -> str:
    canonical = json.dumps(value, sort_keys=True, separators=(",", ":")).encode()
    return hashlib.sha256(canonical).hexdigest()
