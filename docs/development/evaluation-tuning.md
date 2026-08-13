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

`training.batch_size` remains the effective optimizer batch. `training.microbatch_size` may split it into smaller forward/backward chunks whose gradients are accumulated before one optimizer step; `auto` uses 2,048-position chunks on CPU to reduce the NNUE accumulator working set and keeps the full batch on accelerators. Microbatching does not change the effective batch or loss.

The default loss is the unweighted squared difference between transformed prediction and target, where `F(x) = 0.5 * (1 + sigmoid((x - O) / S) - sigmoid((-x - O) / S))`, `O = 270 cp`, and `S = 380 cp`. AdamW uses a peak learning rate of 0.01 and weight decay of 0.00001. The first 1.5% of optimizer steps linearly warm from 10% to 100% of the peak rate, after which the rate decays by a factor of 0.992 per complete pass over the training set.

`engine-commit` exports the latest completed run. An interrupted run must be selected explicitly with `--run <id>`, in which case its best checkpoint is used. Export validates all engine widths before updating `hardware/data/pst_values/pst_values.json` and regenerating tracked hardware data.

## Model Constraints

Material and PST use separate parameter groups. Pawn and king material are fixed; other material values and reachable PST entries are learned. Symmetry and centering constraints remove redundant offsets, and unreachable pawn squares remain zero.

The NNUE model matches the hardware's direct piece-square feature encoding, 256-lane accumulator arithmetic, clipped activation, perspective ordering, piece-count output buckets, and quantized output layer. Quantization-aware training uses the same integer ranges and modular accumulator behavior as RTL so exported weights require no rescaling. Checkpoint compatibility is determined directly from the stored tensor names and shapes.

`training.nnue_output_buckets` accepts a divisor of 32 for controlled architecture experiments; the deployed geometry uses eight heads covering the 31 legal piece counts as 2-5, 6-9, 10-13, 14-17, 18-21, 22-25, 26-29, and 30-32. Counts below two are impossible in a valid standard-chess position and consume no bucket range. Training does not apply phase-dependent bucket weighting. `training.accumulator_overflow_penalty` discourages unwrapped accumulator values outside the signed five-bit state, and latent quantization-aware parameters are projected into their deployed integer ranges after every optimizer step so saturated straight-through values remain trainable. `training.initialize_material_pst_from_engine` starts material and PST at the checked-in engine tables while initializing the new NNUE correction to zero. `training.pst_warmup_steps` can hold NNUE parameters fixed while material and PST train, but remains zero by default.

The deployed correction is invariant under simultaneously flipping the board vertically, swapping piece colors, and changing the side to move. The training loss converts the hardware score unit to centipawns, while the exported correction remains in the engine's 1/128-pawn units.

Generated NNUE files use the packing described in [nnue-evaluator.md](../modules/nnue-evaluator.md). Export preserves the rounding and packing expected by RTL so Python inference and hardware remain bit-compatible.

## Dataset Filtering

Cache construction rejects invalid or terminal standard-chess positions and records side to move with the piece data and target. The default depth floor is 20; roots in check and positions whose selected principal-variation move is a capture are excluded because quiescence search resolves those tactical transitions before relying on a quiet static score. Exact reservoir sampling randomly selects the validation subset, the training loader reshuffles every pass, and validation uses one deterministic shuffled permutation for reproducible checkpoint comparisons. WandB logging is optional and disabled by default.
