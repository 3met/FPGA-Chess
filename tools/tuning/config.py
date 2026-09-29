"""Configuration loading and validation for evaluation tuning."""

from __future__ import annotations

import hashlib
import json
from pathlib import Path
from typing import Any


REPO_ROOT = Path(__file__).resolve().parents[2]
DEFAULT_CONFIG = Path(__file__).with_name("default_config.json")
CACHE_RECORD_FORMAT = "32-piece-turn-target-symmetry-group-split"


class ConfigError(ValueError):
    """Raised when a tuning configuration is invalid."""


def load_config(path: str | Path | None) -> dict[str, Any]:
    config_path = Path(path).resolve() if path else DEFAULT_CONFIG
    try:
        config = json.loads(config_path.read_text(encoding="utf-8"))
    except (OSError, json.JSONDecodeError) as exc:
        raise ConfigError(f"cannot load config {config_path}: {exc}") from exc
    _validate(config)
    config["dataset"]["path"] = str(_repo_path(config["dataset"]["path"]))
    config["output"]["root"] = str(_repo_path(config["output"]["root"]))
    config["_config_path"] = str(config_path)
    return config


def _repo_path(value: str) -> Path:
    path = Path(value)
    return path if path.is_absolute() else REPO_ROOT / path


def _validate(config: dict[str, Any]) -> None:
    required = {"dataset", "filters", "training", "output", "wandb"}
    missing = required - config.keys()
    if missing:
        raise ConfigError(f"missing config sections: {', '.join(sorted(missing))}")
    dataset = config["dataset"]
    training = config["training"]
    filters = config["filters"]
    for key in ("path", "max_positions"):
        if key not in dataset:
            raise ConfigError(f"dataset.{key} is required")
    for key in (
        "seed", "batch_size", "validation_size", "learning_rate", "max_steps",
        "device", "shuffle_buffer", "cpu_threads",
        "validation_interval_steps", "checkpoint_interval_steps", "early_stopping_patience",
    ):
        if key not in training:
            raise ConfigError(f"training.{key} is required")
    defaults = json.loads(DEFAULT_CONFIG.read_text(encoding="utf-8"))
    unknown_training = set(training) - set(defaults["training"])
    if unknown_training:
        raise ConfigError(f"unknown training settings: {', '.join(sorted(unknown_training))}")
    overflow_penalty = training.get("accumulator_overflow_penalty", 0.0)
    if not isinstance(overflow_penalty, (int, float)) or overflow_penalty < 0:
        raise ConfigError("training.accumulator_overflow_penalty must be nonnegative")
    microbatch_size = training.get("microbatch_size", "auto")
    if microbatch_size != "auto" and (
        not isinstance(microbatch_size, int)
        or microbatch_size < 1
        or microbatch_size > training["batch_size"]
    ):
        raise ConfigError(
            "training.microbatch_size must be 'auto' or a positive integer no larger than batch_size"
        )
    positive = (
        "batch_size", "learning_rate", "max_steps", "shuffle_buffer",
        "validation_interval_steps", "checkpoint_interval_steps",
    )
    for key in positive:
        if training[key] <= 0:
            raise ConfigError(f"training.{key} must be positive")
    if training["max_steps"] < 2:
        raise ConfigError("training.max_steps must be at least 2")
    patience = training["early_stopping_patience"]
    if patience is not None and (not isinstance(patience, int) or patience <= 0):
        raise ConfigError("training.early_stopping_patience must be a positive integer or null")
    if training["validation_size"] < 1:
        raise ConfigError("validation_size must be positive")
    for section, name, minimum in (
        (dataset, "num_workers", 1),
        (training, "cpu_threads", 1),
    ):
        value = section.get(name, "auto")
        if value != "auto" and (not isinstance(value, int) or value < minimum):
            qualifier = "nonnegative" if minimum == 0 else "positive"
            raise ConfigError(f"{name} must be 'auto' or a {qualifier} integer")
    if dataset.get("progress_interval_seconds", 5) <= 0:
        raise ConfigError("dataset.progress_interval_seconds must be positive")
    if (
        isinstance(dataset["max_positions"], bool)
        or not isinstance(dataset["max_positions"], int)
        or dataset["max_positions"] <= training["validation_size"]
    ):
        raise ConfigError("dataset.max_positions must exceed training.validation_size")
    for name in ("score_probability_offset", "score_probability_scale"):
        if not isinstance(training.get(name), (int, float)) or training[name] <= 0:
            raise ConfigError(f"training.{name} must be positive")
    final_factor = training.get("cosine_final_factor", 0.1)
    if not isinstance(final_factor, (int, float)) or not 0 < final_factor < 1:
        raise ConfigError("training.cosine_final_factor must be in (0, 1)")
    weight_decay = training.get("weight_decay", 0.0)
    if not isinstance(weight_decay, (int, float)) or weight_decay < 0:
        raise ConfigError("training.weight_decay must be nonnegative")
    for key in (
        "remove_in_check", "remove_captures", "remove_checks",
    ):
        if not isinstance(filters.get(key), bool):
            raise ConfigError(f"filters.{key} must be boolean")
    if "minimum_depth" not in filters or filters["minimum_depth"] < 0:
        raise ConfigError("filters.minimum_depth must be nonnegative")
    unknown_filters = set(filters) - set(defaults["filters"])
    if unknown_filters:
        raise ConfigError(f"unknown filters: {', '.join(sorted(unknown_filters))}")
    unknown_dataset = set(dataset) - set(defaults["dataset"])
    if unknown_dataset:
        raise ConfigError(f"unknown dataset settings: {', '.join(sorted(unknown_dataset))}")
    if filters.get("max_evaluation_cp") is not None and filters["max_evaluation_cp"] <= 0:
        raise ConfigError("filters.max_evaluation_cp must be positive or null")


def public_config(config: dict[str, Any]) -> dict[str, Any]:
    """Return the serializable portion used for cache keys and run snapshots."""
    return {key: value for key, value in config.items() if not key.startswith("_")}


def cache_key(config: dict[str, Any]) -> str:
    dataset = Path(config["dataset"]["path"])
    stat = dataset.stat()
    relevant = {
        "dataset": {
            "path": config["dataset"]["path"],
            "max_positions": config["dataset"]["max_positions"],
        },
        "filters": config["filters"],
        "validation_size": config["training"]["validation_size"],
        "source_size": stat.st_size,
        "source_mtime_ns": stat.st_mtime_ns,
        "record_format": CACHE_RECORD_FORMAT,
    }
    raw = json.dumps(relevant, sort_keys=True, separators=(",", ":")).encode()
    return hashlib.sha256(raw).hexdigest()[:16]
