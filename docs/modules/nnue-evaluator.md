# NNUE Evaluator (`nnue_evaluator`)

The NNUE evaluator produces a side-to-move-relative correction that search adds to material plus PST after converting the latter to side-to-move point of view. It stores one live accumulator per search thread; callers must preserve per-thread update ordering and wait for outstanding updates before evaluating that thread.

## Encoding

Each perspective uses 768 direct piece-square features: six friendly and six opposing piece types over 64 vertically oriented squares. The Black perspective flips ranks before indexing, so both perspectives share one transformer. Kings are ordinary features; there are no king buckets or horizontal mirroring.

Transformer rows contain 256 signed two-bit weights packed four per byte. Each perspective therefore has 256 accumulator lanes. Each feature addition or removal updates both perspectives together. Direct features make every legal board change incremental, including castling; null moves require no feature change.

## Accumulator Updates

Each thread owns White and Black accumulator vectors. A clear starts a perspective from the trained bias, while add and remove requests apply one transformer row. Accumulator arithmetic is modular and matches quantization-aware training, so removing a feature exactly reverses adding it even across a wrap.

Before search, the controller builds the root accumulator for every thread. An ordinary move applies compact feature deltas to the live child state, stores the reversible delta with the ply record, and applies its inverse after board reversal. Castling updates the king and rook features; a null child keeps the parent accumulator unchanged.

The final request in an update plan marks completion and returns the tagged thread and ply. Requests from different threads share the update path, while evaluation has an independent accumulator read path.

Reset, New Game, Kill, and search restart flush in-flight datapath work. Accumulator RAM contents need not be erased because the controller tracks which per-thread state is valid.

## Output Layer

Evaluation clips each biased accumulator value to the trained activation range, places the side-to-move perspective before the opposing perspective, and applies the quantized output layer and bias. Eight output heads cover piece counts 2-5, 6-9, 10-13, 14-17, 18-21, 22-25, 26-29, and 30-32. The result is clipped to the finite search-score range.

Swapping every piece color, flipping the board vertically, and flipping the turn leaves the ordered model input and correction unchanged. The RTL uses portable inferred memories and arithmetic; synthesis hints or target resource choices must not change numerical behavior.

## Model Data

Generated parameters live under `hardware/data/nnue/`:

| File | Contents |
| ---- | -------- |
| `feature_transformer.hex` | Packed transformer rows. |
| `accumulator_bias.hex` | Per-lane accumulator bias. |
| `output_weights.hex` | Packed output-layer weights. |
| `output_bias.hex` | Output bias. |

The tuning and export workflow is described in [evaluation-tuning.md](../development/evaluation-tuning.md). `python hardware/scripts/generate_nnue_defaults.py` creates a legal zero-correction model for development and tests.

## Parameter Memory

| Parameter | Shape and Width | Logical Size |
| --------- | --------------- | ------------ |
| Feature transformer | `768 * 256 * 2` bits | 48 KiB |
| Accumulator bias | `256 * 3` bits | 96 B |
| Output weights | `8 * 512 * 3` bits | 1.5 KiB |
| Output biases | `8 * 5` bits | 5 B |
| Total trained parameters |  | 50,789 B (49.6 KiB) |

Runtime accumulator storage is separate from trained parameter memory. Each thread has two 256-lane signed-five-bit perspectives.
