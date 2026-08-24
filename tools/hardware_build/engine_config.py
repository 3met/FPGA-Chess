"""Load and validate layered engine and search configurations."""

from __future__ import annotations

import hashlib
import json
import math
from pathlib import Path

from .common import BuildError, rel, repo_path


def engine_config_digest(config: dict) -> str:
    """Hash a resolved profile without recursively including an old digest."""
    canonical_value = {key: value for key, value in config.items() if key != "digest"}
    canonical = json.dumps(canonical_value, sort_keys=True, separators=(",", ":")).encode()
    return hashlib.sha256(canonical).hexdigest()


def _load_object(path: Path, label: str) -> dict:
    try:
        value = json.loads(path.read_text(encoding="utf-8"))
    except (OSError, json.JSONDecodeError) as exc:
        raise BuildError(f"Could not load {label} {rel(path)}: {exc}") from exc
    if not isinstance(value, dict):
        raise BuildError(f"{label.capitalize()} {rel(path)} must contain a JSON object")
    return value


def _object(parent: dict, name: str, context: str) -> dict:
    value = parent.get(name)
    if not isinstance(value, dict):
        raise BuildError(f"{context}.{name} must be an object")
    return value


def _require_keys(value: dict, required: set[str], context: str) -> None:
    missing = sorted(required - value.keys())
    extra = sorted(value.keys() - required)
    if missing or extra:
        details = []
        if missing:
            details.append("missing " + ", ".join(missing))
        if extra:
            details.append("unknown " + ", ".join(extra))
        raise BuildError(f"{context} has {'; '.join(details)}")


def _integer(
    parent: dict,
    name: str,
    context: str,
    minimum: int = 0,
    maximum: int | None = None,
) -> int:
    value = parent.get(name)
    if (
        isinstance(value, bool)
        or not isinstance(value, int)
        or value < minimum
        or (maximum is not None and value > maximum)
    ):
        limit = f" between {minimum} and {maximum}" if maximum is not None else f" of at least {minimum}"
        raise BuildError(f"{context}.{name} must be an integer{limit}")
    return value


def _positive_number(parent: dict, name: str, context: str) -> float:
    value = parent.get(name)
    if isinstance(value, bool) or not isinstance(value, (int, float)) or not math.isfinite(value) or value <= 0:
        raise BuildError(f"{context}.{name} must be a positive finite number")
    return float(value)


def _boolean(parent: dict, name: str, context: str) -> bool:
    value = parent.get(name)
    if not isinstance(value, bool):
        raise BuildError(f"{context}.{name} must be a boolean")
    return value


def _fraction(parent: dict, name: str, context: str) -> list[int]:
    value = parent.get(name)
    if (
        not isinstance(value, list)
        or len(value) != 2
        or any(isinstance(item, bool) or not isinstance(item, int) for item in value)
        or value[0] < 0
        or value[1] <= 0
        or value[0] > value[1]
    ):
        raise BuildError(f"{context}.{name} must be a fraction between zero and one")
    return value


