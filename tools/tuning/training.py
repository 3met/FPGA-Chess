"""Efficient PyTorch training and checkpoint management."""

from __future__ import annotations

import contextlib
import hashlib
import json
import math
import os
import random
import sys
import time
from pathlib import Path

from .config import public_config
from .data import CacheBatchLoader, available_cpus, cache_datasets
from .model import EvaluationModel, NNUE_MODEL_VERSION, PIECE_ORDER, engine_combined_cp
from .reporting import atomic_json, create_run


class Tee:
    """Mirror stdout exactly to a persistent run log."""

    def __init__(self, terminal, log):
        self.terminal = terminal
        self.log = log

    def write(self, value):
        self.terminal.write(value)
        self.log.write(value)
        self.log.flush()
        return len(value)

    def flush(self):
        self.terminal.flush()
        self.log.flush()


def _device(torch, requested: str):
    if requested == "auto":
        if torch.cuda.is_available():
            return torch.device("cuda")
        if hasattr(torch.backends, "mps") and torch.backends.mps.is_available():
            return torch.device("mps")
        return torch.device("cpu")
    return torch.device(requested)


def _optimizer(torch, model, settings, device):
    kwargs = {
        "lr": settings["learning_rate"],
        "weight_decay": settings.get("weight_decay", 0.0),
    }
    kind = settings["optimizer"]
    cls = {"adamw": torch.optim.AdamW, "adam": torch.optim.Adam, "sgd": torch.optim.SGD}[kind]
    if device.type == "cuda" and kind in {"adamw", "adam"}:
        try:
            return cls(model.parameters(), fused=True, **kwargs)
        except (TypeError, RuntimeError):
            pass
    return cls(model.parameters(), **kwargs)


def _scheduler(torch, optimizer, settings):
    if settings.get("scheduler", "none") == "cosine":
        return torch.optim.lr_scheduler.CosineAnnealingLR(
            optimizer,
            T_max=settings["max_steps"],
            eta_min=settings.get("minimum_learning_rate", 0.0),
        )
    return None


def _loss(torch, prediction, target, settings):
    if settings["loss"] == "mse":
        return torch.nn.functional.mse_loss(prediction, target)
    return torch.nn.functional.huber_loss(
        prediction, target, delta=float(settings.get("huber_delta", 100.0))
    )


def _cpu_threads(settings) -> int:
    value = settings.get("cpu_threads", "auto")
    # PyTorch's kernels can use SMT effectively for this memory-heavy workload.
    return available_cpus() if value == "auto" else int(value)


def _loader(_torch, dataset, settings, shuffle: bool):
    return CacheBatchLoader(
        dataset,
        batch_size=settings["batch_size"],
        shuffle=shuffle,
        seed=settings["seed"],
        shuffle_buffer=settings["shuffle_buffer"],
    )


def _move_batch(codes, white_to_move, target, device):
    """Use pinned host buffers for asynchronous CUDA transfer; keep CPU direct."""
    if device.type == "cuda":
        return (
            codes.pin_memory().to(device, non_blocking=True),
            white_to_move.pin_memory().to(device, non_blocking=True),
            target.pin_memory().to(device, non_blocking=True),
        )
    return codes.to(device), white_to_move.to(device), target.to(device)


def _evaluate(torch, model, loader, settings, device):
    model.eval()
    total_loss = total_abs = total_squared = 0.0
    count = 0
    with torch.inference_mode():
        for codes, white_to_move, target in loader:
            codes, white_to_move, target = _move_batch(
                codes, white_to_move, target, device
            )
            prediction = model(codes, white_to_move)
            loss = _loss(torch, prediction, target, settings)
            error = prediction - target
            size = target.numel()
            total_loss += loss.item() * size
            total_abs += error.abs().sum().item()
            total_squared += error.square().sum().item()
            count += size
    return total_loss / count, total_abs / count, math.sqrt(total_squared / count)


def _ranges(values) -> dict[str, list[float]]:
    values = values.detach().cpu().reshape(6, 64)
    ranges = {}
    for index, piece in enumerate(PIECE_ORDER):
        reachable = values[index, 8:56] if piece == "pawn" else values[index]
        ranges[piece] = [float(reachable.min()), float(reachable.max())]
    return ranges


def _parameter_report(model) -> dict:
    """Build report fields from the model's identifiable parameter groups."""
    material = model.material_cp().detach().cpu()
    pst = model.pst_cp().detach().cpu()
    pst_ranges = {}
    for index, piece in enumerate(PIECE_ORDER):
        values = pst[index, 8:56] if piece == "pawn" else pst[index]
        pst_ranges[piece] = [float(values.min()), float(values.max())]
    return {
        "parameter_ranges_cp": _ranges(model.combined_cp()),
        "material_values_cp": {
            piece: float(material[index]) for index, piece in enumerate(PIECE_ORDER)
        },
        "pst_ranges_cp": pst_ranges,
    }


