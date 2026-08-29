# Evaluation and NNUE Tuning

Install the optional dependencies with `python -m pip install -r requirements-tuning.txt`. Tuning commands use `tools/tuning/default_config.json` unless `--config <path>` is supplied.

## Workflow

| Command | Purpose |
| ------- | ------- |
| `python -m tools.tuning train` | Build or reuse dataset caches and train material, PST, and NNUE parameters. |
| `python -m tools.tuning view-report` | Summarize the selected or most recent run. |
| `python -m tools.tuning quantization-report [--sample-positions N]` | Measure trained integer parameter and node ranges on validation positions. |
| `python -m tools.tuning engine-commit [--dry-run]` | Export a completed run to engine parameters and regenerate hardware data. |

Training reads the configured Lichess JSONL or JSONL.ZST dataset and writes caches, checkpoints, metrics, parameters, and reports under `work/tuning/`. Training settings live in the configuration file; `--initialize <run>` starts from another model without reusing its optimizer state.

`engine-commit` exports a completed run, validates the deployed widths, updates `hardware/data/pst_values/pst_values.json`, and regenerates the tracked hardware data. Pass `--run <id>` to select a specific run.

## Model Constraints

Material and PST use separate parameter groups. Pawn and king material are fixed; other material values and reachable PST entries are learned. Symmetry and centering constraints remove redundant offsets, and unreachable pawn squares remain zero.

The NNUE model matches the hardware's direct piece-square encoding, accumulator arithmetic, clipped activation, perspective ordering, piece-count output buckets, and quantized output layer. Quantization-aware training uses the deployed integer ranges and modular behavior so exported weights require no rescaling.

The correction is invariant under simultaneously flipping the board vertically, swapping piece colors, and changing the side to move. Exported scores use the engine's 1/128-pawn units.

Generated NNUE files use the packing described in [nnue-evaluator.md](../modules/nnue-evaluator.md). Export preserves the rounding and packing expected by RTL so Python inference and hardware remain bit-compatible.

## Dataset Filtering

Cache construction rejects invalid or terminal standard-chess positions. Roots in check and positions whose selected principal-variation move is a capture are excluded because quiescence search resolves those tactical transitions before relying on a quiet static score. Training and validation sampling are deterministic for a fixed configuration and seed. WandB logging is optional.
