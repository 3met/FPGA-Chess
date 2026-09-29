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


def format_table(headers: tuple[str, ...], rows: list[tuple[str, ...]],
                 left_columns: tuple[int, ...] = (0,)) -> str:
    """Align plain-text report columns without terminal-specific formatting."""
    widths = [max(len(value) for value in column) for column in zip(headers, *rows)]

    def line(values: tuple[str, ...]) -> str:
        return "  ".join(
            value.ljust(width) if index in left_columns else value.rjust(width)
            for index, (value, width) in enumerate(zip(values, widths))
        ).rstrip()

    return "\n".join((line(headers), line(tuple("-" * width for width in widths)),
                      *(line(row) for row in rows)))


def _cp(value: float) -> str:
    """Avoid displaying tiny negative values as negative zero centipawns."""
    return f"{0.0 if round(value, 1) == 0 else value:.1f}"


def _cp_range(low: float, high: float) -> str:
    """Format a reachable piece-square range in centipawns."""
    return f"{_cp(low)}..{_cp(high)}"


def _piece_rows(material: dict, pst: dict, endgame_material: dict,
                endgame_pst: dict, label: str) -> list[tuple[str, ...]]:
    """Put material and reachable PST ranges under one piece-column header."""
    from .model import PIECE_ORDER

    def ranges(tables: dict) -> tuple[str, ...]:
        cells = []
        for piece in PIECE_ORDER:
            values = tables[piece][8:56] if piece == "pawn" else tables[piece]
            cells.append(_cp_range(min(values), max(values)))
        return tuple(cells)

    return [
        (f"{label} opening material", *(_cp(material[piece]) for piece in PIECE_ORDER)),
        (f"{label} opening PST", *ranges(pst)),
        (f"{label} endgame material", *(_cp(endgame_material[piece]) for piece in PIECE_ORDER)),
        (f"{label} endgame PST", *ranges(endgame_pst)),
    ]


def print_report(run: Path) -> None:
    """Show latest metrics and selected weights without conflating the two."""
    report = _read_report(run)
    if not report:
        raise ValueError(f"run has no readable report: {run}")
    print(f"Run: {run.name}  Status: {report['status']}")
    print(f"Progress: {report.get('step', 0):,}/{report['max_steps']:,} steps")
    if report.get("initialized_from"):
        print(f"Initialized from: {report['initialized_from']}")
    best_path = run / "best.pt"
    best = None
    if best_path.is_file():
        import torch

        best = torch.load(best_path, map_location="cpu", weights_only=True)
        print(f"Selected checkpoint: step {best['step']:,} (lowest validation loss)")
    if "validation_loss" in report:
        metric_rows = [
            ("Validation loss", f"{report['validation_loss']:.6f}",
             f"{best['validation_loss']:.6f}" if best else "-"),
            ("Validation MAE (cp)", f"{report['validation_mae']:.2f}",
             f"{best['validation_mae']:.2f}" if best else "-"),
            ("Validation RMSE (cp)", f"{report['validation_rmse']:.2f}",
             f"{best['validation_rmse']:.2f}" if best else "-"),
        ]
        print("\nValidation")
        print(format_table(("Metric", "Latest", "Selected"), metric_rows))
    if "train_loss" in report:
        print(f"\nLast training interval: data={report['train_data_loss']:.6f}, "
              f"total={report['train_loss']:.6f}")
        if "train_accumulator_overflow_penalty" in report:
            config_path = run / "config.json"
            weight = (json.loads(config_path.read_text(encoding="utf-8"))["training"].get(
                "accumulator_overflow_penalty", 0.0
            ) if config_path.is_file() else 0.0)
            raw = report["train_accumulator_overflow_penalty"]
            print(f"Overflow penalty: raw={raw:.6f}, weighted={raw * weight:.8f}")
    if "positions_per_second" in report:
        print(f"Throughput: {report['positions_per_second']:,.0f} positions/s")
    counts = report.get("filter_counts", {})
    if counts:
        print(f"\nDataset: {report.get('train_positions', 0):,} training, "
              f"{report.get('validation_positions', 0):,} validation positions")
        print(format_table(("Cache count", "Positions"), [
            (name.replace("_", " "), f"{count:,}") for name, count in sorted(counts.items())
        ]))
    if "material_values_cp" in report:
        from .model import PIECE_ORDER

        label = "Selected" if report["status"] == "complete" else "Latest"
        rows = [
            (f"{label} opening material", *(_cp(report['material_values_cp'][piece]) for piece in PIECE_ORDER)),
            (f"{label} opening PST", *(_cp_range(*report['pst_ranges_cp'][piece]) for piece in PIECE_ORDER)),
            (f"{label} endgame material", *(_cp(report['endgame_material_values_cp'][piece]) for piece in PIECE_ORDER)),
            (f"{label} endgame PST", *(_cp_range(*report['endgame_pst_ranges_cp'][piece]) for piece in PIECE_ORDER)),
        ]
        if report["status"] != "complete" and best is not None:
            from .engine import load_run_parameters

            parameters, _ = load_run_parameters(run)
            rows.extend(_piece_rows(
                parameters["material"], parameters["pst"],
                parameters["material_endgame"], parameters["pst_endgame"], "Selected"
            ))
        print("\nMaterial and PST ranges (cp; reachable squares)")
        print(format_table(("Parameter", *(piece.title() for piece in PIECE_ORDER)), rows))
