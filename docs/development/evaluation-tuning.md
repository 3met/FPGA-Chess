# Evaluation and NNUE Tuning

Install the optional dependencies with `python -m pip install -r requirements-tuning.txt`. Tuning commands use `tools/tuning/default_config.json` unless `--config <path>` is supplied.

## Workflow

| Command | Purpose |
| ------- | ------- |
| `python -m tools.tuning train` | Build or reuse dataset caches and train material, PST, and NNUE parameters. |
| `python -m tools.tuning view-report` | Summarize the latest active or completed run. |
| `python -m tools.tuning quantization-report [--sample-positions N]` | Measure trained integer parameter and node ranges on validation positions. |
| `python -m tools.tuning engine-commit [--dry-run]` | Export a completed run to engine parameters and regenerate hardware data. |

Training reads the configured local Lichess JSONL or JSONL.ZST data and writes caches, logs, checkpoints, metrics, parameters, and a run report under ignored `work/tuning/`. Runs stop by optimizer step and support early stopping. Use `--initialize <run>` to initialize a new run from another model checkpoint without reusing its optimizer state.

`engine-commit` exports the latest completed run. An interrupted run must be selected explicitly with `--run <id>`, in which case its best checkpoint is used. Export validates all engine widths before updating `hardware/data/pst_values/pst_values.json` and regenerating tracked hardware data.

## Model Constraints

Material and PST use separate parameter groups. Pawn and king material are fixed; other material values and reachable PST entries are learned. Symmetry and centering constraints remove redundant offsets, and unreachable pawn squares remain zero.

The NNUE model matches the hardware's direct piece-square feature encoding, 256-lane accumulator arithmetic, clipped activation, perspective ordering, piece-count output buckets, and quantized output layer. Quantization-aware training uses the same integer ranges and modular accumulator behavior as RTL so exported weights require no rescaling. Checkpoints carry a numerical-model identifier, and incompatible shapes or model versions are rejected.

`training.nnue_output_buckets` accepts a divisor of 32 for controlled architecture experiments; the deployed geometry uses sixteen equal two-piece buckets. `training.initialize_material_pst_from_engine` starts material and PST at the checked-in engine tables while initializing the new NNUE correction to zero. `training.pst_warmup_steps` can hold NNUE parameters fixed while material and PST train, but remains zero by default.

The deployed correction is invariant under simultaneously flipping the board vertically, swapping piece colors, and changing the side to move. The training loss converts the hardware score unit to centipawns, while the exported correction remains in the engine's 1/128-pawn units.

Generated NNUE files use the packing described in [nnue-evaluator.md](../modules/nnue-evaluator.md). Export preserves the rounding and packing expected by RTL so Python inference and hardware remain bit-compatible.

## Dataset Filtering

Cache construction rejects invalid or terminal standard-chess positions and records side to move with the piece data and target. Configuration can exclude roots in check and positions whose selected principal-variation move is a capture or check. WandB logging is optional and disabled by default.
