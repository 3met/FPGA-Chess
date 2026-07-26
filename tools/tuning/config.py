"""Configuration loading and validation for evaluation tuning."""

from __future__ import annotations

import hashlib
import json
from pathlib import Path
from typing import Any


REPO_ROOT = Path(__file__).resolve().parents[2]
DEFAULT_CONFIG = Path(__file__).with_name("default_config.json")


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
        "optimizer", "loss", "device", "shuffle_buffer", "cpu_threads",
        "validation_interval_steps", "checkpoint_interval_steps", "early_stopping_patience",
    ):
        if key not in training:
            raise ConfigError(f"training.{key} is required")
    positive = (
        "batch_size", "learning_rate", "max_steps", "shuffle_buffer",
        "validation_interval_steps", "checkpoint_interval_steps",
    )
    for key in positive:
        if training[key] <= 0:
            raise ConfigError(f"training.{key} must be positive")
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
    if dataset["max_positions"] is not None and dataset["max_positions"] <= training["validation_size"]:
        raise ConfigError("dataset.max_positions must exceed training.validation_size")
    if training["loss"] not in {"huber", "mse"}:
        raise ConfigError("training.loss must be 'huber' or 'mse'")
    if training["optimizer"] not in {"adamw", "adam", "sgd"}:
        raise ConfigError("training.optimizer must be adamw, adam, or sgd")
    if training.get("scheduler", "none") not in {"none", "cosine"}:
        raise ConfigError("training.scheduler must be none or cosine")
    if training.get("minimum_learning_rate", 0.0) < 0:
        raise ConfigError("training.minimum_learning_rate must be nonnegative")
    if training.get("minimum_learning_rate", 0.0) > training["learning_rate"]:
        raise ConfigError("training.minimum_learning_rate cannot exceed training.learning_rate")
    for key in (
        "remove_mates", "remove_in_check", "remove_captures", "remove_checks",
    ):
        if not isinstance(filters.get(key), bool):
            raise ConfigError(f"filters.{key} must be boolean")
    for key in ("minimum_depth", "mate_score_cp"):
        if key not in filters or filters[key] < 0:
            raise ConfigError(f"filters.{key} must be nonnegative")
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
            "rebuild_cache": config["dataset"].get("rebuild_cache", False),
        },
        "filters": config["filters"],
        "seed": config["training"]["seed"],
        "validation_size": config["training"]["validation_size"],
        "source_size": stat.st_size,
        "source_mtime_ns": stat.st_mtime_ns,
    }
    raw = json.dumps(relevant, sort_keys=True, separators=(",", ":")).encode()
    return hashlib.sha256(raw).hexdigest()[:16]