def _initialize_model(model, checkpoint: dict) -> int:
    """Load a checkpoint only when it uses the current numerical model."""
    version = checkpoint.get("nnue_model_version")
    state = checkpoint["model"]
    if version != NNUE_MODEL_VERSION:
        raise ValueError(
            f"checkpoint model version {version!r} cannot initialize version "
            f"{NNUE_MODEL_VERSION}"
        )
    model.load_state_dict(state)
    return version


def train(
    config: dict,
    cache: Path,
    resume_run: Path | None = None,
    initialize_run: Path | None = None,
) -> Path:
    import torch

    if resume_run is not None and initialize_run is not None:
        raise ValueError("resume_run and initialize_run are mutually exclusive")
    settings = config["training"]
    torch.set_num_threads(_cpu_threads(settings))
    seed = settings["seed"]
    random.seed(seed)
    torch.manual_seed(seed)
    if torch.cuda.is_available():
        torch.cuda.manual_seed_all(seed)
    serialized = json.dumps(public_config(config), sort_keys=True).encode()
    run = resume_run or create_run(Path(config["output"]["root"]), hashlib.sha256(serialized).hexdigest())
    if resume_run is not None:
        previous_config = json.loads((run / "config.json").read_text(encoding="utf-8"))
        comparable_previous = json.loads(json.dumps(previous_config))
        comparable_current = json.loads(json.dumps(public_config(config)))
        comparable_previous["training"]["max_steps"] = comparable_current["training"]["max_steps"]
        if comparable_previous != comparable_current:
            raise ValueError("resume config differs from the original run (only training.max_steps may change)")
    atomic_json(run / "config.json", public_config(config))
    train_data, validation_data, metadata = cache_datasets(cache)
    report = (
        json.loads((run / "report.json").read_text(encoding="utf-8"))
        if resume_run is not None else {
            "status": "running",
            "step": 0,
            "max_steps": settings["max_steps"],
            "filter_counts": metadata["counts"],
            "train_positions": len(train_data),
            "validation_positions": len(validation_data),
        }
    )
    report.update({"status": "running", "max_steps": settings["max_steps"]})
    atomic_json(run / "report.json", report)

    with (run / "train.log").open("a", encoding="utf-8") as log, contextlib.redirect_stdout(Tee(sys.stdout, log)):
        device = _device(torch, settings["device"])
        print(
            f"Run {run.name}: {len(train_data):,} train, {len(validation_data):,} validation, "
            f"device={device}, vectorized_cache=true, cpu_threads={torch.get_num_threads()}."
        )
        wandb_run = _start_wandb(config, run)
        output_buckets = int(settings.get("nnue_output_buckets", 16))
        warmup_steps = int(settings.get("pst_warmup_steps", 0))
        initialize_engine_pst = bool(settings.get("initialize_material_pst_from_engine", True))
        model = EvaluationModel(
            engine_combined_cp() if initialize_engine_pst else None,
            output_buckets=output_buckets,
        ).to(device)
        if initialize_engine_pst:
            print("Initialized material and PST parameters from the checked-in engine tables.")
        if initialize_run is not None:
            checkpoint_path = initialize_run / "best.pt"
            if not checkpoint_path.exists():
                raise ValueError(f"initialization run has no best checkpoint: {initialize_run.name}")
            checkpoint = torch.load(checkpoint_path, map_location=device, weights_only=True)
            source_version = _initialize_model(model, checkpoint)
            model.project_parameters()
            report.update({
                "initialized_from": initialize_run.name,
                "initialized_from_model_version": source_version,
            })
            atomic_json(run / "report.json", report)
            print(
                f"Initialized model version {NNUE_MODEL_VERSION} from {initialize_run.name} "
                f"version {source_version} best checkpoint; optimizer state was reset."
            )
        optimizer = _optimizer(torch, model, settings, device)
        scheduler = _scheduler(torch, optimizer, settings)
        if warmup_steps:
            print(
                f"PST/material-only warmup enabled for the first {warmup_steps:,} optimizer steps."
            )
        start_step = 0
        if resume_run is not None:
            checkpoint_path = run / "latest.pt"
            if not checkpoint_path.exists():
                raise ValueError(f"run has no resumable checkpoint: {run.name}")
            checkpoint = torch.load(checkpoint_path, map_location=device, weights_only=True)
            if checkpoint.get("nnue_model_version") != NNUE_MODEL_VERSION:
                raise ValueError(
                    "checkpoint does not match the current NNUE model and cannot be resumed"
                )
            try:
                model.load_state_dict(checkpoint["model"])
            except RuntimeError as exc:
                raise ValueError(
                    "checkpoint uses the former combined material/PST model and cannot be resumed"
                ) from exc
            optimizer.load_state_dict(checkpoint["optimizer"])
            if scheduler is not None and checkpoint.get("scheduler") is not None:
                scheduler.load_state_dict(checkpoint["scheduler"])
            start_step = int(checkpoint["step"])
            if start_step >= settings["max_steps"]:
                raise ValueError("resume step is already at or beyond configured training.max_steps")
            print(f"Resuming {run.name} after step {start_step:,}.")
        compiled = model
        if settings.get("compile", True) and hasattr(torch, "compile"):
            try:
                compiled = torch.compile(model)
                print("PyTorch compilation enabled.")
            except Exception as exc:  # Backend availability varies by platform.
                print(f"PyTorch compilation unavailable: {exc}")
        amp_enabled = bool(settings.get("amp", True) and device.type == "cuda")
        scaler = torch.amp.GradScaler("cuda", enabled=amp_enabled)
        train_loader = _loader(torch, train_data, settings, shuffle=True)
        train_loader.iteration = start_step // max(len(train_loader), 1)
        validation_loader = _loader(torch, validation_data, settings, shuffle=False)
        best_loss = float(report.get("best_validation_loss", float("inf")))
        best_step = int(report.get("best_step", 0))
        if initialize_run is not None:
            initial_loss, initial_mae, initial_rmse = _evaluate(
                torch, compiled, validation_loader, settings, device
            )
            best_loss = initial_loss
            best_step = 0
            initial_metric = {
                "step": 0,
                "validation_loss": initial_loss,
                "validation_mae": initial_mae,
                "validation_rmse": initial_rmse,
            }
            torch.save({
                "nnue_model_version": NNUE_MODEL_VERSION,
                "model": model.state_dict(),
                **initial_metric,
            }, run / "best.pt")
            report.update(initial_metric)
            report.update({"best_validation_loss": best_loss, "best_step": best_step})
            report.update(_parameter_report(model))
            atomic_json(run / "report.json", report)
            print(
                f"Step 0/{settings['max_steps']:,}: validation={initial_loss:.4f}, "
                f"MAE={initial_mae:.2f} cp (initialization candidate)."
            )
        stale_validations = 0
        metrics_path = run / "metrics.jsonl"
        start_time = time.monotonic()
        try:
            step = start_step
            interval_loss = 0.0
            interval_count = 0
            interval_start = time.monotonic()
            stop_early = False
            while step < settings["max_steps"] and not stop_early:
                for codes, white_to_move, target in train_loader:
                    if step >= settings["max_steps"]:
                        break
                    model.train()
                    codes, white_to_move, target = _move_batch(
                        codes, white_to_move, target, device
                    )
                    optimizer.zero_grad(set_to_none=True)
                    with torch.autocast(device_type=device.type, enabled=amp_enabled):
                        prediction = compiled(codes, white_to_move)
                        loss = _loss(torch, prediction, target, settings)
                    scaler.scale(loss).backward()
                    if step < warmup_steps:
                        for parameter in model.nnue_parameters():
                            parameter.grad = None
                    clip = settings.get("gradient_clip")
                    if clip is not None:
                        scaler.unscale_(optimizer)
                        torch.nn.utils.clip_grad_norm_(model.parameters(), clip)
                    scaler.step(optimizer)
                    scaler.update()
                    model.project_parameters()
                    if scheduler is not None:
                        scheduler.step()
                    size = target.numel()
                    interval_loss += loss.item() * size
                    interval_count += size
                    step += 1
                    validate = (
                        step % settings["validation_interval_steps"] == 0
                        or step == settings["max_steps"]
                    )
                    if not validate:
                        continue
                    validation_loss, validation_mae, validation_rmse = _evaluate(
                        torch, compiled, validation_loader, settings, device
                    )
                    elapsed = max(time.monotonic() - interval_start, 1e-9)
                    metric = {
                        "step": step,
                        "train_loss": interval_loss / interval_count,
                        "validation_loss": validation_loss,
                        "validation_mae": validation_mae,
                        "validation_rmse": validation_rmse,
                        "positions_per_second": interval_count / elapsed,
                        "learning_rate": optimizer.param_groups[0]["lr"],
                    }
                    with metrics_path.open("a", encoding="utf-8") as handle:
                        handle.write(json.dumps(metric, sort_keys=True) + "\n")
                    if wandb_run is not None:
                        wandb_run.log(metric, step=step)
                    checkpoint = {
                        "nnue_model_version": NNUE_MODEL_VERSION,
                        "model": model.state_dict(),
                        "optimizer": optimizer.state_dict(),
                        "scheduler": scheduler.state_dict() if scheduler is not None else None,
                        **metric,
                    }
                    torch.save(checkpoint, run / "latest.pt")
                    if (
                        step % settings["checkpoint_interval_steps"] == 0
                        or step == settings["max_steps"]
                    ):
                        torch.save(checkpoint, run / f"checkpoint-{step:08d}.pt")
                    if validation_loss < best_loss:
                        best_loss, best_step, stale_validations = validation_loss, step, 0
                        torch.save({
                            "nnue_model_version": NNUE_MODEL_VERSION,
                            "model": model.state_dict(),
                            **metric,
                        }, run / "best.pt")
                    else:
                        stale_validations += 1
                    report.update(metric)
                    report.update({
                        "best_validation_loss": best_loss,
                        "best_step": best_step,
                    })
                    report.update(_parameter_report(model))
                    atomic_json(run / "report.json", report)
                    print(
                        f"Step {step:,}/{settings['max_steps']:,}: "
                        f"train={metric['train_loss']:.4f}, validation={validation_loss:.4f}, "
                        f"MAE={validation_mae:.2f} cp, {metric['positions_per_second']:,.0f} positions/s."
                    )
                    interval_loss = 0.0
                    interval_count = 0
                    interval_start = time.monotonic()
                    patience = settings.get("early_stopping_patience")
                    if patience is not None and stale_validations >= patience:
                        print(f"Early stopping at step {step:,}.")
                        stop_early = True
                        break
            checkpoint = torch.load(run / "best.pt", map_location="cpu", weights_only=True)
            best_model = EvaluationModel(output_buckets=output_buckets)
            best_model.load_state_dict(checkpoint["model"])
            best_model.project_parameters()
            best_material = best_model.material_cp().detach().cpu()
            best_pst = best_model.pst_cp().detach().cpu()
            best_weights = best_model.combined_cp().detach().cpu()
            parameters = {
                "units": "centipawns",
                "piece_order": list(PIECE_ORDER),
                "material": {
                    piece: float(best_material[index])
                    for index, piece in enumerate(PIECE_ORDER)
                },
                "pst": {
                    piece: best_pst[index].tolist()
                    for index, piece in enumerate(PIECE_ORDER)
                },
                "combined_pst": best_weights.tolist(),
                "nnue": {
                    "model_version": NNUE_MODEL_VERSION,
                    "encoding": "relative-2x6x64",
                    "output_units": "pawn/128",
                    "output_buckets": output_buckets,
                    "accumulator_bias": best_model.accumulator_bias.detach().cpu().tolist(),
                    "feature_weights": best_model.feature_weights.detach().cpu().round()
                        .clamp(-2, 1).to(torch.int8).tolist(),
                    "output_weights": best_model.output_weights.detach().cpu().tolist(),
                    "output_bias": best_model.output_bias.detach().cpu().tolist(),
                },
                "best_step": best_step,
            }
            atomic_json(run / "parameters.json", parameters)
            report.update({
                "status": "complete",
                "elapsed_seconds": time.monotonic() - start_time,
            })
            report.update(_parameter_report(best_model))
            atomic_json(run / "report.json", report)
            if wandb_run is not None:
                wandb_run.summary.update(report)
                wandb_run.finish()
            print(f"Training complete; best validation loss {best_loss:.4f} at step {best_step:,}.")
        except BaseException:
            report["status"] = "interrupted" if isinstance(sys.exc_info()[1], KeyboardInterrupt) else "failed"
            atomic_json(run / "report.json", report)
            if wandb_run is not None:
                wandb_run.finish(exit_code=1)
            raise
    train_data.close()
    validation_data.close()
    return run


def _start_wandb(config: dict, run: Path):
    settings = config["wandb"]
    if not settings["enabled"]:
        return None
    os.environ.setdefault("WANDB_SILENT", "true")
    try:
        import wandb
    except ImportError:
        if settings.get("required", False):
            raise RuntimeError("WandB is enabled and required but is not installed")
        print("WandB unavailable; continuing with local artifacts.")
        return None
    return wandb.init(
        project=settings["project"],
        entity=settings.get("entity"),
        mode=settings.get("mode", "online"),
        config=public_config(config),
        name=run.name,
    )
