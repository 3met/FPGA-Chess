# NNUE Evaluator (`nnue_evaluator`)

The evaluator keeps a circular set of two-perspective accumulator snapshots per search thread. Search orders each thread's updates and waits for completion before evaluating that thread. Results contain a side-to-move-relative NNUE correction and a White-relative material/PST blend; search combines them and saturates to the finite, non-mate score range.

## Model and Parameters

`nnue_defs` defines the accumulator node count per perspective, vector multiplier width, output bucket count, and piece-count mapping. The node count must be a multiple of the vector width. Defaults are 512 nodes per side, 256 multipliers, and eight output buckets. The default buckets cover piece counts 2–5, 6–9, through 30–32. Model images and the training/export geometry must match these parameters.

Accumulator values and biases are signed six-bit integers, transformer weights signed two-bit integers, activations unsigned four-bit integers, and output weights signed four-bit integers. Accumulator arithmetic wraps modulo 64 without saturation; add/remove updates therefore remain exact inverses. Training penalizes overflow. Activation is `min(15, floor(max(0, accumulator)^2 / 8))`. Output bias remains unsigned six-bit, and the complete dot product retains sufficient signed width until search applies score saturation.

Each perspective has 768 direct piece-square features: six friendly and six opposing piece types over 64 squares. The Black perspective flips ranks. Kings are ordinary features, and there are no king buckets or horizontal mirroring. The side-to-move perspective is first in the output layer. The datapath reads White then Black accumulator rows and permutes weight-row addresses to implement that ordering.

## Accumulator Storage and Updates

The accumulator is a simple-dual-port BRAM with a registered read output and enabled write port. Each word contains one multiplier vector's worth of accumulator values. The read output directly feeds the activation registers and update adders. Forward-pass reads always take priority; a waiting transformer row holds until the port becomes available. The caller must prevent an evaluation from reading an address being updated.

The engine configuration selects a power-of-two `nnue_cache_entries`. Cache index occupies the low address bits; vector row and thread select the higher bits. Each update reads its source snapshot and writes the result directly into its destination snapshot. A zero-delta copy supports null moves and setup. No separate parent copy is needed for a normal move. Increasing cache depth uses the spare depth of the existing BRAM banks until their capacity is exhausted.

At FPGA configuration, all snapshot rows initialize to accumulator biases; there are no reserved bias rows or runtime bias reload path. Search retains the existing thread board and its selected ply alongside RAM across a warm reset. Setup serially removes each old square feature and adds its replacement, committing that board tile only after completion. A selected snapshot outside slot zero is first copied to slot zero. Reset and cancellation drain accepted board and NNUE work before clearing ownership, preserving the board/accumulator correspondence.

The transformer uses three disjoint BRAM banks, each with two registered read ports. Bank selection is `(oriented_square + relative_color) mod 3`. Each bank reserves sixteen pawn entries and twenty-two entries per other piece type per color, plus a dedicated zero row. Unreachable pawn end-rank entries map to that zero row and are omitted from physical storage. The zero vector is initialized explicitly and cannot be overwritten by model data. Unused ports read that zero row. Ordinary captures separate mover and victim by color, and both en passant and standard castling fit within two reads per bank in each perspective. Promotions use the same square/color mapping.

An elastic input register separates search feature encoding from bank decoding and holds the next request during writeback. The controller emits move deltas with `combine` set. The evaluator collects their feature addresses and signs into bank slots until the final `complete` request. It then processes both perspectives as one ordered update. Setup combines at most one removed and one added feature per square. A completion marker performs no write and returns its thread/ply tag after preceding transactions finish.

The six ROM outputs are sign-adjusted, summed into a signed four-bit delta, and registered. Standard moves add/remove at most four signed two-bit features; opposite signs bound the total to four bits. On that same clock, the accumulator read port captures the old row. The registered sum and old accumulator drive the modular update adder and RAM write port. Transformer reads, sum/accumulator reads, and writes overlap across rows; without forward-pass contention, one row advances per cycle. Pending update transactions are processed one at a time.

## Forward Pipeline

Each request streams all accumulator rows through registered memory output, registered activation, registered multiplier products, and one registered vector sum. The next request starts reading immediately after the previous request's last row, while older products and sums drain. Per-row validity, first/last markers, bias, and PST data preserve request ordering without resetting the datapath between evaluations.

With `R = 2 * nodes_per_side / vector_width`, the minimum initiation interval is `R` clocks and the result latency is `R + 3` clocks from acceptance. A sustained request stream has no idle multiplier cycles. The registered partial sums accumulate across rows, and output bias is added once at the end.

In parallel, material/PST scores interpolate from the two-king endgame value to the full-board first-phase value, using signed truncation. Reciprocal division runs through the same pipeline and remains aligned with its NNUE result.

## Multiplier Packing

The Cyclone V wrapper groups two independent unsigned 18×18 multipliers into one DSP. Each multiplier computes `(a0 + 256*a1) * (abs(w0) + 256*abs(w1))`. Bits 7:0 and 23:16 hold the two magnitude products; each weight's sign is restored separately. The largest cross term is `2*15*8 = 240`, below 256, so it cannot carry into the high product. This gives four NNUE products per DSP. Other FPGA targets use equivalent inferred arithmetic.

## Model Data

Model images are tracked inputs under `hardware/data/nnue/`, written by the training exporter. Builds require these files and never generate or replace them. Their contents participate in the build fingerprint.

| File | Contents |
| ---- | -------- |
| `feature_transformer.hex` | Signed two-bit transformer weights, one complete node vector per feature. Unreachable pawn rows are zero. |
| `accumulator_bias.hex` | Signed six-bit two's-complement bias per node, loaded into accumulator BRAM initialization. |
| `output_weights.hex` | Signed four-bit weights, one vector per row, grouped by bucket and perspective. |
| `output_bias.hex` | Unsigned output bias per bucket. |

Training and export use the same arithmetic; see [evaluation tuning](../development/evaluation-tuning.md).
