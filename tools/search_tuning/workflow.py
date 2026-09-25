"""Crash-safe synthesis, programming, tournament, and checkpoint workflow."""

from __future__ import annotations

import copy
import hashlib
import json
import math
import os
import re
import signal
import shutil
import subprocess
import sys
import time
from datetime import datetime, timezone
from pathlib import Path
from typing import Any, Callable

from tools.hardware_build.common import BuildError, REPO_ROOT, process_group_options, stop_process_tree
from tools.hardware_build.engine_config import load_engine_config
from tools.hardware_build.manifest import load_manifest
from tools.stockfish_benchmark import (
    BenchmarkConfig,
    BenchmarkError,
    DEFAULT_STOCKFISH_NODES,
    resume_tournament,
    run_tournament,
)

from .optimizer import posterior_rankings, suggest
from .space import configured_parameters, get_path, parameter_hash


REPORT_RE = re.compile(
    r"^Elo:\s+([-+]?(?:\d+(?:\.\d+)?|inf|nan))\s+\+/-\s+"
    r"([-+]?(?:\d+(?:\.\d+)?|inf|nan)).*?^Games:\s+(\d+),",
    re.MULTILINE | re.DOTALL | re.IGNORECASE,
)
SPRT_RE = re.compile(r"SPRT \([^\n]+\) completed - (H[01]) was accepted")
PLAYER_FAILURE_RE = re.compile(
    r"Player:\s+FPGA[^\n]*\n\s+Timeouts:\s+(\d+)\n\s+Crashed:\s+(\d+)", re.MULTILINE
)
PGN_TAG_RE = re.compile(r'^\[([A-Za-z0-9_]+)\s+"(.*)"\]$')


class TuningError(RuntimeError):
    pass


class RunLock:
    """Cross-platform advisory lock preventing concurrent tuning runs."""

    def __init__(self, path: Path):
        self.path = path
        self.handle: Any = None

    def __enter__(self) -> "RunLock":
        self.path.parent.mkdir(parents=True, exist_ok=True)
        self.handle = self.path.open("a+", encoding="utf-8")
        try:
            if os.name == "nt":
                import msvcrt
                self.handle.seek(0)
                if self.handle.read(1) == "":
                    self.handle.write("0")
                    self.handle.flush()
                self.handle.seek(0)
                msvcrt.locking(self.handle.fileno(), msvcrt.LK_NBLCK, 1)
            else:
                import fcntl
                fcntl.flock(self.handle.fileno(), fcntl.LOCK_EX | fcntl.LOCK_NB)
        except (OSError, BlockingIOError) as exc:
            self.handle.close()
            self.handle = None
            raise TuningError(f"another tuner is already using {self.path.parent}") from exc
        return self

    def __exit__(self, _type: object, _value: object, _traceback: object) -> None:
        if self.handle is not None:
            self.handle.close()
            self.handle = None


def utc_now() -> str:
    return datetime.now(timezone.utc).isoformat(timespec="seconds")


def atomic_json(path: Path, value: Any) -> None:
    """Replace JSON atomically so power loss cannot leave half a checkpoint."""
    path.parent.mkdir(parents=True, exist_ok=True)
    temporary = path.with_name(f".{path.name}.{os.getpid()}.tmp")
    with temporary.open("w", encoding="utf-8", newline="\n") as handle:
        json.dump(value, handle, indent=2)
        handle.write("\n")
        handle.flush()
        os.fsync(handle.fileno())
    os.replace(temporary, path)


def load_json(path: Path, label: str) -> dict:
    try:
        value = json.loads(path.read_text(encoding="utf-8"))
    except (OSError, json.JSONDecodeError) as exc:
        raise TuningError(f"could not load {label} {path}: {exc}") from exc
    if not isinstance(value, dict):
        raise TuningError(f"{label} {path} must contain a JSON object")
    return value


def validate_state(state: dict) -> None:
    """Validate the current checkpoint schema before using mutable state."""
    required = {
        "created_at", "run_id", "experiment", "experiment_digest", "baseline",
        "history", "rejections", "best_id", "pending", "trust_region_radius", "successes", "failures",
        "validation",
    }
    if (
        not required <= state.keys()
        or not isinstance(state["history"], list)
        or not isinstance(state["rejections"], list)
    ):
        raise TuningError("tuning state does not match the current schema")

    def valid_number(value: Any, *, nonnegative: bool = False) -> bool:
        return (
            not isinstance(value, bool)
            and isinstance(value, (int, float))
            and math.isfinite(value)
            and (not nonnegative or value >= 0)
        )

    def valid_evaluation(evaluation: Any) -> bool:
        return (
            isinstance(evaluation, dict)
            and valid_number(evaluation.get("score"))
            and valid_number(evaluation.get("score_error"), nonnegative=True)
            and evaluation.get("completion") in {"full", "H0"}
            and not isinstance(evaluation.get("games"), bool)
            and isinstance(evaluation.get("games"), int)
            and evaluation["games"] >= 1
            and isinstance(evaluation.get("tournament_dir"), str)
        )

    for index, record in enumerate(state["history"]):
        if not isinstance(record, dict) or record.get("id") != index:
            raise TuningError("tuning history IDs must be contiguous")
        if (
            not isinstance(record.get("parameters"), dict)
            or record.get("parameter_hash") != parameter_hash(record["parameters"])
            or not valid_number(record.get("score"))
            or not valid_number(record.get("score_error"), nonnegative=True)
            or not isinstance(record.get("evaluations"), list)
            or not record["evaluations"]
            or not isinstance(record.get("tournament_dirs"), list)
            or len(record["tournament_dirs"]) < len(record["evaluations"])
        ):
            raise TuningError(f"trial {index + 1} has invalid parameters or evaluations")
        for evaluation in record["evaluations"]:
            if not valid_evaluation(evaluation):
                raise TuningError(f"trial {index + 1} has an invalid tournament result")
    for rejection in state["rejections"]:
        if (
            not isinstance(rejection, dict)
            or rejection.get("reason") != "synthesis"
            or not isinstance(rejection.get("parameters"), dict)
            or rejection.get("parameter_hash") != parameter_hash(rejection["parameters"])
            or not isinstance(rejection.get("seeds"), list)
        ):
            raise TuningError("tuning state has an invalid rejected candidate")
    best_id = state["best_id"]
    if state["history"]:
        if isinstance(best_id, bool) or not isinstance(best_id, int) or not 0 <= best_id < len(state["history"]):
            raise TuningError("tuning state has an invalid best trial")
    elif best_id is not None:
        raise TuningError("empty tuning history cannot have a best trial")
    pending = state["pending"]
    if pending is not None and (
        not isinstance(pending, dict)
        or pending.get("id") != len(state["history"])
        or pending.get("phase") not in {"synthesis", "flash", "tournament"}
        or not isinstance(pending.get("evaluations"), list)
        or not isinstance(pending.get("tournament_dirs"), list)
        or not isinstance(pending.get("synthesis_seed_index"), int)
        or not 0 <= pending["synthesis_seed_index"] < len(state["experiment"]["synthesis_seeds"])
        or pending.get("parameter_hash") != parameter_hash(pending.get("parameters", {}))
        or any(not valid_evaluation(evaluation) for evaluation in pending.get("evaluations", []))
    ):
        raise TuningError("pending trial does not match the current schema")
    validation = state["validation"]
    if (
        not isinstance(validation, dict)
        or not isinstance(validation.get("finalist_ids"), list)
        or not isinstance(validation.get("failed_ids"), list)
        or any(
            isinstance(identifier, bool) or not isinstance(identifier, int)
            or not 0 < identifier < len(state["history"])
            for identifier in validation.get("finalist_ids", [])
        )
        or len(set(validation.get("finalist_ids", []))) != len(validation.get("finalist_ids", []))
        or len(set(validation.get("failed_ids", []))) != len(validation.get("failed_ids", []))
        or any(identifier not in validation.get("finalist_ids", []) for identifier in validation.get("failed_ids", []))
        or not isinstance(validation.get("complete"), bool)
    ):
        raise TuningError("tuning validation state does not match the current schema")
    active = validation.get("active")
    if active is not None and (
        not isinstance(active, dict)
        or active.get("trial_id") not in [0, *validation["finalist_ids"]]
        or isinstance(active.get("block"), bool)
        or not isinstance(active.get("block"), int)
        or active["block"] < 1
        or active.get("phase") not in {"synthesis", "flash", "tournament"}
        or not isinstance(active.get("synthesis_seed_index"), int)
        or not 0 <= active["synthesis_seed_index"] < len(state["experiment"]["synthesis_seeds"])
    ):
        raise TuningError("active validation target does not match the current schema")


