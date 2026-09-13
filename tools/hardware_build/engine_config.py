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


def engine_rtl_parameter_values(config: dict) -> dict[str, int]:
    """Translate one resolved engine profile into the shared RTL parameters."""
    search = config["search"]
    thresholds = search["quiet_bucket_thresholds"]
    increment = search["increment_fraction"]
    hard_time = search["hard_time_fraction"]
    next_depth = search["next_depth_fraction"]
    return {
        "SEARCH_THREAD_COUNT": config["threads"],
        "SEARCH_STACK_DEPTH": config["stack_depth"],
        "TT_TAG_BITS": config["tt_tag_bits"],
        "TT_CACHE_INDEX_BITS": config["tt_cache_index_bits"],
        "HISTORY_ENTRY_COUNT": config["history_entry_count"],
        "HISTORY_ENTRY_BITS": config["history_entry_bits"],
        "ENABLE_SEARCH_STATS": int(config["search_statistics"]),
        "ASPIRATION_STARTING_DELTA": search["aspiration_starting_delta"],
        "ASPIRATION_DELTA_MULTIPLIER_Q3": search["aspiration_delta_multiplier_q3"],
        "LMR_A_Q8": search["lmr_a_q8"],
        "LMR_B_Q8": search["lmr_b_q8"],
        "LMR_MINIMUM_DEPTH": search["lmr_minimum_depth"],
        "LMR_MINIMUM_MOVE_NUMBER": search["lmr_minimum_move_number"],
        "NULL_MINIMUM_DEPTH": search["null_minimum_depth"],
        "NULL_DEEP_DEPTH_THRESHOLD": search["null_deep_depth_threshold"],
        "NULL_SHALLOW_REDUCTION": search["null_shallow_reduction"],
        "NULL_DEEP_REDUCTION": search["null_deep_reduction"],
        "RFP_BASE_MARGIN": search["rfp_base_margin"],
        "RFP_MARGIN_PER_DEPTH": search["rfp_margin_per_depth"],
        "RFP_MAXIMUM_DEPTH": search["rfp_maximum_depth"],
        "FUTILITY_BASE_MARGIN": search["futility_base_margin"],
        "FUTILITY_MARGIN_PER_DEPTH": search["futility_margin_per_depth"],
        "FUTILITY_MAXIMUM_DEPTH": search["futility_maximum_depth"],
        "QDELTA_MARGIN": search["qdelta_margin"],
        "MOVES_TO_GO_BUFFER": search["moves_to_go_buffer"],
        "DEFAULT_MOVES_DIVISOR": search["default_moves_divisor"],
        "INCREMENT_NUMERATOR": increment[0],
        "INCREMENT_DENOMINATOR": increment[1],
        "HARD_BASE_MULTIPLIER": search["hard_base_multiplier"],
        "HARD_TIME_NUMERATOR": hard_time[0],
        "HARD_TIME_DENOMINATOR": hard_time[1],
        "SOFT_FACTOR_DEFAULT": search["soft_factor_default"],
        "SOFT_FACTOR_MINIMUM": search["soft_factor_minimum"],
        "SOFT_FACTOR_MAXIMUM": search["soft_factor_maximum"],
        "STABLE_DEPTH_THRESHOLD": search["stable_depth_threshold"],
        "SCORE_DROP_THRESHOLD": search["score_drop_evalscore"],
        "NEXT_DEPTH_NUMERATOR": next_depth[0],
        "NEXT_DEPTH_DENOMINATOR": next_depth[1],
        "SINGLE_LEGAL_MOVE_MS": search["single_legal_move_ms"],
        "HISTORY_REWARD_PER_DEPTH": search["history_reward_per_depth"],
        "HISTORY_MAXIMUM_REWARD": search["history_maximum_reward"],
        "HISTORY_MALUS_DIVISOR": search["history_malus_divisor"],
        "QUIET_THRESHOLD_1": thresholds[0],
        "QUIET_THRESHOLD_2": thresholds[1],
        "QUIET_THRESHOLD_3": thresholds[2],
        "CASTLING_HISTORY_BONUS": search["castling_history_bonus"],
        "TT_VALIDATE_MINIMUM_DEPTH": search["tt_history_validation_minimum_depth"],
        "TT_VALIDATE_BYPASS_HALFMOVES": search["tt_history_validation_bypass_halfmoves"],
        "TT_STALE_DEPTH_TOLERANCE": search["tt_stale_entry_depth_tolerance"],
    }


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
        {
            "aspiration", "lmr", "null_move", "rfp", "futility", "qsearch_delta_pruning",
            "time_management", "history", "transposition_table",
        },
        context,
    )
    aspiration = _object(search, "aspiration", context)
    lmr = _object(search, "lmr", context)
    null_move = _object(search, "null_move", context)
    rfp = _object(search, "rfp", context)
    futility = _object(search, "futility", context)
    qdelta = _object(search, "qsearch_delta_pruning", context)
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
        rfp,
        {"base_margin", "margin_per_depth", "maximum_depth"},
        f"{context}.rfp",
    )
    _require_keys(
        futility,
        {"base_margin", "margin_per_depth", "maximum_depth"},
        f"{context}.futility",
    )
    _require_keys(qdelta, {"margin"}, f"{context}.qsearch_delta_pruning")
    _require_keys(
        timing,
        {
            "moves_to_go_buffer", "default_moves_divisor", "increment_fraction",
            "hard_base_multiplier", "hard_time_fraction", "soft_factor_default",
            "soft_factor_minimum", "soft_factor_maximum", "stable_depth_threshold",
            "score_drop_evalscore", "next_depth_fraction", "single_legal_move_ms",
        },
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

    soft_factor_default = _integer(
        timing, "soft_factor_default", f"{context}.time_management", 1
    )
    soft_factor_minimum = _integer(
        timing, "soft_factor_minimum", f"{context}.time_management", 1
    )
    soft_factor_maximum = _integer(
        timing, "soft_factor_maximum", f"{context}.time_management", 1
    )
    if not soft_factor_minimum <= soft_factor_default <= soft_factor_maximum:
        raise BuildError(
            f"{context}.time_management soft factors must satisfy minimum <= default <= maximum"
        )

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
        "rfp_base_margin": _integer(rfp, "base_margin", f"{context}.rfp", 0, 32767),
        "rfp_margin_per_depth": _integer(rfp, "margin_per_depth", f"{context}.rfp", 0, 32767),
        "rfp_maximum_depth": _integer(rfp, "maximum_depth", f"{context}.rfp", 1),
        "futility_base_margin": _integer(
            futility, "base_margin", f"{context}.futility", 0, 32767
        ),
        "futility_margin_per_depth": _integer(
            futility, "margin_per_depth", f"{context}.futility", 0, 32767
        ),
        "futility_maximum_depth": _integer(
            futility, "maximum_depth", f"{context}.futility", 1
        ),
        "qdelta_margin": _integer(
            qdelta, "margin", f"{context}.qsearch_delta_pruning", 0, 32767
        ),
        "moves_to_go_buffer": _integer(timing, "moves_to_go_buffer", f"{context}.time_management"),
        "default_moves_divisor": _integer(timing, "default_moves_divisor", f"{context}.time_management", 1),
        "increment_fraction": _fraction(timing, "increment_fraction", f"{context}.time_management"),
        "hard_base_multiplier": _integer(timing, "hard_base_multiplier", f"{context}.time_management", 1),
        "hard_time_fraction": _fraction(timing, "hard_time_fraction", f"{context}.time_management"),
        "soft_factor_default": soft_factor_default,
        "soft_factor_minimum": soft_factor_minimum,
        "soft_factor_maximum": soft_factor_maximum,
        "stable_depth_threshold": _integer(timing, "stable_depth_threshold", f"{context}.time_management", 1),
        "score_drop_evalscore": _integer(
            timing, "score_drop_evalscore", f"{context}.time_management", 0, 32767
        ),
        "next_depth_fraction": _fraction(timing, "next_depth_fraction", f"{context}.time_management"),
        "single_legal_move_ms": _integer(timing, "single_legal_move_ms", f"{context}.time_management"),
        "history_reward_per_depth": _integer(history, "reward_per_depth", f"{context}.history", 1),
        "history_maximum_reward": _integer(history, "maximum_reward", f"{context}.history", 1),
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
        {"search_config", "engine", "transposition_table", "history_heuristic", "instrumentation"},
        rel(engine_path),
    )
    search_value = engine_profile.get("search_config")
    if not isinstance(search_value, str) or not search_value:
        raise BuildError(f"Engine configuration {rel(engine_path)}.search_config must be a repository path")
    search_path = repo_path(search_value)
    search = _validate_search(_load_object(search_path, "search configuration"), search_path)
    engine = _object(engine_profile, "engine", rel(engine_path))
    tt = _object(engine_profile, "transposition_table", rel(engine_path))
    history = _object(engine_profile, "history_heuristic", rel(engine_path))
    instrumentation = _object(engine_profile, "instrumentation", rel(engine_path))
    _require_keys(engine, {"threads", "stack_depth", "clock_frequency_hz"}, f"{rel(engine_path)}.engine")
    _require_keys(tt, {"tag_bits", "cache_index_bits"}, f"{rel(engine_path)}.transposition_table")
    _require_keys(history, {"entry_count", "entry_bits"}, f"{rel(engine_path)}.history_heuristic")
    _require_keys(instrumentation, {"search_statistics"}, f"{rel(engine_path)}.instrumentation")
    resolved = {
        "engine_config": rel(engine_path),
        "search_config": rel(search_path),
        "threads": _integer(engine, "threads", f"{rel(engine_path)}.engine", 1),
        "stack_depth": _integer(engine, "stack_depth", f"{rel(engine_path)}.engine", 1),
        "clock_frequency_hz": _integer(engine, "clock_frequency_hz", f"{rel(engine_path)}.engine", 1),
        "tt_tag_bits": _integer(tt, "tag_bits", f"{rel(engine_path)}.transposition_table", 1, 63),
        "tt_cache_index_bits": _integer(tt, "cache_index_bits", f"{rel(engine_path)}.transposition_table", 1),
        "history_entry_count": _integer(history, "entry_count", f"{rel(engine_path)}.history_heuristic", 2),
        "history_entry_bits": _integer(history, "entry_bits", f"{rel(engine_path)}.history_heuristic", 2),
        "search_statistics": _boolean(instrumentation, "search_statistics", f"{rel(engine_path)}.instrumentation"),
        "search": search,
    }
    if search["rfp_maximum_depth"] > resolved["stack_depth"]:
        raise BuildError(
            f"{rel(engine_path)} RFP maximum depth must not exceed the engine stack depth"
        )
    if search["futility_maximum_depth"] >= resolved["stack_depth"]:
        raise BuildError(
            f"{rel(engine_path)} futility maximum predicted depth must be smaller than the engine stack depth"
        )
    if resolved["history_entry_count"] & (resolved["history_entry_count"] - 1):
        raise BuildError(f"{rel(engine_path)}.history_heuristic.entry_count must be a power of two")
    history_maximum = (1 << (resolved["history_entry_bits"] - 1)) - 1
    if search["history_maximum_reward"] > history_maximum:
        raise BuildError(
            f"{rel(search_path)}.history.maximum_reward must fit the configured history entry width"
        )
    if search["castling_history_bonus"] > history_maximum:
        raise BuildError(
            f"{rel(search_path)}.history.castling_bonus must fit the configured history entry width"
        )
    if any(value < -history_maximum - 1 or value > history_maximum
            for value in search["quiet_bucket_thresholds"]):
        raise BuildError(
            f"{rel(search_path)}.history.quiet_bucket_thresholds must fit the configured history entry width"
        )
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