def _validate_search(search: dict, path: Path) -> dict:
    context = rel(path)
    _require_keys(
        search,
        {"aspiration", "lmr", "null_move", "time_management", "history", "transposition_table"},
        context,
    )
    aspiration = _object(search, "aspiration", context)
    lmr = _object(search, "lmr", context)
    null_move = _object(search, "null_move", context)
    timing = _object(search, "time_management", context)
    history = _object(search, "history", context)
    tt = _object(search, "transposition_table", context)
    _require_keys(aspiration, {"starting_delta", "delta_multiplier"}, f"{context}.aspiration")
    _require_keys(lmr, {"base", "divisor", "minimum_depth", "minimum_move_number"}, f"{context}.lmr")
    _require_keys(
        null_move,
        {"minimum_depth", "deep_depth_threshold", "shallow_reduction", "deep_reduction"},
        f"{context}.null_move",
    )
    _require_keys(
        timing,
        {"move_overhead_ms", "minimum_search_ms", "increment_fraction", "remaining_time_fraction"},
        f"{context}.time_management",
    )
    _require_keys(
        history,
        {"reward_per_depth", "maximum_reward", "malus_divisor", "quiet_bucket_thresholds", "castling_bonus"},
        f"{context}.history",
    )
    _require_keys(
        tt,
        {"history_validation_minimum_depth", "history_validation_bypass_halfmoves", "stale_entry_depth_tolerance"},
        f"{context}.transposition_table",
    )

    thresholds = history.get("quiet_bucket_thresholds")
    if (
        not isinstance(thresholds, list)
        or len(thresholds) != 3
        or any(isinstance(value, bool) or not isinstance(value, int) for value in thresholds)
        or not thresholds[0] < thresholds[1] < thresholds[2]
    ):
        raise BuildError(f"{context}.history.quiet_bucket_thresholds must be three ascending integers")

    base = _positive_number(lmr, "base", f"{context}.lmr")
    divisor = _positive_number(lmr, "divisor", f"{context}.lmr")
    base_q8 = round(base * 256)
    divisor_q8 = round(divisor * 256)
    if base_q8 <= 0 or divisor_q8 <= 0:
        raise BuildError(f"{context}.lmr coefficients are too small for unsigned Q8 representation")

    aspiration_multiplier = _positive_number(
        aspiration, "delta_multiplier", f"{context}.aspiration"
    )
    aspiration_multiplier_q3 = round(aspiration_multiplier * 8)
    if aspiration_multiplier_q3 <= 8:
        raise BuildError(f"{context}.aspiration.delta_multiplier must be greater than one")
    if aspiration_multiplier_q3 > 64:
        raise BuildError(f"{context}.aspiration.delta_multiplier must not exceed eight")

    null_minimum_depth = _integer(null_move, "minimum_depth", f"{context}.null_move", 1)
    null_deep_depth_threshold = _integer(null_move, "deep_depth_threshold", f"{context}.null_move", 1)
    null_shallow_reduction = _integer(null_move, "shallow_reduction", f"{context}.null_move", 1)
    null_deep_reduction = _integer(null_move, "deep_reduction", f"{context}.null_move", 1)
    if null_deep_depth_threshold < null_minimum_depth:
        raise BuildError(f"{context}.null_move.deep_depth_threshold must not precede minimum_depth")
    if null_shallow_reduction >= null_minimum_depth or null_deep_reduction >= null_deep_depth_threshold:
        raise BuildError(f"{context}.null_move reductions must be smaller than their depth thresholds")

    return {
        "aspiration_starting_delta": _integer(
            aspiration, "starting_delta", f"{context}.aspiration", 1, 32767
        ),
        "aspiration_delta_multiplier_q3": aspiration_multiplier_q3,
        "lmr_a_q8": base_q8,
        "lmr_b_q8": divisor_q8,
        "lmr_minimum_depth": _integer(lmr, "minimum_depth", f"{context}.lmr", 1),
        "lmr_minimum_move_number": _integer(lmr, "minimum_move_number", f"{context}.lmr", 1),
        "null_minimum_depth": null_minimum_depth,
        "null_deep_depth_threshold": null_deep_depth_threshold,
        "null_shallow_reduction": null_shallow_reduction,
        "null_deep_reduction": null_deep_reduction,
        "move_overhead_ms": _integer(timing, "move_overhead_ms", f"{context}.time_management"),
        "minimum_search_ms": _integer(timing, "minimum_search_ms", f"{context}.time_management"),
        "increment_fraction": _fraction(timing, "increment_fraction", f"{context}.time_management"),
        "remaining_time_fraction": _fraction(timing, "remaining_time_fraction", f"{context}.time_management"),
        "history_reward_per_depth": _integer(history, "reward_per_depth", f"{context}.history", 1),
        "history_maximum_reward": _integer(history, "maximum_reward", f"{context}.history", 1, 127),
        "history_malus_divisor": _integer(history, "malus_divisor", f"{context}.history", 1),
        "quiet_bucket_thresholds": thresholds,
        "castling_history_bonus": _integer(history, "castling_bonus", f"{context}.history"),
        "tt_history_validation_minimum_depth": _integer(tt, "history_validation_minimum_depth", f"{context}.transposition_table"),
        "tt_history_validation_bypass_halfmoves": _integer(tt, "history_validation_bypass_halfmoves", f"{context}.transposition_table"),
        "tt_stale_entry_depth_tolerance": _integer(tt, "stale_entry_depth_tolerance", f"{context}.transposition_table"),
    }


def load_engine_config(value: str) -> dict:
    """Resolve one FPGA engine profile and its referenced search policy."""
    engine_path = repo_path(value)
    engine_profile = _load_object(engine_path, "engine configuration")
    _require_keys(
        engine_profile,
        {"search_config", "engine", "transposition_table", "instrumentation"},
        rel(engine_path),
    )
    search_value = engine_profile.get("search_config")
    if not isinstance(search_value, str) or not search_value:
        raise BuildError(f"Engine configuration {rel(engine_path)}.search_config must be a repository path")
    search_path = repo_path(search_value)
    search = _validate_search(_load_object(search_path, "search configuration"), search_path)
    engine = _object(engine_profile, "engine", rel(engine_path))
    tt = _object(engine_profile, "transposition_table", rel(engine_path))
    instrumentation = _object(engine_profile, "instrumentation", rel(engine_path))
    _require_keys(engine, {"threads", "stack_depth", "clock_frequency_hz"}, f"{rel(engine_path)}.engine")
    _require_keys(tt, {"tag_bits", "cache_index_bits"}, f"{rel(engine_path)}.transposition_table")
    _require_keys(instrumentation, {"search_statistics"}, f"{rel(engine_path)}.instrumentation")
    resolved = {
        "engine_config": rel(engine_path),
        "search_config": rel(search_path),
        "threads": _integer(engine, "threads", f"{rel(engine_path)}.engine", 1),
        "stack_depth": _integer(engine, "stack_depth", f"{rel(engine_path)}.engine", 1),
        "clock_frequency_hz": _integer(engine, "clock_frequency_hz", f"{rel(engine_path)}.engine", 1),
        "tt_tag_bits": _integer(tt, "tag_bits", f"{rel(engine_path)}.transposition_table", 1, 63),
        "tt_cache_index_bits": _integer(tt, "cache_index_bits", f"{rel(engine_path)}.transposition_table", 1),
        "search_statistics": _boolean(instrumentation, "search_statistics", f"{rel(engine_path)}.instrumentation"),
        "search": search,
    }
    resolved["digest"] = engine_config_digest(resolved)
    return resolved


def engine_config_for_target(target: dict) -> dict | None:
    value = target.get("engine_config")
    if value is None:
        return None
    if not isinstance(value, str) or not value:
        raise BuildError("Synthesis target engine_config must be a nonempty repository path")
    return load_engine_config(value)


def engine_clock_mhz_for_target(target: dict) -> float | None:
    """Return the target clock from its engine profile or legacy manifest field."""
    config = engine_config_for_target(target)
    if config is not None:
        return config["clock_frequency_hz"] / 1_000_000
    return target.get("engine_clock_mhz")
