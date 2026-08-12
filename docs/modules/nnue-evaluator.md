# NNUE Evaluator (`nnue_evaluator`)

The NNUE evaluator produces a side-to-move-relative correction that search adds to material plus PST after converting the latter to side-to-move point of view. It stores one live accumulator per search thread; callers must preserve per-thread update ordering and wait for outstanding updates before evaluating that thread.

## Encoding

Each perspective uses 768 direct piece-square features: six friendly and six opposing piece types over 64 vertically oriented squares. The Black perspective flips ranks before indexing, so both perspectives share one transformer. Kings are ordinary features; there are no king buckets or horizontal mirroring.

Transformer rows contain 256 signed two-bit weights packed four per byte. Each perspective therefore has 256 accumulator lanes. Each feature addition or removal updates all 512 perspective lanes in one request cycle, preserving the existing one-row-per-cycle update throughput. Direct features make every legal board change incremental, including castling; null moves require no feature change.

## Accumulator Updates

Each thread owns White and Black accumulator vectors. A clear starts a perspective from the trained bias, while add and remove requests apply one transformer row. Accumulator arithmetic is modular and matches quantization-aware training, so removing a feature exactly reverses adding it even across a wrap.

Before search, the controller builds the root accumulator for every thread. An ordinary move applies compact feature deltas to the live child state, stores the reversible delta with the ply record, and applies its inverse after board reversal. Castling updates the king and rook features; a null child keeps the parent accumulator unchanged.

The final request in an update plan marks completion and returns the tagged thread and ply. Real feature requests always update both perspectives together, while an ordered completion-only request bypasses the accumulator datapath and its wide state write. Requests from different thread plans share one streaming update port, while evaluation uses a logically independent accumulator read path. The storage implementation is portable inferred memory and does not depend on vendor primitives.

Reset, New Game, Kill, and search restart flush in-flight datapath work. Accumulator RAM contents need not be erased because the controller tracks which per-thread state is valid.

## Output Layer

Evaluation clips each biased accumulator value to the trained activation range, places the side-to-move perspective before the opposing perspective, and applies the quantized output layer and bias. Sixteen output heads use the incrementally maintained total piece count: counts 2-3 use head 0, counts 4-5 use head 1, counts 30-31 use head 14, and the full 32-piece position uses head 15. This alignment gives the legal two-king minimum a head trained by three-piece positions. A 128-lane MAC evaluates the 512 inputs in four cycles; a synchronous block-ROM prefetch supplies one 384-bit weight row ahead of the MAC, so output-head selection adds neither a cycle nor combinational selection muxes. Every signed activation-weight product uses generic multiplication so each synthesis target may choose its own LUT, DSP, packing, and MAC implementation. The result is clipped to the finite search-score range.

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
| Output weights | `16 * 512 * 3` bits | 3 KiB |
| Output biases | `16 * 5` bits | 10 B |
| Total trained parameters |  | 52,330 B (51.1 KiB) |

Runtime accumulator storage is separate from trained parameter memory. Each thread has two 256-lane signed-five-bit perspectives, or 320 B per logical state. Multi-thread builds keep update and evaluation mirrors to provide independent read paths; a single-thread build snapshots the update state directly and lets synthesis remove the otherwise wasteful one-word evaluation mirror.

On the single-thread Cyclone V target, the transformer maps to 393,216 block-memory bits in 52 M10Ks. The 24,576-bit output-weight table maps to ten additional M10Ks because its 384-bit read width spans ten physical blocks; the accumulator and output biases remain in logic. With generic inferred multiplication, synchronous output-weight prefetch, and request-level accumulator-update gating, the complete fitted evaluator uses 3,050.5 ALMs, 5,398 logic registers, 62 M10Ks, and 80 DSP blocks.
