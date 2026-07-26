"""Run discovery and atomic tuning reports."""

from __future__ import annotations

import json
from datetime import datetime, timezone
from pathlib import Path
from typing import Any

from tools.common.files import atomic_write_json


atomic_json = atomic_write_json


def create_run(root: Path, config_hash: str) -> Path:
    run_id = datetime.now(timezone.utc).strftime("%Y%m%dT%H%M%SZ") + "-" + config_hash[:8]
    run = root / "runs" / run_id
    suffix = 1
    while run.exists():
        run = root / "runs" / f"{run_id}-{suffix}"
        suffix += 1
    run.mkdir(parents=True)
    atomic_json(root / "latest.json", {"run": str(run.resolve())})
    return run


def resolve_run(root: Path, value: str | None, completed: bool = False) -> Path:
    if value:
        candidate = Path(value)
        if not candidate.is_absolute():
            candidate = root / "runs" / value
        run = candidate.resolve()
    elif completed:
        runs = sorted((root / "runs").glob("*"), reverse=True)
        run = next(
            (item for item in runs if _read_report(item).get("status") == "complete"),
            None,
        )
        if run is None:
            raise FileNotFoundError("no completed tuning run found")
    else:
        latest = json.loads((root / "latest.json").read_text(encoding="utf-8"))
        run = Path(latest["run"])
    if not run.is_dir():
        raise FileNotFoundError(f"tuning run not found: {run}")
    return run


def _read_report(run: Path) -> dict[str, Any]:
    try:
        return json.loads((run / "report.json").read_text(encoding="utf-8"))
    except (OSError, json.JSONDecodeError):
        return {}


def run_status(run: Path) -> str | None:
    """Return the persisted status for command safety checks."""
    return _read_report(run).get("status")


def print_report(run: Path) -> None:
    report = _read_report(run)
    if not report:
        raise ValueError(f"run has no readable report: {run}")
    print(f"Run: {run.name}")
    print(f"Status: {report['status']}")
    if "max_steps" in report:
        print(f"Step: {report.get('step', 0):,}/{report['max_steps']:,}")
    else:
        print(f"Epoch: {report.get('epoch', 0)}/{report.get('epochs', 0)}")
    if "train_loss" in report:
        best_location = (
            f"step {report['best_step']:,}" if "best_step" in report
            else f"epoch {report['best_epoch']}"
        )
        print(
            f"Loss: train={report['train_loss']:.4f}, "
            f"validation={report['validation_loss']:.4f}, "
            f"best={report['best_validation_loss']:.4f} ({best_location})"
        )
        print(
            f"Validation: MAE={report['validation_mae']:.2f} cp, "
            f"RMSE={report['validation_rmse']:.2f} cp"
        )
    if "positions_per_second" in report:
        print(f"Throughput: {report['positions_per_second']:,.0f} positions/s")
    counts = report.get("filter_counts", {})
    if counts:
        summary = ", ".join(f"{key}={value:,}" for key, value in sorted(counts.items()))
        print(f"Dataset: {summary}")
    ranges = report.get("parameter_ranges_cp")
    if ranges:
        from .model import PIECE_ORDER

        range_label = "Current combined parameter ranges" if report["status"] != "complete" else "Combined parameter ranges"
        print(f"{range_label} (cp): " + ", ".join(
            f"{piece}={ranges[piece][0]:.1f}..{ranges[piece][1]:.1f}"
            for piece in PIECE_ORDER if piece in ranges
        ))
    parameters_path = run / "parameters.json"
    if report["status"] != "complete" and (run / "best.pt").is_file():
        from .engine import load_run_parameters

        parameters, source = load_run_parameters(run)
        best_step = parameters.get("best_step") or report.get("best_step", 0)
        print(f"Export candidate: {source} at best step {best_step:,}")
        _print_parameter_values(parameters, "Best ")
    elif "material_values_cp" in report and "pst_ranges_cp" in report:
        from .model import PIECE_ORDER

        material_cp = ", ".join(
            f"{piece}={report['material_values_cp'][piece]:.1f}"
            for piece in PIECE_ORDER
        )
        print(f"Material values (cp): {material_cp}")
        print("Normalized PST ranges (cp): " + ", ".join(
            f"{piece}={report['pst_ranges_cp'][piece][0]:.1f}.."
            f"{report['pst_ranges_cp'][piece][1]:.1f}"
            for piece in PIECE_ORDER
        ))
    elif parameters_path.is_file():
        parameters = json.loads(parameters_path.read_text(encoding="utf-8"))
        _print_parameter_values(parameters)


def _print_parameter_values(parameters: dict, prefix: str = "") -> None:
    """Print parameter values in their unrounded training representation."""
    from .engine import export_values
    from .model import PIECE_ORDER

    if "material" in parameters and "pst" in parameters:
        material = [float(parameters["material"][piece]) for piece in PIECE_ORDER]
        pst = parameters["pst"]
    else:
        material_units, pst_units = export_values(parameters)
        material = [value * 100.0 / 128.0 for value in material_units]
        pst = {
            piece: [value * 100.0 / 128.0 for value in table]
            for piece, table in pst_units.items()
        }
    print(f"{prefix}Material values (cp): " + ", ".join(
        f"{piece}={value:.1f}" for piece, value in zip(PIECE_ORDER, material)
    ))
    print(f"{prefix}Normalized PST ranges (cp): " + ", ".join(
        f"{piece}={min(pst[piece][8:56] if piece == 'pawn' else pst[piece]):.1f}.."
        f"{max(pst[piece][8:56] if piece == 'pawn' else pst[piece]):.1f}"
        for piece in PIECE_ORDER
    ))
