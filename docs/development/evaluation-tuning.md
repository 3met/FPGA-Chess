# Evaluation and NNUE Tuning

Use `tools.tuning` to train material, piece-square tables (PSTs), and NNUE parameters, inspect validation results, and export parameters to the engine. Run commands from the repository root.

## Setup and Training

Install the optional dependencies:

```text
python -m pip install -r requirements-tuning.txt
```

Settings default to [`tools/tuning/default_config.json`](../../tools/tuning/default_config.json). Copy that file to customize the dataset path, filtering, training device, training schedule, or output directory. The dataset must be a local Lichess evaluation file in JSONL or JSONL.ZST format.

```text
python -m tools.tuning train --config <config-path>
```

Training builds or reuses a dataset cache and saves runs under the configured output root, which defaults to `work/tuning/`. Use `--rebuild-cache` when a matching cache needs regeneration.

Resume from a run's latest checkpoint, or start a new run from its best model:

```text
python -m tools.tuning train --config <config-path> --resume <run-id-or-path>
python -m tools.tuning train --config <config-path> --initialize <run-id-or-path>
```

Resume restores training state; the configuration must match the original run except for `training.max_steps`. Initialization keeps compatible model parameters and starts a fresh optimizer. The two options are mutually exclusive. Training from scratch starts material/PST values from the checked-in engine table.

## Inspect and Export

```text
python -m tools.tuning view-report --run <run-id-or-path>
python -m tools.tuning quantization-report --run <run-id-or-path>
python -m tools.tuning engine-commit --run <run-id-or-path> --dry-run
python -m tools.tuning engine-commit --run <run-id-or-path>
```

These commands also accept `--config <path>`. Omit `--run` to select the latest run under that configuration's output root.

| Command | Result |
| ------- | ------ |
| `view-report` | Shows training progress, latest and best-checkpoint validation metrics, and material/PST values. |
| `quantization-report` | Analyzes integer ranges, accumulator wrapping, activation occupancy, output clipping, and phase-bucket coverage. Saves `quantization.json` in the run directory. Use `--sample-positions <count>` to control sample size. |
| `engine-commit --dry-run` | Shows the exported material values without changing engine files. |
| `engine-commit` | Validates hardware widths, updates opening/endgame material and PST data, writes NNUE ROM images, and regenerates tracked hardware data. |

Despite its name, `engine-commit` writes files; it does not create a Git commit. Without `--run`, export requires the latest run to be complete. An explicit run can export saved parameters or its best checkpoint. Use a model compatible with the current RTL, review the generated changes, and run [build and verification](build-test-synthesis.md) before deploying them.

Runs contain `report.json`, `metrics.jsonl`, `latest.pt` for resuming, `best.pt` for the checkpoint selected by validation loss, and `parameters.json` after successful completion.

## Measure Training Speed

With an existing dataset cache:

```text
python -m tools.tuning.benchmark --config <config-path> --run <run-id-or-path>
```

The benchmark measures optimizer throughput and full validation time after warmup. Use `--steps`, `--warmup`, and `--repeats` to control the measurement, or `--profile-steps <count>` to add a CPU operator profile. Compare runs using the same checkpoint, configuration, and machine conditions.

## Model and Dataset

Training follows the engine's [evaluation blend](../architecture/evaluation-design.md) and [NNUE feature encoding and integer arithmetic](../modules/nnue-evaluator.md). Quantization-aware training uses deployed integer arithmetic in the forward pass while retaining high-precision parameters. Opening and endgame material/PST values are learned separately; pawn and king material stay fixed.

Cache construction rejects invalid, terminal, and mate-scored positions. The default filters also exclude roots in check and positions whose selected principal-variation move is a capture, leaving quiet positions for static evaluation. Filtering thresholds are configured in the JSON file.

The validation split groups positions by the inputs visible to the model and keeps color-flipped equivalents together to prevent leakage. The split is deterministic; training shuffling is deterministic for a fixed seed. WandB logging is optional and configured in the same file.