def resolve_repo_path(value: str) -> Path:
    path = Path(value)
    return path.resolve() if path.is_absolute() else (REPO_ROOT / path).resolve()


def platform_executable(value: str) -> Path:
    """Resolve a configured executable and add .exe on Windows when needed."""
    path = resolve_repo_path(value)
    if os.name == "nt" and path.suffix.casefold() != ".exe":
        path = path.with_suffix(path.suffix + ".exe")
    return path


def relative_repo_path(path: Path) -> str:
    try:
        return path.resolve().relative_to(REPO_ROOT).as_posix()
    except ValueError as exc:
        raise TuningError(f"tuning output must remain inside the repository: {path}") from exc


def hash_file(path: Path) -> str | None:
    """Hash a potentially large experiment input without loading it into memory."""
    if not path.is_file():
        return None
    digest = hashlib.sha256()
    with path.open("rb") as handle:
        for chunk in iter(lambda: handle.read(1024 * 1024), b""):
            digest.update(chunk)
    return digest.hexdigest()


def hash_source_tree(paths: list[Path]) -> str:
    """Hash the relevant source set in stable repository-relative order."""
    files = []
    for path in paths:
        if path.is_file():
            files.append(path)
        elif path.is_dir():
            files.extend(
                item for item in path.rglob("*")
                if item.is_file() and "__pycache__" not in item.parts and item.suffix != ".pyc"
            )
    digest = hashlib.sha256()
    for path in sorted(set(files), key=lambda item: item.as_posix()):
        digest.update(relative_repo_path(path).encode())
        digest.update(b"\0")
        with path.open("rb") as handle:
            for chunk in iter(lambda: handle.read(1024 * 1024), b""):
                digest.update(chunk)
        digest.update(b"\0")
    return digest.hexdigest()


def validate_config(config: dict) -> None:
    if "stockfish_elo" in config or "stockfish_time_control" in config:
        raise TuningError("Stockfish Elo and time controls are unsupported; use full strength with stockfish_nodes")
    required_strings = (
        "baseline", "output_root", "synthesis_target", "flash_target",
        "fastchess_binary", "stockfish_binary", "opening_book", "benchmark_results_root",
        "fpga_time_control",
    )
    for name in required_strings:
        if not isinstance(config.get(name), str) or not config[name]:
            raise TuningError(f"{name} must be a nonempty path or target name")
    for name in ("iterations", "paired_openings", "progress_interval_games", "opening_start"):
        if isinstance(config.get(name), bool) or not isinstance(config.get(name), int) or config[name] < 1:
            raise TuningError(f"{name} must be a positive integer")
    for name in ("stockfish_threads", "stockfish_hash_mb"):
        if isinstance(config.get(name), bool) or not isinstance(config.get(name), int) or config[name] < 1:
            raise TuningError(f"{name} must be a positive integer")
    nodes = config.get("stockfish_nodes", DEFAULT_STOCKFISH_NODES)
    if isinstance(nodes, bool) or not isinstance(nodes, int) or nodes < 1:
        raise TuningError("stockfish_nodes must be a positive integer")
    optimizer = config.get("optimizer")
    if not isinstance(optimizer, dict):
        raise TuningError("optimizer must be an object")
    for name in (
        "candidate_pool_size", "initial_candidate_pool_size",
        "acquisition_shortlist_size", "initial_design", "mutation_axes",
    ):
        if isinstance(optimizer.get(name), bool) or not isinstance(optimizer.get(name), int) or optimizer[name] < 1:
            raise TuningError(f"optimizer.{name} must be a positive integer")
    if optimizer["candidate_pool_size"] < 100:
        raise TuningError("optimizer.candidate_pool_size must be at least 100")
    if optimizer["initial_candidate_pool_size"] < 100:
        raise TuningError("optimizer.initial_candidate_pool_size must be at least 100")
    if optimizer["acquisition_shortlist_size"] > optimizer["candidate_pool_size"]:
        raise TuningError("optimizer.acquisition_shortlist_size must not exceed candidate_pool_size")
    for name in ("successes_before_expand", "failures_before_shrink"):
        if isinstance(optimizer.get(name), bool) or not isinstance(optimizer.get(name), int) or optimizer[name] < 1:
            raise TuningError(f"optimizer.{name} must be a positive integer")
    for name in ("observation_noise_elo", "acquisition_exploration_elo"):
        if (
            isinstance(optimizer.get(name), bool)
            or not isinstance(optimizer.get(name), (int, float))
            or not math.isfinite(optimizer[name])
            or optimizer[name] < 0
        ):
            raise TuningError(f"optimizer.{name} must be nonnegative")
    for name in ("trust_region_success_probability", "trust_region_failure_probability"):
        value = optimizer.get(name)
        if (
            isinstance(value, bool)
            or not isinstance(value, (int, float))
            or not math.isfinite(value)
            or not 0 < value < 1
        ):
            raise TuningError(f"optimizer.{name} must be in (0, 1)")
    if optimizer["trust_region_failure_probability"] >= optimizer["trust_region_success_probability"]:
        raise TuningError("trust-region failure probability must be below success probability")
    for name in ("expand_multiplier", "shrink_multiplier"):
        if (
            isinstance(optimizer.get(name), bool)
            or not isinstance(optimizer.get(name), (int, float))
            or not math.isfinite(optimizer[name])
            or optimizer[name] <= 0
        ):
            raise TuningError(f"optimizer.{name} must be positive")
    if optimizer["expand_multiplier"] <= 1 or optimizer["shrink_multiplier"] >= 1:
        raise TuningError("expand_multiplier must exceed one and shrink_multiplier must be below one")
    for name in ("initial_radius", "minimum_radius", "maximum_radius"):
        if (
            isinstance(optimizer.get(name), bool)
            or not isinstance(optimizer.get(name), (int, float))
            or not math.isfinite(optimizer[name])
            or not 0 < optimizer[name] <= 1
        ):
            raise TuningError(f"optimizer.{name} must be in (0, 1]")
    if not optimizer["minimum_radius"] <= optimizer["initial_radius"] <= optimizer["maximum_radius"]:
        raise TuningError("trust-region radii must satisfy minimum <= initial <= maximum")
    jobs = config.get("synthesis_jobs")
    if jobs is not None and (isinstance(jobs, bool) or not isinstance(jobs, int) or jobs < 1):
        raise TuningError("synthesis_jobs must be null or a positive integer")
    seeds = config.get("synthesis_seeds")
    if (
        not isinstance(seeds, list)
        or not seeds
        or any(isinstance(seed, bool) or not isinstance(seed, int) or seed < 0 for seed in seeds)
        or len(set(seeds)) != len(seeds)
    ):
        raise TuningError("synthesis_seeds must contain unique nonnegative integers")
    maximum_rejections = config.get("maximum_synthesis_rejections")
    if (
        isinstance(maximum_rejections, bool)
        or not isinstance(maximum_rejections, int)
        or maximum_rejections < 1
    ):
        raise TuningError("maximum_synthesis_rejections must be a positive integer")
    validation = config.get("validation")
    if not isinstance(validation, dict):
        raise TuningError("validation must be an object")
    if (
        isinstance(validation.get("maximum_finalists"), bool)
        or not isinstance(validation.get("maximum_finalists"), int)
        or validation["maximum_finalists"] < 0
    ):
        raise TuningError("validation.maximum_finalists must be a nonnegative integer")
    if (
        isinstance(validation.get("maximum_blocks"), bool)
        or not isinstance(validation.get("maximum_blocks"), int)
        or validation["maximum_blocks"] < 1
    ):
        raise TuningError("validation.maximum_blocks must be a positive integer")
    if (
        isinstance(validation.get("promotion_z_score"), bool)
        or not isinstance(validation.get("promotion_z_score"), (int, float))
        or not math.isfinite(validation["promotion_z_score"])
        or validation["promotion_z_score"] < 0
    ):
        raise TuningError("validation.promotion_z_score must be nonnegative")
    probability = validation.get("minimum_success_probability")
    if (
        isinstance(probability, bool)
        or not isinstance(probability, (int, float))
        or not math.isfinite(probability)
        or not 0 <= probability <= 1
    ):
        raise TuningError("validation.minimum_success_probability must be in [0, 1]")
    distance = validation.get("minimum_parameter_distance")
    if (
        isinstance(distance, bool) or not isinstance(distance, (int, float))
        or not math.isfinite(distance) or not 0 <= distance <= 1
    ):
        raise TuningError("validation.minimum_parameter_distance must be in [0, 1]")
    runtime = config.get("runtime_failures")
    if (
        not isinstance(runtime, dict)
        or isinstance(runtime.get("maximum_per_tournament"), bool)
        or not isinstance(runtime.get("maximum_per_tournament"), int)
        or runtime["maximum_per_tournament"] < 0
    ):
        raise TuningError("runtime_failures.maximum_per_tournament must be a nonnegative integer")
    early = config.get("early_stopping")
    if not isinstance(early, dict) or not isinstance(early.get("enabled"), bool):
        raise TuningError("early_stopping.enabled must be boolean")
    if (
        isinstance(early.get("start_after_trials"), bool)
        or not isinstance(early.get("start_after_trials"), int)
        or early["start_after_trials"] < 1
    ):
        raise TuningError("early_stopping.start_after_trials must be a positive integer")
    for name in ("reject_margin_elo", "competitive_margin_elo"):
        if (
            isinstance(early.get(name), bool)
            or not isinstance(early.get(name), (int, float))
            or not math.isfinite(early[name])
            or early[name] < 0
        ):
            raise TuningError(f"early_stopping.{name} must be nonnegative")
    if early["reject_margin_elo"] <= early["competitive_margin_elo"]:
        raise TuningError("early_stopping.reject_margin_elo must exceed competitive_margin_elo")
    for name in ("alpha", "beta"):
        if (
            isinstance(early.get(name), bool)
            or not isinstance(early.get(name), (int, float))
            or not math.isfinite(early[name])
            or not 0 < early[name] < 1
        ):
            raise TuningError(f"early_stopping.{name} must be in (0, 1)")
    if early["alpha"] + early["beta"] >= 1:
        raise TuningError("early_stopping alpha plus beta must be below one")
    configured_parameters(config)


