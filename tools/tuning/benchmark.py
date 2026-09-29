"""Sustained NNUE training benchmark using the real cache and optimizer step."""

from __future__ import annotations

import argparse
import statistics
import time
from pathlib import Path

from .config import cache_key, load_config
from .data import cache_datasets
from .model import EvaluationModel, engine_combined_cp
from .reporting import resolve_run
from .training import (
    _cpu_threads,
    _device,
    _evaluate,
    _loader,
    _optimizer,
    _scheduler,
    _train_batch,
    _training_objective,
)


def benchmark(
    config: dict, run: Path | None, steps: int, warmup: int, repeats: int,
    profile_steps: int = 0,
) -> None:
    """Time sustained batches and a full validation pass after compilation settles."""
    import torch

    settings = config["training"]
    torch.set_num_threads(_cpu_threads(settings))
    cache = Path(config["output"]["root"]) / "cache" / cache_key(config)
    if not (cache / "metadata.json").exists():
        raise FileNotFoundError(f"training cache not found: {cache}; run training to build it")
    train_data, validation_data, _ = cache_datasets(cache)
    try:
        device = _device(torch, settings["device"])
        model = EvaluationModel(engine_combined_cp()).to(device)
        if run is not None:
            checkpoint = torch.load(run / "best.pt", map_location=device, weights_only=True)
            model.load_state_dict(checkpoint["model"])
            model.project_parameters()
        optimizer = _optimizer(torch, model, settings, device)
        scheduler = _scheduler(torch, optimizer, settings)
        compile_enabled = bool(settings.get("compile", True) and hasattr(torch, "compile"))
        compiled = torch.compile(model) if compile_enabled else model
        objective = lambda codes, stm, target: _training_objective(
            model, codes, stm, target, settings
        )
        if compile_enabled:
            objective = torch.compile(objective)
        scaler = torch.amp.GradScaler(
            "cuda", enabled=bool(settings.get("amp", True) and device.type == "cuda")
        )
        loader = iter(_loader(train_data, settings, shuffle=True))

        def next_batch():
            nonlocal loader
            try:
                return next(loader)
            except StopIteration:
                loader = iter(_loader(train_data, settings, shuffle=True))
                return next(loader)

        print(
            f"Benchmark: device={device}, threads={torch.get_num_threads()}, "
            f"batch={settings['batch_size']}, microbatch={settings.get('microbatch_size', 'auto')}, "
            f"warmup={warmup}, timed={repeats} x {steps} steps."
        )
        compile_start = time.monotonic()
        for step in range(warmup):
            _train_batch(
                torch, model, objective, optimizer, scaler, settings,
                device, next_batch(),
            )
            scheduler.step()
        print(f"Warmup/compilation: {time.monotonic() - compile_start:.1f}s (excluded).")

        step = warmup
        if profile_steps:
            with torch.profiler.profile(activities=[torch.profiler.ProfilerActivity.CPU]) as profile:
                for _ in range(profile_steps):
                    _train_batch(
                        torch, model, objective, optimizer, scaler, settings,
                        device, next_batch(),
                    )
                    scheduler.step()
                    step += 1
            print(profile.key_averages().table(sort_by="self_cpu_time_total", row_limit=18))

        rates = []
        timed_positions = 0
        timed_seconds = 0.0
        for repeat in range(repeats):
            positions = 0
            data_seconds = 0.0
            update_seconds = 0.0
            for _ in range(steps):
                start = time.monotonic()
                batch = next_batch()
                data_seconds += time.monotonic() - start
                start = time.monotonic()
                _, count = _train_batch(
                    torch, model, objective, optimizer, scaler, settings,
                    device, batch,
                )
                scheduler.step()
                update_seconds += time.monotonic() - start
                positions += count
                step += 1
            seconds = data_seconds + update_seconds
            rate = positions / seconds
            rates.append(rate)
            timed_positions += positions
            timed_seconds += seconds
            print(
                f"Window {repeat + 1}: {rate:,.0f} positions/s "
                f"(loader {data_seconds:.1f}s, update {update_seconds:.1f}s)."
            )

        validation_loader = _loader(
            validation_data, settings, shuffle=True, reshuffle_each_iteration=False
        )
        # Validation has a separate inference graph; compile it before timing.
        _evaluate(torch, compiled, validation_loader, settings, device)
        start = time.monotonic()
        _evaluate(torch, compiled, validation_loader, settings, device)
        validation_seconds = time.monotonic() - start
        interval = settings["validation_interval_steps"]
        cycle_seconds = timed_seconds + validation_seconds * (repeats * steps / interval)
        print(
            f"Median train-only: {statistics.median(rates):,.0f} positions/s; "
            f"full validation: {validation_seconds:.1f}s; "
            f"estimated {interval:,}-step cycle: {timed_positions / cycle_seconds:,.0f} positions/s."
        )
    finally:
        train_data.close()
        validation_data.close()


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--config", help="Training configuration; defaults to checked-in settings")
    parser.add_argument("--run", help="Load the selected checkpoint from this run")
    parser.add_argument("--steps", type=int, default=500, help="Timed steps per window")
    parser.add_argument("--warmup", type=int, default=40, help="Untimed compilation and warmup steps")
    parser.add_argument("--repeats", type=int, default=3, help="Number of timed windows")
    parser.add_argument("--profile-steps", type=int, default=0, help="Profile untimed optimizer steps")
    args = parser.parse_args()
    if args.steps < 1 or args.warmup < 1 or args.repeats < 1 or args.profile_steps < 0:
        parser.error("steps, warmup, and repeats must be positive; profile-steps must be nonnegative")
    config = load_config(args.config)
    run = resolve_run(Path(config["output"]["root"]), args.run) if args.run else None
    benchmark(config, run, args.steps, args.warmup, args.repeats, args.profile_steps)


if __name__ == "__main__":
    main()
