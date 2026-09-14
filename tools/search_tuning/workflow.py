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

from .optimizer import suggest
from .space import configured_parameters, get_path, parameter_hash


REPORT_RE = re.compile(
    r"^Elo:\s+([-+]?(?:\d+(?:\.\d+)?|inf|nan))\s+\+/-\s+"
    r"([-+]?(?:\d+(?:\.\d+)?|inf|nan)).*?^Games:\s+(\d+),",
    re.MULTILINE | re.DOTALL | re.IGNORECASE,
)
RESULTS_RE = re.compile(r"^Results:\s+(.+?)\s*$", re.MULTILINE)
SPRT_RE = re.compile(r"SPRT \([^\n]+\) completed - (H[01]) was accepted")


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
    required_strings = (
        "baseline", "output_root", "synthesis_target", "flash_target",
        "fastchess_binary", "stockfish_binary", "opening_book", "benchmark_results_root",
        "fpga_time_control", "stockfish_time_control",
    )
    for name in required_strings:
        if not isinstance(config.get(name), str) or not config[name]:
            raise TuningError(f"{name} must be a nonempty path or target name")
    for name in ("iterations", "paired_openings", "progress_interval_games", "opening_start"):
        if isinstance(config.get(name), bool) or not isinstance(config.get(name), int) or config[name] < 1:
            raise TuningError(f"{name} must be a positive integer")
    for name in ("stockfish_elo", "stockfish_threads", "stockfish_hash_mb"):
        if isinstance(config.get(name), bool) or not isinstance(config.get(name), int) or config[name] < 1:
            raise TuningError(f"{name} must be a positive integer")
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
    confirmation = config.get("confirmation")
    if not isinstance(confirmation, dict):
        raise TuningError("confirmation must be an object")
    if (
        isinstance(confirmation.get("maximum_repeats"), bool)
        or not isinstance(confirmation.get("maximum_repeats"), int)
        or confirmation["maximum_repeats"] < 0
    ):
        raise TuningError("confirmation.maximum_repeats must be a nonnegative integer")
    if (
        isinstance(confirmation.get("promotion_z_score"), bool)
        or not isinstance(confirmation.get("promotion_z_score"), (int, float))
        or not math.isfinite(confirmation["promotion_z_score"])
        or confirmation["promotion_z_score"] < 0
    ):
        raise TuningError("confirmation.promotion_z_score must be nonnegative")
    probability = confirmation.get("minimum_success_probability")
    if (
        isinstance(probability, bool)
        or not isinstance(probability, (int, float))
        or not math.isfinite(probability)
        or not 0 <= probability <= 1
    ):
        raise TuningError("confirmation.minimum_success_probability must be in [0, 1]")
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
        "stockfish_time_control": config["stockfish_time_control"],
        "stockfish_elo": config["stockfish_elo"],
        "stockfish_threads": config["stockfish_threads"],
        "stockfish_hash_mb": config["stockfish_hash_mb"],
        "parameters": [parameter.__dict__ for parameter in parameters],
        "optimizer": optimizer,
        "confirmation": config["confirmation"],
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


def promotion_is_significant(score: float, error: float, incumbent: dict, z_score: float) -> bool:
    combined_standard_error = math.sqrt((error / 1.96) ** 2 + (float(incumbent["score_error"]) / 1.96) ** 2)
    return score - float(incumbent["score"]) > z_score * combined_standard_error


def probability_better(score: float, error: float, reference: dict) -> float:
    """Probability that one noisy Elo estimate exceeds another."""
    deviation = math.sqrt((error / 1.96) ** 2 + (float(reference["score_error"]) / 1.96) ** 2)
    z = (score - float(reference["score"])) / max(deviation, 1e-12)
    return 0.5 * math.erfc(-z / math.sqrt(2.0))