def experiment_snapshot(config: dict, baseline: dict, parameters: list[Any]) -> dict:
    """Capture settings whose changes would invalidate or reinterpret observations."""
    optimizer = dict(config["optimizer"])
    optimizer.pop("candidate_pool_size", None)
    optimizer.pop("initial_candidate_pool_size", None)
    optimizer.pop("acquisition_shortlist_size", None)
    benchmark_assets = {
        "fastchess": hash_file(platform_executable(config["fastchess_binary"])),
        "stockfish": hash_file(platform_executable(config["stockfish_binary"])),
        "opening_book": hash_file(resolve_repo_path(config["opening_book"])),
    }
    implementation_hash = hash_source_tree([
        REPO_ROOT / "hardware/rtl",
        REPO_ROOT / "hardware/data",
        REPO_ROOT / "hardware/ip",
        REPO_ROOT / "hardware/constraints",
        REPO_ROOT / "hardware/build/manifest.json",
        REPO_ROOT / "hardware/config/engine/de1-soc.json",
        REPO_ROOT / "software/engine",
        REPO_ROOT / "tools/hardware_build",
        REPO_ROOT / "tools/stockfish_benchmark.py",
        *(REPO_ROOT / "tools/search_tuning").glob("*.py"),
    ])
    return {
        "baseline_path": config["baseline"],
        "baseline_hash": parameter_hash(baseline),
        "paired_openings": config["paired_openings"],
        "opening_start": config["opening_start"],
        "random_seed": config.get("random_seed", 1),
        "synthesis_target": config["synthesis_target"],
        "synthesis_seeds": config["synthesis_seeds"],
        "flash_target": config["flash_target"],
        "benchmark_asset_hashes": benchmark_assets,
        "implementation_hash": implementation_hash,
        "benchmark_results_root": config["benchmark_results_root"],
        "fastchess_binary": config["fastchess_binary"],
        "stockfish_binary": config["stockfish_binary"],
        "opening_book": config["opening_book"],
        "fpga_time_control": config["fpga_time_control"],
        "stockfish_nodes": config.get("stockfish_nodes", DEFAULT_STOCKFISH_NODES),
        "stockfish_threads": config["stockfish_threads"],
        "stockfish_hash_mb": config["stockfish_hash_mb"],
        "parameters": [parameter.__dict__ for parameter in parameters],
        "optimizer": optimizer,
        "validation": config["validation"],
        "runtime_failures": config["runtime_failures"],
        "early_stopping": config["early_stopping"],
    }


def snapshot_digest(snapshot: dict) -> str:
    canonical = json.dumps(snapshot, sort_keys=True, separators=(",", ":")).encode()
    return hashlib.sha256(canonical).hexdigest()


def validate_baseline_ranges(baseline: dict, parameters: list[Any]) -> None:
    """Reject overrides that would silently clamp the experiment baseline."""
    for parameter in parameters:
        value = get_path(baseline, parameter.path)
        numeric = value[0] / value[1] if parameter.kind == "fraction" else float(value)
        if not parameter.low <= numeric <= parameter.high:
            raise TuningError(
                f"baseline value for {parameter.path} is outside its configured range "
                f"[{parameter.low}, {parameter.high}]"
            )


def aggregate_evaluations(evaluations: list[dict]) -> tuple[float, float]:
    """Combine independent Elo measurements using inverse-variance weighting."""
    weights = [1.0 / max(1e-12, (float(item["score_error"]) / 1.96) ** 2) for item in evaluations]
    score = sum(weight * float(item["score"]) for weight, item in zip(weights, evaluations, strict=True)) / sum(weights)
    confidence_error = 1.96 * math.sqrt(1.0 / sum(weights))
    return score, confidence_error


def probability_better(score: float, error: float, reference: dict) -> float:
    """Probability that one noisy Elo estimate exceeds another."""
    deviation = math.sqrt((error / 1.96) ** 2 + (float(reference["score_error"]) / 1.96) ** 2)
    z = (score - float(reference["score"])) / max(deviation, 1e-12)
    return 0.5 * math.erfc(-z / math.sqrt(2.0))


def parse_tournament_completion(
    summary: str, raw_output: str, expected_games: int
) -> tuple[float, float, int, str]:
    """Accept either a full match or a native Fastchess SPRT decision."""
    reports = REPORT_RE.findall(summary)
    if not reports:
        raise TuningError("tournament summary has no rating report")
    score_text, error_text, games_text = reports[-1]
    try:
        score, error, games = float(score_text), abs(float(error_text)), int(games_text)
    except ValueError as exc:
        raise TuningError("final tournament result could not be parsed") from exc
    if games == expected_games:
        if not math.isfinite(score) or not math.isfinite(error):
            raise TuningError("final tournament Elo is not finite; use more games or a better-matched opponent")
        return score, error, games, "full"
    decisions = SPRT_RE.findall(raw_output)
    if decisions and 0 < games < expected_games:
        # An extreme early result can legitimately be +/-inf with an undefined
        # interval. The SPRT decision remains finite evidence and H0 is later
        # represented by its configured conservative upper bound.
        return score, error, games, decisions[-1]
    if not math.isfinite(score) or not math.isfinite(error):
        raise TuningError("tournament Elo is not finite and has no completed SPRT decision")
    raise TuningError(f"tournament summary is incomplete (expected {expected_games} games)")


def _pgn_candidate_scores(path: Path) -> list[tuple[str, str, float]]:
    """Read candidate scores keyed by opening FEN and candidate color."""
    tags: dict[str, str] = {}
    games = []
    for line in path.read_text(encoding="utf-8", errors="replace").splitlines():
        match = PGN_TAG_RE.match(line)
        if match:
            tags[match.group(1)] = match.group(2)
            continue
        if line or "Result" not in tags:
            continue
        white_fpga = tags.get("White", "").startswith("FPGA-")
        black_fpga = tags.get("Black", "").startswith("FPGA-")
        if white_fpga == black_fpga or "FEN" not in tags:
            raise TuningError(f"could not identify FPGA player in {path}")
        result = tags["Result"]
        if result == "1/2-1/2":
            score = 0.5
        elif result == "1-0":
            score = 1.0 if white_fpga else 0.0
        elif result == "0-1":
            score = 0.0 if white_fpga else 1.0
        else:
            raise TuningError(f"unsupported PGN result {result!r} in {path}")
        games.append((tags["FEN"], "white" if white_fpga else "black", score))
        tags = {}
    if not games:
        raise TuningError(f"no completed games found in {path}")
    return games


