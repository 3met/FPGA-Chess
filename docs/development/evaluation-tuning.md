# Evaluation and NNUE Tuning

Install the optional dependencies with `python -m pip install -r requirements-tuning.txt`. Tuning commands use `tools/tuning/default_config.json` unless `--config <path>` is supplied.

## Workflow

| Command | Purpose |
| ------- | ------- |
| `python -m tools.tuning train [--rebuild-cache]` | Build or reuse dataset caches and train material, PST, and NNUE parameters. |
| `python -m tools.tuning view-report` | Show training progress, latest versus selected validation metrics, and material/PST values by piece. |
| `python -m tools.tuning quantization-report [--sample-positions N]` | Analyze the selected checkpoint's integer parameters and nodes on validation positions. |
| `python -m tools.tuning engine-commit [--dry-run]` | Export a completed run to engine parameters and regenerate hardware data. |

Training reads the configured Lichess JSONL or JSONL.ZST dataset and writes caches, checkpoints, metrics, parameters, and reports under `work/tuning/`. Training settings live in the configuration file; `--initialize <run>` preserves compatible parameters from another model without reusing its optimizer state. Use `--rebuild-cache` only when an existing cache must be regenerated.

Use `python -m tools.tuning.benchmark --run <run-id>` to measure training and validation throughput using an existing cache and checkpoint. Compare runs with the same checkpoint and machine conditions. `--profile-steps N` adds a CPU operator profile.

`engine-commit` exports a completed run, validates the deployed widths, updates both material/PST sets in `hardware/data/pst_values/pst_values.json`, and regenerates the tracked hardware data. Pass `--run <id>` to select a specific run. Export and hardware verification should use a checkpoint trained for the current RTL activation.

## Model Constraints

Opening and endgame material/PST values are learned separately, with pawn and king material fixed. Symmetry and centering constraints remove redundant offsets, and unreachable pawn squares remain zero. The model uses the engine's piece-count blend described in [evaluation-design.md](../architecture/evaluation-design.md).

Scratch runs start material/PST values from the checked-in engine table. Warm starts preserve learned material, PST, and NNUE parameters.

The NNUE training model follows the hardware feature encoding, perspective ordering, output buckets, and integer arithmetic described in [nnue-evaluator.md](../modules/nnue-evaluator.md). Quantization-aware training retains high-precision parameters while using the deployed integer arithmetic in its forward pass.

The correction is invariant under simultaneously flipping the board vertically, swapping piece colors, and changing the side to move. Exported scores use the engine's 1/128-pawn units.

The quantization report covers parameter ranges, accumulator wrapping, activation occupancy, output clipping, and validation coverage by phase bucket.

`view-report` reads the saved training report and distinguishes the latest state from the checkpoint selected by validation loss; during training, it shows both sets of piece values. `quantization-report` performs a separate validation-position analysis and saves its full results in `quantization.json` under the run directory.

## Dataset Filtering

Cache construction rejects invalid, terminal, and mate-scored standard-chess positions. Roots in check and positions whose selected principal-variation move is a capture are excluded because quiescence search resolves those tactical transitions before relying on a quiet static score. The validation split is deterministic and groups positions by the piece placement and side to move visible to the model, ignoring castling and en-passant fields it cannot consume. Color-flipped positions are placed in the same group because the model enforces that symmetry exactly, preventing equivalent positions from leaking across training and validation.

The dataset split is stable across training seeds, and shuffling is deterministic for a fixed seed. Symmetry-equivalent positions receive no additional mirrored samples. Duplicates within a split are retained. WandB logging is optional.
