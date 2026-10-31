# Evaluation Files

A `.nnue.json` file is the sole tracked source of the quantized material, piece-square, and NNUE parameters for a build. Files live under `hardware/data/evaluation/`; `baseline.nnue.json` preserves the evaluation used before this format was introduced. FPGA engine profiles select a repository-relative `evaluation_file` alongside `search_config`. Standalone type profiles also select an `evaluation_file`.

The file contains `metadata`, `architecture`, `weights`, `material`, and `pst`. Metadata identifies the model and may record its training run and selected checkpoint step. There is no version field. Architecture declares the relative piece-square input, accumulator size and activation name, linear output with inclusive piece-count bucket ranges, and evaluation units and phase endpoints. Unsupported architectures or dtypes fail validation. Hardware execution parallelism and accumulator cache capacity are build choices, separate from the model.

## Integer Encoding and Order

NNUE tensors declare `dtype`, `encoding: "base64"`, and `data`. Material uses named JSON integers with `dtype: "int16"`. PSTs declare `dtype: "int10"` and `encoding: "base64"`, with one base64 string per piece in each of `opening` and `endgame`. Every value is already quantized in engine units; loading never rounds or clamps parameters.

Base64 encodes consecutive integer codes as a continuous bitstream. The first value occupies the least-significant bits of the first byte; subsequent values follow immediately, crossing byte boundaries without word padding. Signed values use two's complement. Any unused high bits of the final byte are zero. Payload lengths must match dimensions derived from the architecture.

| Parameter | Dtype | Logical order, outermost first |
| --------- | ----- | ------------------------------ |
| Accumulator weights | `int2` | Feature, accumulator node |
| Accumulator biases | `int6` | Accumulator node |
| Output weights | `int4` | Bucket, perspective, accumulator node |
| Output biases | `uint6` | Bucket |
| Material | `int16` | Phase, named piece |
| PST | `int10` | Phase, named piece, square |

Piece order is pawn, knight, bishop, rook, queen, king. Features contain friendly pieces followed by opposing pieces, each in piece order and then square order. Squares run from a1 through h1, then a2 through h2, up to h8. Black's feature perspective flips ranks. Output perspectives are side to move first, opponent second. Both phases' PSTs use White's square orientation; Black flips ranks. Unreachable pawn end-rank transformer rows and PST entries are zero. Pawn and king material retain their fixed values.

Bucket ranges partition legal piece counts without gaps or overlap. Counts below the legal minimum during board setup use the first bucket. Geometry and ranges drive generated RTL constants; fixed datapath widths and supported phase semantics are validated before compilation.

## Build and Export

`tools/evaluation_model.py` reads and validates the model without training dependencies. Every synthesis, simulation, or profiling build generates its own ROM images and `rtl_config.sv`, which contains model constants and absolute ROM paths. These generated files are build outputs. The selected model's contents participate in build identity, including when its path stays the same.

`python -m tools.tuning engine-commit --run <run>` writes `hardware/data/evaluation/<run-name>.nnue.json`. `--output <path.nnue.json>` selects another destination, and `--dry-run` validates without writing. Export quantizes the training parameters, validates the complete model, and atomically replaces the destination. Selecting the model in an FPGA configuration is a separate edit. Training checkpoints and reports remain in the run directory.