def paired_elo_difference(candidate_pgns: list[Path], baseline_pgns: list[Path]) -> dict:
    """Estimate an Elo difference using covariance from identical opening/color games."""
    if len(candidate_pgns) != len(baseline_pgns) or not candidate_pgns:
        raise TuningError("paired validation requires matching nonempty tournament blocks")
    candidate_scores: list[float] = []
    baseline_scores: list[float] = []
    for candidate_path, baseline_path in zip(candidate_pgns, baseline_pgns, strict=True):
        candidate_games = _pgn_candidate_scores(candidate_path)
        baseline_games = _pgn_candidate_scores(baseline_path)
        if [(fen, color) for fen, color, _ in candidate_games] != [
            (fen, color) for fen, color, _ in baseline_games
        ]:
            raise TuningError("validation tournaments do not contain identical opening/color games")
        candidate_scores.extend(score for _, _, score in candidate_games)
        baseline_scores.extend(score for _, _, score in baseline_games)
    count = len(candidate_scores)
    if count < 2:
        raise TuningError("paired validation requires at least two games")
    candidate_mean = sum(candidate_scores) / count
    baseline_mean = sum(baseline_scores) / count
    candidate_probability = (sum(candidate_scores) + 0.5) / (count + 1.0)
    baseline_probability = (sum(baseline_scores) + 0.5) / (count + 1.0)
    scale = 400.0 / math.log(10.0)
    delta = scale * (
        math.log(candidate_probability / (1.0 - candidate_probability))
        - math.log(baseline_probability / (1.0 - baseline_probability))
    )
    variance_candidate = sum((value - candidate_mean) ** 2 for value in candidate_scores) / (count - 1)
    variance_baseline = sum((value - baseline_mean) ** 2 for value in baseline_scores) / (count - 1)
    covariance = sum(
        (candidate - candidate_mean) * (baseline - baseline_mean)
        for candidate, baseline in zip(candidate_scores, baseline_scores, strict=True)
    ) / (count - 1)
    candidate_gradient = scale / (candidate_probability * (1.0 - candidate_probability))
    baseline_gradient = scale / (baseline_probability * (1.0 - baseline_probability))
    variance = (
        candidate_gradient**2 * variance_candidate
        + baseline_gradient**2 * variance_baseline
        - 2.0 * candidate_gradient * baseline_gradient * covariance
    ) / count
    standard_error = math.sqrt(max(variance, 1e-12))
    probability_better = 0.5 * math.erfc(-delta / (standard_error * math.sqrt(2.0)))
    return {
        "elo_difference": delta,
        "elo_error": 1.96 * standard_error,
        "probability_better": probability_better,
        "games": count,
        "candidate_score": candidate_mean,
        "baseline_score": baseline_mean,
    }


def _engine_profile(candidate_path: Path, profile_path: Path) -> dict:
    source = load_json(REPO_ROOT / "hardware/config/engine/de1-soc.json", "DE1-SoC engine profile")
    source["search_config"] = relative_repo_path(candidate_path)
    atomic_json(profile_path, source)
    # Validate with exactly the same loader synthesis will use.
    load_engine_config(relative_repo_path(profile_path))
    return source


