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

Use `python -m tools.tuning.benchmark --run <run-id>` to measure training throughput against the existing cache and selected checkpoint without writing a training run. It times repeated complete optimizer steps after compilation warmup, reports data-loading and update time separately, then times a full validation pass and estimates the configured validation-cycle throughput. Use the same command, machine load, and checkpoint before and after performance changes; `--profile-steps N` adds a CPU operator profile outside the timed windows.

The learning rate warms linearly for the first 1.5% of optimizer steps and then follows cosine decay to the configured final fraction of its peak. This schedule retains a short high-rate exploration period while giving quantization-aware weights time to settle across integer thresholds.

`engine-commit` exports a completed run, validates the deployed widths, updates both material/PST sets in `hardware/data/pst_values/pst_values.json`, and regenerates the tracked hardware data. Pass `--run <id>` to select a specific run. Export and hardware verification should use a checkpoint trained for the current RTL activation.

## Model Constraints

Opening and endgame material/PST sets use separate parameter groups. Pawn and king material are fixed in both sets; other material values and reachable PST entries are learned. The opening weight is `(piece_count - 2) / 30`, using the same piece count as the NNUE output bucket. Symmetry and centering constraints remove redundant offsets, and unreachable pawn squares remain zero.

Scratch runs start both material/PST sets from the checked-in engine table. Warm starts preserve the checkpoint's learned material, PST, and NNUE parameters instead. The deployable output-bucket count, AdamW optimizer, and score-probability loss are fixed rather than configurable.

The NNUE training model uses the hardware's direct piece-square encoding, perspective ordering, piece-count output buckets, and integer blend. Its quantization target has five-bit signed modular accumulators, four-bit unsigned accumulator biases, three-bit signed output weights, and six-bit unsigned output biases. After wrapping, each accumulator is mapped to the three-bit SCReLU code `min(7, floor(max(0, accumulator)² / 8))`. The RTL implements the same integer mapping. A small derived lookup table decodes piece-square features during training without increasing checkpoint size. Scratch initialization uses paired integer lanes that give an exact zero correction without dead gradients or a mostly-zero quantized network. Quantization-aware training keeps high-precision shadow parameters and applies the target integer arithmetic in the forward pass. Optimizer decay is limited to NNUE weights, and outward momentum is cleared when an NNUE shadow reaches a legal bound.

The auxiliary accumulator overflow loss is quadratic at the five-bit boundary and linear for larger excursions, so wrapped lanes receive a corrective gradient without letting a few deep wraps dominate training. The forward pass uses the target modular accumulator values.

The SCReLU calculation floors the division to keep integer activation codes and 3×3-bit output multiplications. Its positive input ranges from 0 to 15, and inputs of 8 or more produce the maximum activation code 7.

The correction is invariant under simultaneously flipping the board vertically, swapping piece colors, and changing the side to move. Exported scores use the engine's 1/128-pawn units.

Generated NNUE files retain the output-weight packing described in [nnue-evaluator.md](../modules/nnue-evaluator.md). The quantization report includes parameter ranges, occupancy, and nonnegative share for signed parameters; zero-weight rates by friendly and opposing piece category; accumulator ranges and wrapping; paired SCReLU input/output code frequencies; output clipping; and the number of sampled validation positions assigned to each phase bucket.

`view-report` reads the saved training report and distinguishes the latest state from the checkpoint selected by validation loss; during training, it shows both sets of piece values. `quantization-report` performs a separate validation-position analysis and saves its full results in `quantization.json` under the run directory.

## Dataset Filtering

Cache construction rejects invalid, terminal, and mate-scored standard-chess positions. Roots in check and positions whose selected principal-variation move is a capture are excluded because quiescence search resolves those tactical transitions before relying on a quiet static score. The validation split is deterministic and groups positions by the piece placement and side to move visible to the model, ignoring castling and en-passant fields it cannot consume. Color-flipped positions are placed in the same group because the model enforces that symmetry exactly, preventing equivalent positions from leaking across training and validation.

Cache parsing rejects obvious captures directly from FEN before constructing a chess board. For ordinary four-field FENs, it decodes piece placement once into both board bitboards and training features; other FENs use the standard parser. Remaining candidates still receive legal-move and terminal-position checks. A legal selected move itself rules out mate and stalemate, avoiding a redundant search for legal moves during cache construction.

No mirrored datapoints are added. A color flip is already an architectural invariant and would only duplicate sample weight, while horizontal reflection and vertical reflection without a color swap are not exact symmetries of reachable standard-chess positions. Exact and model-visible duplicates are retained within a split: they are rare in the Lichess evaluation dump, and global deduplication would require a large index while changing the source distribution. The default validation set remains large enough to cover the sparsely populated endgame output buckets without phase-stratified sampling. Training shuffling is deterministic for a fixed seed, while the dataset split remains stable across training seeds. WandB logging is optional.