def confirmation_success_probability(
    evaluations: list[dict], incumbent: dict, promotion_z_score: float
) -> float:
    """Estimate whether one equally precise repeat can clear promotion."""
    score, error = aggregate_evaluations(evaluations)
    existing_se = max(error / 1.96, 1e-12)
    repeat_se = max(float(evaluations[-1]["score_error"]) / 1.96, 1e-12)
    incumbent_se = max(float(incumbent["score_error"]) / 1.96, 1e-12)
    existing_weight = 1.0 / existing_se**2
    repeat_weight = 1.0 / repeat_se**2
    total_weight = existing_weight + repeat_weight
    projected_se = math.sqrt(1.0 / total_weight)
    promotion_cutoff = float(incumbent["score"]) + promotion_z_score * math.sqrt(
        projected_se**2 + incumbent_se**2
    )
    repeat_fraction = repeat_weight / total_weight
    projected_score_sd = repeat_fraction * math.sqrt(existing_se**2 + repeat_se**2)
    z = (promotion_cutoff - score) / max(projected_score_sd, 1e-12)
    return 0.5 * math.erfc(z / math.sqrt(2.0))


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
    if not math.isfinite(score) or not math.isfinite(error):
        raise TuningError("final tournament Elo is not finite; use more games or a better-matched opponent")
    if games == expected_games:
        return score, error, games, "full"
    decisions = SPRT_RE.findall(raw_output)
    if decisions and 0 < games < expected_games:
        return score, error, games, decisions[-1]
    raise TuningError(f"tournament summary is incomplete (expected {expected_games} games)")


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
                })
                atomic_json(self.candidate_path, current_baseline)
                atomic_json(self.best_path, current_baseline)
                _engine_profile(self.candidate_path, self.profile_path)
                self.save(state)
            if state.get("experiment_digest") != current_digest:
                raise TuningError(
                    "tuning configuration is incompatible with the saved experiment; "
                    "restore it or choose a new output_root"
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
                f"opening book is missing: {book}; run the benchmark wrapper once before tuning"
            )
        with book.open(encoding="utf-8", errors="replace") as handle:
            available_openings = sum(1 for line in handle if line.strip())
        required_openings = (
            self.config["opening_start"] - 1
            + self.config["paired_openings"] * (1 + self.config["confirmation"]["maximum_repeats"])
        )
        if required_openings > available_openings:
            raise TuningError(
                f"opening book has {available_openings} positions but confirmation may require "
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
        root = resolve_repo_path(self.config["benchmark_results_root"])
        matches = sorted(root.glob(f"{label}-*"), key=lambda path: path.stat().st_mtime, reverse=True)
        return matches[0].resolve() if matches else None

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
        if tournament is None:
            command = [
                sys.executable, "-m", "tools.search_tuning.benchmark",
                "--fastchess", str(platform_executable(self.config["fastchess_binary"])),
                "--results-root", str(resolve_repo_path(self.config["benchmark_results_root"])),
                "--label", label,
                "--rounds", str(self.config["paired_openings"]),
                "--repo-root", str(REPO_ROOT),
                "--stockfish", str(platform_executable(self.config["stockfish_binary"])),
                "--book", str(resolve_repo_path(self.config["opening_book"])),
                "--opening-start", environment["OPENING_START"],
                "--fpga-tc", self.config["fpga_time_control"],
                "--stockfish-tc", self.config["stockfish_time_control"],
                "--stockfish-elo", str(self.config["stockfish_elo"]),
                "--stockfish-threads", str(self.config["stockfish_threads"]),
                "--stockfish-hash", str(self.config["stockfish_hash_mb"]),
            ]
            if "SPRT_ELO0" in environment:
                command.extend([
                    "--sprt-elo0", environment["SPRT_ELO0"],
                    "--sprt-elo1", environment["SPRT_ELO1"],
                    "--sprt-alpha", environment["SPRT_ALPHA"],
                    "--sprt-beta", environment["SPRT_BETA"],
                ])
        else:
            command = [
                sys.executable, "-m", "tools.search_tuning.benchmark",
                "--fastchess", str(platform_executable(self.config["fastchess_binary"])),
                "--resume", str(tournament),
            ]
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

        output = self._run_logged(
            command, self.logs_path / f"{pending['id']:04d}-tournament.log", True,
            report_progress, environment,
        )
        if tournament is None:
            match = RESULTS_RE.search(output)
            tournament = Path(match.group(1)).resolve() if match else self._discover_tournament(label)
        if tournament is None:
            raise TuningError("benchmark completed but its result directory could not be located")
        while len(pending["tournament_dirs"]) <= repeat:
            pending["tournament_dirs"].append(None)
        pending["tournament_dirs"][repeat] = str(tournament)
        self.save(state)
        score, error, games, completion = self._read_tournament_completion(tournament, expected_games)
        if completion == "H1":
            self._disable_completed_upper_sprt(tournament)
            return self._run_tournament(state, pending)
        return score, error, tournament, games, completion

    def _finish_trial(self, state: dict) -> None:
        pending = state["pending"]
        score, error = aggregate_evaluations(pending["evaluations"])
        incumbent = state["history"][state["best_id"]] if state["best_id"] is not None else None
        promoted = incumbent is None or promotion_is_significant(
            score, error, incumbent, float(self.config["confirmation"]["promotion_z_score"])
        )
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
            improvement_probability = probability_better(score, error, center)
            record["optimizer_improvement_probability"] = improvement_probability
            if improvement_probability >= float(settings["trust_region_success_probability"]):
                state["successes"] += 1
                state["failures"] = 0
            elif improvement_probability <= float(settings["trust_region_failure_probability"]):
                state["failures"] += 1
                state["successes"] = 0
            else:
                state["successes"] = 0
                state["failures"] = 0
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

    def _needs_confirmation(self, state: dict, pending: dict) -> bool:
        if not state["history"] or not pending["evaluations"]:
            return False
        score, error = aggregate_evaluations(pending["evaluations"])
        incumbent = state["history"][state["best_id"]]
        maximum = 1 + int(self.config["confirmation"]["maximum_repeats"])
        settings = self.config["confirmation"]
        return (
            score > float(incumbent["score"])
            and len(pending["evaluations"]) < maximum
            and not promotion_is_significant(
                score, error, incumbent, float(settings["promotion_z_score"])
            )
            and confirmation_success_probability(
                pending["evaluations"], incumbent, float(settings["promotion_z_score"])
            ) >= float(settings["minimum_success_probability"])
        )

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
        if completion == "H0":
            environment = self._sprt_environment(state, repeat=0)
            elo0 = float(environment["SPRT_ELO0"])
            elo1 = float(environment["SPRT_ELO1"])
            record.update({
                "score": elo0,
                "score_error": max(error, elo1 - elo0),
                "raw_score": score,
                "raw_score_error": error,
                "censored_upper_elo": elo0,
            })
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
            pending = state["pending"] or self._new_trial(state)
            print(f"Trial {pending['id'] + 1}/{total}: {pending['acquisition']['method']}")
            print(f"Candidate: {relative_repo_path(self.candidate_path)}")
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
                while True:
                    if pending["evaluations"] and not self._needs_confirmation(state, pending):
                        break
                    started = time.monotonic()
                    repeat = len(pending["evaluations"])
                    suffix = f" (confirmation {repeat})" if repeat else ""
                    print(f"  Tournament{suffix}: {self.config['paired_openings'] * 2} games...", flush=True)
                    score, error, tournament, games, completion = self._run_tournament(state, pending)
                    pending["evaluations"].append(
                        self._evaluation_record(state, score, error, games, completion, tournament)
                    )
                    self.save(state)
                    if completion == "H0":
                        print(f"  Futility test rejected candidate after {games} games.")
                    if not self._needs_confirmation(state, pending):
                        break
                    combined_score, combined_error = aggregate_evaluations(pending["evaluations"])
                    print(
                        f"  Candidate leads at {combined_score:+.2f} +/- {combined_error:.2f}; confirming...",
                        flush=True,
                    )
                self._finish_trial(state)
                record = state["history"][-1]
                best = state["history"][state["best_id"]]
                verdict = "promoted" if record["promoted"] else "not promoted"
                print(
                    f"  Elo {record['score']:+.2f} +/- {record['score_error']:.2f}; {verdict}; "
                    f"best {best['score']:+.2f} (trial {best['id'] + 1})"
                )
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
        if state["rejections"]:
            print(f"Rejected:   {len(state['rejections'])} failed candidate builds")
        print(f"Radius:     {state['trust_region_radius']:.3f}")
        print(f"Best file:  {relative_repo_path(self.best_path)}")


def install_signal_handlers() -> None:
    def interrupt(_signum: int, _frame: object) -> None:
        raise KeyboardInterrupt

    signal.signal(signal.SIGTERM, interrupt)