class Runner:
    """Own one output directory and advance its durable state machine."""

    def __init__(self, config_path: Path):
        self.config_path = config_path.resolve()
        self.config = load_json(self.config_path, "tuning configuration")
        validate_config(self.config)
        self.output = resolve_repo_path(self.config["output_root"])
        relative_repo_path(self.output)
        self.state_path = self.output / "state.json"
        self.candidate_path = self.output / "candidate.json"
        self.best_path = self.output / "best.json"
        self.provisional_path = self.output / "provisional.json"
        self.report_path = self.output / "report.json"
        self.profile_path = self.output / "engine.json"
        self.trials_path = self.output / "trials"
        self.logs_path = self.output / "logs"
        self.parameters = configured_parameters(self.config)
        self.active_process: subprocess.Popen[str] | None = None

    def _current_experiment(self, baseline: dict) -> tuple[dict, str]:
        snapshot = experiment_snapshot(self.config, baseline, self.parameters)
        return snapshot, snapshot_digest(snapshot)

    def initialize(self, allow_empty_reset: bool = True) -> dict:
        if self.state_path.exists():
            state = load_json(self.state_path, "tuning state")
            validate_state(state)
            current_baseline = load_json(
                resolve_repo_path(self.config["baseline"]), "baseline search parameters"
            )
            validate_baseline_ranges(current_baseline, self.parameters)
            current_snapshot, current_digest = self._current_experiment(current_baseline)
            if allow_empty_reset and not state["history"] and state.get("experiment_digest") != current_digest:
                # With no measurements, restart cleanly under the current
                # experiment definition rather than preserving ambiguous work.
                state.update({
                    "experiment": current_snapshot,
                    "experiment_digest": current_digest,
                    "baseline": current_baseline,
                    "rejections": [],
                    "best_id": None,
                    "pending": None,
                    "trust_region_radius": self.config["optimizer"]["initial_radius"],
                    "successes": 0,
                    "failures": 0,
                    "validation": {
                        "finalist_ids": [], "failed_ids": [], "active": None, "complete": False,
                    },
                })
                atomic_json(self.candidate_path, current_baseline)
                atomic_json(self.best_path, current_baseline)
                _engine_profile(self.candidate_path, self.profile_path)
                self.save(state)
            if state.get("experiment_digest") != current_digest:
                raise TuningError(
                    "tuning configuration is incompatible with the saved experiment; "
                    "restore it, choose a new output_root, or use --clean to archive it"
                )
            required_iterations = len(state["history"]) + int(state.get("pending") is not None)
            if self.config["iterations"] < required_iterations:
                raise TuningError(
                    f"iterations cannot be reduced below the {required_iterations} completed or pending trials"
                )
            return state
        baseline_path = resolve_repo_path(self.config["baseline"])
        baseline = load_json(baseline_path, "baseline search parameters")
        validate_baseline_ranges(baseline, self.parameters)
        self.output.mkdir(parents=True, exist_ok=True)
        self.trials_path.mkdir(exist_ok=True)
        self.logs_path.mkdir(exist_ok=True)
        snapshot, digest = self._current_experiment(baseline)
        state = {
            "created_at": utc_now(),
            "run_id": datetime.now(timezone.utc).strftime("%Y%m%d%H%M%S"),
            "experiment": snapshot,
            "experiment_digest": digest,
            "baseline": baseline,
            "history": [],
            "rejections": [],
            "best_id": None,
            "pending": None,
            "trust_region_radius": self.config["optimizer"]["initial_radius"],
            "successes": 0,
            "failures": 0,
            "validation": {
                "finalist_ids": [], "failed_ids": [], "active": None, "complete": False,
            },
        }
        atomic_json(self.candidate_path, baseline)
        atomic_json(self.best_path, baseline)
        _engine_profile(self.candidate_path, self.profile_path)
        atomic_json(self.state_path, state)
        return state

    def save(self, state: dict) -> None:
        atomic_json(self.state_path, state)

    def preflight(self) -> None:
        """Fail before synthesis if later programming or benchmark dependencies are absent."""
        try:
            manifest = load_manifest()
        except BuildError as exc:
            raise TuningError(str(exc)) from exc
        synthesis = manifest["synthesis_targets"].get(self.config["synthesis_target"])
        programming = manifest["programming_targets"].get(self.config["flash_target"])
        if synthesis is None:
            raise TuningError(f"unknown synthesis target: {self.config['synthesis_target']}")
        if programming is None:
            raise TuningError(f"unknown programming target: {self.config['flash_target']}")
        if programming["synthesis_target"] != self.config["synthesis_target"]:
            raise TuningError("flash target does not use the configured synthesis target")
        required_tools = []
        if synthesis["tool"] == "quartus":
            required_tools.extend(("quartus_map", "quartus_fit", "quartus_sta", "quartus_asm", "quartus_sh"))
        if programming["tool"] == "quartus":
            required_tools.extend(("jtagconfig", "quartus_pgm"))
        missing = [tool for tool in required_tools if shutil.which(tool) is None]
        if missing:
            raise TuningError("required tools not found on PATH: " + ", ".join(missing))

        fastchess = platform_executable(self.config["fastchess_binary"])
        stockfish = platform_executable(self.config["stockfish_binary"])
        missing_executables = [path for path in (fastchess, stockfish) if not path.is_file() or not os.access(path, os.X_OK)]
        if missing_executables:
            raise TuningError("benchmark executables unavailable: " + ", ".join(map(str, missing_executables)))
        book = resolve_repo_path(self.config["opening_book"])
        if not book.is_file():
            raise TuningError(
                f"opening book is missing: {book}; run tools.stockfish_benchmark once before tuning"
            )
        with book.open(encoding="utf-8", errors="replace") as handle:
            available_openings = sum(1 for line in handle if line.strip())
        required_openings = (
            self.config["opening_start"] - 1
            + self.config["paired_openings"] * (1 + self.config["validation"]["maximum_blocks"])
        )
        if required_openings > available_openings:
            raise TuningError(
                f"opening book has {available_openings} positions but validation may require "
                f"position {required_openings}"
            )

    def _new_trial(self, state: dict) -> dict:
        trial_id = len(state["history"])
        if trial_id == 0:
            candidate = copy.deepcopy(state["baseline"])
            acquisition = {"method": "baseline measurement"}
        else:
            candidate, acquisition = suggest(
                state["baseline"], self.parameters, state["history"], self.config["optimizer"],
                int(self.config.get("random_seed", 1)), float(state["trust_region_radius"]),
                {record["parameter_hash"] for record in state["rejections"]},
            )
        digest = parameter_hash(candidate)
        snapshot = self.trials_path / f"{trial_id:04d}-{digest[:12]}.json"
        atomic_json(snapshot, candidate)
        atomic_json(self.candidate_path, candidate)
        _engine_profile(self.candidate_path, self.profile_path)
        pending = {
            "id": trial_id,
            "parameter_hash": digest,
            "parameters": candidate,
            "snapshot": relative_repo_path(snapshot),
            "acquisition": acquisition,
            "phase": "synthesis",
            "synthesis_seed_index": 0,
            "started_at": utc_now(),
            "phase_started_at": utc_now(),
            "evaluations": [],
            "tournament_dirs": [],
        }
        state["pending"] = pending
        self.save(state)
        return pending

    def _run_logged(
        self,
        command: list[str],
        log_path: Path,
        inspect_output: bool = False,
        progress: Callable[[str], None] | None = None,
        environment: dict[str, str] | None = None,
    ) -> str:
        log_path.parent.mkdir(parents=True, exist_ok=True)
        collected = []
        with log_path.open("a", encoding="utf-8", newline="\n") as log:
            log.write(f"\n[{utc_now()}] command: {subprocess.list2cmdline(command)}\n")
            log.flush()
            self.active_process = subprocess.Popen(
                command, cwd=REPO_ROOT, stdout=subprocess.PIPE, stderr=subprocess.STDOUT,
                text=True, errors="replace", bufsize=1, env=environment, **process_group_options(),
            )
            try:
                assert self.active_process.stdout is not None
                for line in self.active_process.stdout:
                    log.write(line)
                    if inspect_output:
                        collected.append(line)
                    if progress is not None:
                        progress(line)
                return_code = self.active_process.wait()
            except BaseException:
                stop_process_tree(self.active_process)
                raise
            finally:
                self.active_process = None
        if return_code != 0:
            raise TuningError(f"command failed with exit code {return_code}; see {relative_repo_path(log_path)}")
        return "".join(collected)

    def _phase_command(self, phase: str, pending: dict | None = None) -> list[str]:
        if phase == "synthesis":
            command = [
                sys.executable, "-m", "tools.hardware_build", "synth", "--target",
                self.config["synthesis_target"], "--engine-config", relative_repo_path(self.profile_path),
            ]
            jobs = self.config.get("synthesis_jobs")
            if jobs is not None:
                command.extend(("--jobs", str(jobs)))
            if pending is None:
                raise AssertionError("synthesis requires pending trial state")
            seed = self.config["synthesis_seeds"][pending["synthesis_seed_index"]]
            command.extend(("--seed", str(seed)))
            return command
        if phase == "flash":
            return [
                sys.executable, "-m", "tools.hardware_build", "flash", "--target",
                self.config["flash_target"],
            ]
        raise AssertionError(phase)

    def _discover_tournament(self, label: str) -> Path | None:
        """Locate the named directory used by the shared benchmark runner."""
        root = resolve_repo_path(self.config["benchmark_results_root"])
        tournament = root / label
        return tournament.resolve() if tournament.is_dir() else None

    def _sprt_environment(self, state: dict, repeat: int) -> dict[str, str]:
        """Return dynamic absolute-Elo bounds for an ordinary challenger."""
        environment = os.environ.copy()
        environment["OPENING_START"] = str(self.config["opening_start"] + repeat * self.config["paired_openings"])
        early = self.config["early_stopping"]
        if (
            early["enabled"]
            and repeat == 0
            and len(state["history"]) >= early["start_after_trials"]
            and state["best_id"] is not None
        ):
            best = state["history"][state["best_id"]]
            conservative_best = float(best["score"]) - float(best["score_error"])
            environment.update({
                "SPRT_ELO0": f"{conservative_best - float(early['reject_margin_elo']):.6f}",
                "SPRT_ELO1": f"{conservative_best - float(early['competitive_margin_elo']):.6f}",
                "SPRT_ALPHA": str(early["alpha"]),
                "SPRT_BETA": str(early["beta"]),
            })
        else:
            for name in ("SPRT_ELO0", "SPRT_ELO1", "SPRT_ALPHA", "SPRT_BETA"):
                environment.pop(name, None)
        return environment

    def _read_tournament_completion(self, tournament: Path, expected_games: int) -> tuple[float, float, int, str]:
        summary_path = tournament / "summary.txt"
        raw_path = tournament / "raw-output.txt"
        if not summary_path.exists():
            raise TuningError(f"benchmark summary was not created: {summary_path}")
        summary = summary_path.read_text(encoding="utf-8", errors="replace")
        raw_output = raw_path.read_text(encoding="utf-8", errors="replace") if raw_path.exists() else ""
        return parse_tournament_completion(summary, raw_output, expected_games)

    def _disable_completed_upper_sprt(self, tournament: Path) -> None:
        """Turn an H1 checkpoint into a normal match that can continue."""
        state_path = tournament / "state.json"
        saved = load_json(state_path, "Fastchess tournament state")
        sprt = saved.get("sprt")
        if not isinstance(sprt, dict) or not sprt.get("enabled"):
            return
        sprt["enabled"] = False
        atomic_json(state_path, saved)

    def _run_tournament(self, state: dict, pending: dict) -> tuple[float, float, Path, int, str]:
        expected_games = int(self.config["paired_openings"]) * 2
        repeat = len(pending["evaluations"])
        label = (
            f"search-tune-{state['run_id']}-{pending['id']:04d}-"
            f"{pending['parameter_hash'][:8]}-s"
            f"{self.config['synthesis_seeds'][pending['synthesis_seed_index']]}-r{repeat}"
        )
        saved_dir = pending["tournament_dirs"][repeat] if repeat < len(pending["tournament_dirs"]) else None
        tournament = Path(saved_dir).resolve() if saved_dir else self._discover_tournament(label)
        if tournament is not None and (tournament / "summary.txt").exists():
            try:
                score, error, games, completion = self._read_tournament_completion(tournament, expected_games)
                while len(pending["tournament_dirs"]) <= repeat:
                    pending["tournament_dirs"].append(None)
                pending["tournament_dirs"][repeat] = str(tournament)
                self.save(state)
                if completion != "H1":
                    return score, error, tournament, games, completion
                print(f"  Futility upper bound cleared after {games} games; continuing same match.")
                self._disable_completed_upper_sprt(tournament)
            except TuningError:
                pass
        environment = self._sprt_environment(state, repeat)
        results_root = resolve_repo_path(self.config["benchmark_results_root"])
        tournament = tournament or (results_root / label).resolve()
        while len(pending["tournament_dirs"]) <= repeat:
            pending["tournament_dirs"].append(None)
        pending["tournament_dirs"][repeat] = str(tournament)
        self.save(state)
        last_rating = [""]

        def report_progress(line: str) -> None:
            """Reduce Fastchess standings to one stable line per configured interval."""
            if line.startswith("Elo:"):
                last_rating[0] = line.split(",", 1)[0].removeprefix("Elo:").strip()
                return
            match = re.match(r"Games:\s+(\d+),", line)
            if match:
                games = int(match.group(1))
                interval = int(self.config["progress_interval_games"])
                if games == expected_games or games % interval == 0:
                    rating = f", Elo {last_rating[0]}" if last_rating[0] else ""
                    print(f"    {games}/{expected_games} games{rating}", flush=True)

        class ProgressOutput:
            """Write benchmark output to the trial log and forward complete progress lines."""

            def __init__(self, log: Any):
                self.log = log
                self.buffer = ""

            def write(self, value: str) -> int:
                self.log.write(value)
                self.buffer += value
                while "\n" in self.buffer:
                    line, self.buffer = self.buffer.split("\n", 1)
                    report_progress(line + "\n")
                return len(value)

            def flush(self) -> None:
                self.log.flush()

        log_path = self.logs_path / f"{pending['id']:04d}-tournament.log"
        log_path.parent.mkdir(parents=True, exist_ok=True)
        with log_path.open("a", encoding="utf-8", newline="\n") as log:
            log.write(f"\n[{utc_now()}] Stockfish benchmark: {tournament}\n")
            progress_output = ProgressOutput(log)
            try:
                if (tournament / "state.json").is_file():
                    resume_tournament(
                        tournament, fastchess=str(platform_executable(self.config["fastchess_binary"])),
                        output=progress_output,
                    )
                else:
                    if tournament.exists() and not (tournament / "run.json").is_file():
                        raise TuningError(f"benchmark directory is not owned by the runner: {tournament}")
                    run_tournament(BenchmarkConfig(
                        name=label, matches=self.config["paired_openings"], results_root=results_root,
                        book=resolve_repo_path(self.config["opening_book"]),
                        fastchess=str(platform_executable(self.config["fastchess_binary"])),
                        stockfish=str(platform_executable(self.config["stockfish_binary"])),
                        fpga_time_control=self.config["fpga_time_control"],
                        stockfish_nodes=self.config.get("stockfish_nodes", DEFAULT_STOCKFISH_NODES),
                        stockfish_threads=self.config["stockfish_threads"],
                        stockfish_hash_mb=self.config["stockfish_hash_mb"],
                        opening_start=int(environment["OPENING_START"]),
                        sprt_elo0=float(environment["SPRT_ELO0"]) if "SPRT_ELO0" in environment else None,
                        sprt_elo1=float(environment["SPRT_ELO1"]) if "SPRT_ELO1" in environment else None,
                        sprt_alpha=float(environment.get("SPRT_ALPHA", 0.10)),
                        sprt_beta=float(environment.get("SPRT_BETA", 0.02)),
                        force=tournament.exists(),
                    ), output=progress_output)
            except BenchmarkError as exc:
                raise TuningError(f"benchmark failed: {exc}; see {relative_repo_path(log_path)}") from exc
        score, error, games, completion = self._read_tournament_completion(tournament, expected_games)
        if completion == "H1":
            self._disable_completed_upper_sprt(tournament)
            return self._run_tournament(state, pending)
        return score, error, tournament, games, completion

    def _finish_trial(self, state: dict) -> None:
        pending = state["pending"]
        score, error = aggregate_evaluations(pending["evaluations"])
        incumbent = state["history"][state["best_id"]] if state["best_id"] is not None else None
        runtime_invalid = any(evaluation.get("runtime_invalid", False) for evaluation in pending["evaluations"])
        if pending["id"] == 0 and runtime_invalid:
            raise TuningError("baseline tournament produced excessive engine failures")
        # Challengers remain provisional until paired final validation; the
        # first baseline measurement alone establishes the initial incumbent.
        promoted = incumbent is None
        record = {
            "id": pending["id"],
            "parameter_hash": pending["parameter_hash"],
            "parameters": pending["parameters"],
            "snapshot": pending["snapshot"],
            "acquisition": pending["acquisition"],
            "score": score,
            "score_error": error,
            "evaluations": pending["evaluations"],
            "tournament_dirs": pending["tournament_dirs"],
            "promoted": promoted,
            "runtime_invalid": runtime_invalid,
            "started_at": pending["started_at"],
            "completed_at": utc_now(),
        }
        state["history"].append(record)
        settings = self.config["optimizer"]
        if promoted:
            state["best_id"] = record["id"]
            atomic_json(self.best_path, record["parameters"])

        center_id = pending["acquisition"].get("center_id")
        adapt_region = record["id"] >= int(settings["initial_design"]) and center_id is not None
        if adapt_region:
            center = {
                "score": float(pending["acquisition"]["center_posterior_elo"]),
                "score_error": 1.96 * float(pending["acquisition"]["center_posterior_stddev"]),
            }
            improvement_probability = 0.0 if runtime_invalid else probability_better(score, error, center)
            record["optimizer_improvement_probability"] = improvement_probability
            if improvement_probability >= float(settings["trust_region_success_probability"]):
                state["successes"] += 1
                state["failures"] = 0
            elif improvement_probability <= float(settings["trust_region_failure_probability"]):
                state["failures"] += 1
                state["successes"] = 0
            # Ambiguous evidence preserves the current streak so occasional
            # noisy trials do not permanently disable radius adaptation.
            if state["successes"] >= settings["successes_before_expand"]:
                state["trust_region_radius"] = min(
                    settings["maximum_radius"], state["trust_region_radius"] * settings["expand_multiplier"]
                )
                state["successes"] = 0
            elif state["failures"] >= settings["failures_before_shrink"]:
                state["trust_region_radius"] = max(
                    settings["minimum_radius"], state["trust_region_radius"] * settings["shrink_multiplier"]
                )
                state["failures"] = 0
        else:
            state["successes"] = 0
            state["failures"] = 0
        state["pending"] = None
        self.save(state)

    def _select_validation_finalists(self, state: dict) -> None:
        """Choose strong, distinct finalists from the GP posterior."""
        validation = state["validation"]
        if validation["finalist_ids"]:
            return
        rankings = posterior_rankings(self.parameters, state["history"], self.config["optimizer"])
        candidates = [item for item in rankings if item["trial_id"] != 0]
        maximum = int(self.config["validation"]["maximum_finalists"])
        if maximum == 0:
            return
        minimum_distance = float(self.config["validation"]["minimum_parameter_distance"])
        selected: list[dict] = []
        deferred: list[dict] = []
        for item in candidates:
            distance = min(
                (
                    math.sqrt(
                        sum((a - b) ** 2 for a, b in zip(item["vector"], chosen["vector"], strict=True))
                        / len(self.parameters)
                    )
                )
                for chosen in selected
            ) if selected else math.inf
            if distance >= minimum_distance:
                selected.append(item)
            else:
                deferred.append(item)
            if len(selected) == maximum:
                break
        if len(selected) < maximum:
            selected.extend(deferred[:maximum - len(selected)])
        validation["finalist_ids"] = [item["trial_id"] for item in selected]
        validation["posterior"] = [
            {
                "trial_id": item["trial_id"],
                "posterior_elo": item["posterior_elo"],
                "posterior_stddev": item["posterior_stddev"],
            }
            for item in rankings
        ]
        if selected:
            atomic_json(self.provisional_path, state["history"][selected[0]["trial_id"]]["parameters"])
        self.save(state)

    def _paired_validation_result(self, state: dict, trial_id: int) -> dict | None:
        baseline = state["history"][0]
        candidate = state["history"][trial_id]
        blocks = min(len(baseline["evaluations"]), len(candidate["evaluations"])) - 1
        if blocks < 1:
            return None
        baseline_pgns = [Path(item["tournament_dir"]) / "games.pgn" for item in baseline["evaluations"][1:blocks + 1]]
        candidate_pgns = [Path(item["tournament_dir"]) / "games.pgn" for item in candidate["evaluations"][1:blocks + 1]]
        result = paired_elo_difference(candidate_pgns, baseline_pgns)
        result.update({"trial_id": trial_id, "blocks": blocks})
        return result

    def _candidate_needs_block(self, state: dict, trial_id: int, block: int) -> bool:
        record = state["history"][trial_id]
        if record.get("runtime_invalid") or trial_id in state["validation"]["failed_ids"]:
            return False
        if block == 1:
            return True
        result = self._paired_validation_result(state, trial_id)
        if result is None:
            return True
        standard_error = result["elo_error"] / 1.96
        z_score = float(self.config["validation"]["promotion_z_score"])
        if abs(result["elo_difference"]) > z_score * standard_error:
            return False
        return result["probability_better"] >= float(
            self.config["validation"]["minimum_success_probability"]
        )

    def _next_validation_target(self, state: dict) -> dict | None:
        validation = state["validation"]
        if validation["complete"]:
            return None
        if validation["active"] is not None:
            return validation["active"]
        self._select_validation_finalists(state)
        for block in range(1, int(self.config["validation"]["maximum_blocks"]) + 1):
            candidates = [
                trial_id for trial_id in validation["finalist_ids"]
                if self._candidate_needs_block(state, trial_id, block)
            ]
            if not candidates:
                continue
            baseline = state["history"][0]
            if len(baseline["evaluations"]) <= block:
                trial_id = 0
            else:
                missing = [trial_id for trial_id in candidates if len(state["history"][trial_id]["evaluations"]) <= block]
                if not missing:
                    continue
                trial_id = missing[0]
            validation["active"] = {
                "trial_id": trial_id,
                "block": block,
                "phase": "synthesis",
                "synthesis_seed_index": 0,
            }
            self.save(state)
            return validation["active"]
        self._finish_validation(state)
        return None

    def _validation_context(self, state: dict, active: dict) -> dict:
        record = state["history"][active["trial_id"]]
        return {
            "id": record["id"],
            "parameter_hash": record["parameter_hash"],
            "parameters": record["parameters"],
            "synthesis_seed_index": active["synthesis_seed_index"],
            "evaluations": record["evaluations"],
            "tournament_dirs": record["tournament_dirs"],
        }

    def _finish_validation(self, state: dict) -> None:
        validation = state["validation"]
        results = []
        for trial_id in validation["finalist_ids"]:
            if trial_id not in validation["failed_ids"]:
                result = self._paired_validation_result(state, trial_id)
                if result is not None:
                    results.append(result)
        z_score = float(self.config["validation"]["promotion_z_score"])
        for result in results:
            result["promotion_lower_bound"] = (
                result["elo_difference"] - z_score * (result["elo_error"] / 1.96)
            )
        significant = [
            result for result in results
            if result["promotion_lower_bound"] > 0.0
        ]
        if significant:
            winner = max(significant, key=lambda item: item["promotion_lower_bound"])
            record = state["history"][winner["trial_id"]]
            record["promoted"] = True
            state["best_id"] = record["id"]
            atomic_json(self.best_path, record["parameters"])
        provisional = max(results, key=lambda item: item["promotion_lower_bound"], default=None)
        if provisional is not None:
            atomic_json(self.provisional_path, state["history"][provisional["trial_id"]]["parameters"])
        else:
            self.provisional_path.unlink(missing_ok=True)
        report = {
            "completed_at": utc_now(),
            "best_id": state["best_id"],
            "provisional_id": provisional["trial_id"] if provisional is not None else None,
            "finalist_ids": validation["finalist_ids"],
            "failed_finalist_ids": validation["failed_ids"],
            "paired_results": results,
            "posterior_ranking": validation.get("posterior", []),
            "runtime_invalid_ids": [record["id"] for record in state["history"] if record.get("runtime_invalid")],
            "synthesis_rejections": [
                {"parameter_hash": item["parameter_hash"], "reason": item["reason"]}
                for item in state["rejections"]
            ],
        }
        finalist_records = [state["history"][trial_id] for trial_id in validation["finalist_ids"]]
        report["parameter_consensus"] = {
            parameter.path: get_path(finalist_records[0]["parameters"], parameter.path)
            for parameter in self.parameters
            if finalist_records
            and all(
                get_path(record["parameters"], parameter.path)
                == get_path(finalist_records[0]["parameters"], parameter.path)
                for record in finalist_records[1:]
            )
            and get_path(finalist_records[0]["parameters"], parameter.path)
            != get_path(state["baseline"], parameter.path)
        }
        atomic_json(self.report_path, report)
        validation["complete"] = True
        validation["active"] = None
        validation["results"] = results
        self.save(state)

    def _run_validation(self, state: dict) -> None:
        """Run resumable paired baseline-versus-finalist validation blocks."""
        while True:
            active = self._next_validation_target(state)
            if active is None:
                return
            record = state["history"][active["trial_id"]]
            if active["phase"] == "tournament" and len(record["evaluations"]) > active["block"]:
                state["validation"]["active"] = None
                self.save(state)
                continue
            context = self._validation_context(state, active)
            atomic_json(self.candidate_path, record["parameters"])
            _engine_profile(self.candidate_path, self.profile_path)
            label = "baseline" if record["id"] == 0 else f"trial {record['id'] + 1}"
            print(f"\nValidation block {active['block']}: {label} ({record['parameter_hash'][:12]})", flush=True)
            rejected = False
            while active["phase"] == "synthesis":
                started = time.monotonic()
                seed = self.config["synthesis_seeds"][active["synthesis_seed_index"]]
                context["synthesis_seed_index"] = active["synthesis_seed_index"]
                print(f"  Synthesis (seed {seed})...", flush=True)
                try:
                    self._run_logged(
                        self._phase_command("synthesis", context),
                        self.logs_path / f"{record['id']:04d}-validation-synthesis.log",
                    )
                except TuningError as exc:
                    active["synthesis_seed_index"] += 1
                    if active["synthesis_seed_index"] < len(self.config["synthesis_seeds"]):
                        self.save(state)
                        print(f"  Synthesis failed for seed {seed}; trying another fitter seed.")
                        continue
                    if record["id"] == 0:
                        raise exc
                    state["validation"]["failed_ids"].append(record["id"])
                    state["validation"]["active"] = None
                    self.save(state)
                    print("  Finalist skipped: synthesis failed for every configured fitter seed.")
                    rejected = True
                    break
                active["phase"] = "flash"
                self.save(state)
                print(f"  Synthesis complete ({(time.monotonic() - started) / 60:.1f} min)")
            if rejected:
                continue
            context = self._validation_context(state, active)
            if active["phase"] == "flash":
                started = time.monotonic()
                print("  Flash...", flush=True)
                self._run_logged(
                    self._phase_command("flash"),
                    self.logs_path / f"{record['id']:04d}-validation-flash.log",
                )
                active["phase"] = "tournament"
                self.save(state)
                print(f"  Flash complete ({(time.monotonic() - started) / 60:.1f} min)")
            if active["phase"] == "tournament":
                print(f"  Paired tournament: {self.config['paired_openings'] * 2} games...", flush=True)
                score, error, tournament, games, completion = self._run_tournament(state, context)
                evaluation = self._evaluation_record(state, score, error, games, completion, tournament)
                record["evaluations"].append(evaluation)
                record["score"], record["score_error"] = aggregate_evaluations(record["evaluations"])
                if evaluation["runtime_invalid"]:
                    if record["id"] == 0:
                        raise TuningError("baseline validation produced excessive engine failures")
                    record["runtime_invalid"] = True
                    state["validation"]["failed_ids"].append(record["id"])
                state["validation"]["active"] = None
                self.save(state)

    def _evaluation_record(
        self, state: dict, score: float, error: float, games: int,
        completion: str, tournament: Path,
    ) -> dict:
        """Represent an H0 result as a conservative censored observation."""
        record = {
            "score": score,
            "score_error": error,
            "games": games,
            "completion": completion,
            "tournament_dir": str(tournament),
            "completed_at": utc_now(),
        }
        raw_path = tournament / "raw-output.txt"
        raw_output = raw_path.read_text(encoding="utf-8", errors="replace") if raw_path.exists() else ""
        failures = PLAYER_FAILURE_RE.findall(raw_output)
        timeouts = sum(int(timeout) for timeout, _crashes in failures)
        crashes = sum(int(crash) for _timeouts, crash in failures)
        record.update({"timeouts": timeouts, "crashes": crashes})
        record["runtime_invalid"] = (
            timeouts + crashes > int(self.config["runtime_failures"]["maximum_per_tournament"])
        )
        if completion == "H0":
            environment = self._sprt_environment(state, repeat=0)
            elo0 = float(environment["SPRT_ELO0"])
            elo1 = float(environment["SPRT_ELO1"])
            raw_is_finite = math.isfinite(score) and math.isfinite(error)
            record.update({
                "score": elo0,
                "score_error": max(error, elo1 - elo0) if raw_is_finite else elo1 - elo0,
                "censored_upper_elo": elo0,
            })
            if raw_is_finite:
                record.update({"raw_score": score, "raw_score_error": error})
            else:
                record["raw_score_unbounded"] = "negative" if score < 0 else "positive"
        return record

    def _archive_output(self) -> Path | None:
        """Move an existing experiment aside so a clean run remains recoverable."""
        if not self.output.exists():
            return None
        if self.output == REPO_ROOT:
            raise TuningError("refusing to clean the repository root")
        archive_root = self.output.parent / f"{self.output.name}-archive"
        if archive_root == self.output or self.output in archive_root.parents:
            raise TuningError("output_root cannot contain its own archive directory")
        archive_root.mkdir(parents=True, exist_ok=True)
        timestamp = datetime.now(timezone.utc).strftime("%Y%m%dT%H%M%S.%fZ")
        destination = archive_root / timestamp
        sequence = 1
        while destination.exists():
            destination = archive_root / f"{timestamp}-{sequence}"
            sequence += 1
        self.output.replace(destination)
        return destination

    def run(self, dry_run: bool = False, clean: bool = False) -> None:
        # The board is global even when separate experiments use different
        # output roots, so serialize all tuner instances in this repository.
        with RunLock(REPO_ROOT / "work/search-tuning.run.lock"):
            if clean:
                archived = self._archive_output()
                if archived is not None:
                    print(f"Archived previous run: {relative_repo_path(archived)}")
            self._run_locked(dry_run)

    def _run_locked(self, dry_run: bool) -> None:
        state = self.initialize()
        if state.get("pending"):
            atomic_json(self.candidate_path, state["pending"]["parameters"])
            _engine_profile(self.candidate_path, self.profile_path)
        total = int(self.config["iterations"])
        print(f"Search tuning: {len(state['history'])}/{total} evaluations complete; {len(self.parameters)} parameters enabled")
        self.preflight()
        if dry_run:
            if len(state["history"]) < total:
                pending = state["pending"] or self._new_trial(state)
                print(f"Trial {pending['id'] + 1}/{total}: {pending['acquisition']['method']}")
                print(f"Candidate: {relative_repo_path(self.candidate_path)}")
            else:
                active = self._next_validation_target(state)
                if active is None:
                    print("Validation is complete.")
                else:
                    label = "baseline" if active["trial_id"] == 0 else f"trial {active['trial_id'] + 1}"
                    print(f"Validation block {active['block']}: {label}")
            print("Dry run stopped before synthesis or FPGA programming.")
            return
        while len(state["history"]) < total:
            pending = state["pending"]
            if pending is None:
                if state["history"]:
                    print(
                        f"\nSelecting trial {len(state['history']) + 1}/{total} from "
                        f"{self.config['optimizer']['candidate_pool_size']:,} quantized candidates...",
                        flush=True,
                    )
                pending = self._new_trial(state)
            trial_number = pending["id"] + 1
            print(f"\nTrial {trial_number}/{total}: {pending['acquisition']['method']} ({pending['parameter_hash'][:12]})")
            rejected = False
            while pending["phase"] == "synthesis":
                started = time.monotonic()
                seed = self.config["synthesis_seeds"][pending["synthesis_seed_index"]]
                print(f"  Synthesis (seed {seed})...", flush=True)
                try:
                    self._run_logged(
                        self._phase_command("synthesis", pending),
                        self.logs_path / f"{pending['id']:04d}-synthesis.log",
                    )
                except TuningError as exc:
                    pending["synthesis_seed_index"] += 1
                    pending["phase_started_at"] = utc_now()
                    if pending["synthesis_seed_index"] < len(self.config["synthesis_seeds"]):
                        self.save(state)
                        print(f"  Synthesis failed for seed {seed}; trying another fitter seed.")
                        continue
                    if pending["id"] == 0:
                        # The baseline is required to anchor the Elo model. A
                        # systemic inability to build it must stop the run.
                        pending["synthesis_seed_index"] = 0
                        self.save(state)
                        raise exc
                    rejection = {
                        "parameter_hash": pending["parameter_hash"],
                        "parameters": pending["parameters"],
                        "snapshot": pending["snapshot"],
                        "reason": "synthesis",
                        "seeds": self.config["synthesis_seeds"],
                        "rejected_at": utc_now(),
                    }
                    state["rejections"].append(rejection)
                    state["pending"] = None
                    self.save(state)
                    print("  Candidate rejected: synthesis failed for every configured fitter seed.")
                    if len(state["rejections"]) >= self.config["maximum_synthesis_rejections"]:
                        raise TuningError(
                            "maximum synthesis rejections reached; inspect timing before continuing"
                        )
                    rejected = True
                    break
                pending["phase"] = "flash"
                pending["phase_started_at"] = utc_now()
                self.save(state)
                print(f"  Synthesis complete ({(time.monotonic() - started) / 60:.1f} min)")
            if rejected:
                continue
            if pending["phase"] == "flash":
                started = time.monotonic()
                print("  Flash...", flush=True)
                self._run_logged(self._phase_command("flash"), self.logs_path / f"{pending['id']:04d}-flash.log")
                pending["phase"] = "tournament"
                pending["phase_started_at"] = utc_now()
                self.save(state)
                print(f"  Flash complete ({(time.monotonic() - started) / 60:.1f} min)")
            if pending["phase"] == "tournament":
                if not pending["evaluations"]:
                    print(f"  Tournament: {self.config['paired_openings'] * 2} games...", flush=True)
                    score, error, tournament, games, completion = self._run_tournament(state, pending)
                    pending["evaluations"].append(
                        self._evaluation_record(state, score, error, games, completion, tournament)
                    )
                    self.save(state)
                    if completion == "H0":
                        print(f"  Futility test rejected candidate after {games} games.")
                self._finish_trial(state)
                record = state["history"][-1]
                best = state["history"][state["best_id"]]
                if record["promoted"]:
                    verdict = "promoted"
                elif record["runtime_invalid"]:
                    failures = sum(
                        evaluation.get("timeouts", 0) + evaluation.get("crashes", 0)
                        for evaluation in record["evaluations"]
                    )
                    verdict = f"runtime-invalid ({failures} failures)"
                elif record["score"] > best["score"]:
                    verdict = "provisional lead; paired validation deferred"
                else:
                    verdict = "not promoted"
                print(
                    f"  Elo {record['score']:+.2f} +/- {record['score_error']:.2f}; {verdict}; "
                    f"best {best['score']:+.2f} (trial {best['id'] + 1})"
                )
        self._run_validation(state)
        print(f"\nTuning complete. Best parameters: {relative_repo_path(self.best_path)}")

    def status(self) -> None:
        if not self.state_path.exists():
            print("Search tuning has not been started.")
            return
        state = self.initialize(allow_empty_reset=False)
        history = state["history"]
        print(f"Evaluations: {len(history)}/{self.config['iterations']}")
        if history:
            best = history[state["best_id"]]
            print(f"Best Elo:   {best['score']:+.2f} +/- {best['score_error']:.2f} (trial {best['id'] + 1})")
        pending = state.get("pending")
        if pending:
            phase = pending["phase"]
            if phase == "synthesis":
                index = pending["synthesis_seed_index"]
                seeds = self.config["synthesis_seeds"]
                phase += f" (seed {seeds[index]}, attempt {index + 1}/{len(seeds)})"
            print(f"Pending:    trial {pending['id'] + 1}, {phase}")
        else:
            print("Pending:    none")
        validation = state["validation"]
        active = validation["active"]
        if active:
            label = "baseline" if active["trial_id"] == 0 else f"trial {active['trial_id'] + 1}"
            print(f"Validation: block {active['block']}, {label}, {active['phase']}")
        elif validation["complete"]:
            print("Validation: complete")
        elif len(history) >= self.config["iterations"]:
            print("Validation: ready")
        if state["rejections"]:
            print(f"Rejected:   {len(state['rejections'])} failed candidate builds")
        print(f"Radius:     {state['trust_region_radius']:.3f}")
        print(f"Best file:  {relative_repo_path(self.best_path)}")
        if self.provisional_path.exists():
            print(f"Provisional: {relative_repo_path(self.provisional_path)}")


def install_signal_handlers() -> None:
    def interrupt(_signum: int, _frame: object) -> None:
        raise KeyboardInterrupt

    signal.signal(signal.SIGTERM, interrupt)
