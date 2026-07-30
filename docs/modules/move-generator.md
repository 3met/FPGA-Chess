# Move Generator (`move_generator`)

`move_generator` contains independent variable-latency noisy and quiet destination-centric pipelines, their class-specific move-ordering datapaths, and an eight-bucket move store split by move class. It emits pseudo-legal moves; `board_update_pipeline` remains responsible for ordinary king safety, pins, discovered checks, and en-passant discovered checks. Castling origin, transit, and destination safety are checked during quiet generation and direct validation because those conditions cannot be reconstructed from only the final board.

## Commands

Independent noisy/direct and quiet ready/valid interfaces each capture one `FullBoard`, `thread`, `ply`, suppression move, and eight current bucket tops. Both pipelines can accept requests and return tagged completions in the same cycle; no compatibility arbiter serializes either direction.

| Command | Behavior |
| --- | --- |
| `MOVE_GEN_VALIDATE_DIRECT` | Pseudo-legally validates the supplied TT/root move and returns it directly without writing a bucket. |
| `MOVE_GEN_GENERATE_NOISY` | Generates captures, en passant, and all promotion choices. |
| `MOVE_GEN_GENERATE_QUIET` | Generates ordinary non-captures and standard castling. |

Each response is tagged with thread and ply. Generation completion is produced only from the final state after the last candidate has been classified and its RAM write has committed; there is no fixed-latency assumption.

An attempted direct move is passed as the exact 14-bit suppression move on later generation commands. Equality includes source, destination, and promotion encoding, so promotion variants remain distinct. A failed direct pseudo-legality validation is not suppressed.

## Destination Context and Generation

Each pipeline has its own 64-bit priority selector and geometry so noisy and quiet destinations for different threads can be processed concurrently. The noisy destination mask contains enemy-occupied non-king squares, an en-passant target only when an adjacent pawn can capture it, and empty rank-8 promotion squares for White or rank-1 promotion squares for Black only when the required pawn push exists. The quiet mask contains empty squares, with pawn promotions filtered into the noisy phase.

For each selected destination, the class pipeline's combinational geometry constructs a context containing the 6-bit destination, 4-bit destination tile, eight nearest occupied ray records `{Tile, distance_minus_one[2:0]}`, and eight fixed knight-source tiles. One destination-indexed 8-by-7 first-occupant network computes the rays. The same selection cycle constructs the 16-bit source mask; pawn bits include the exact single-push, starting-rank double-push, capture, en-passant, and promotion distance constraints. A zero mask consumes the destination without entering candidate expansion. For a nonzero mask, the context is registered and the walker emits at most one explicit candidate per cycle into a one-entry writeback stage. The walker can expand the next source or select the next destination while the previous candidate is scored and written. A promotion source retains the writeback stage while bishop, rook, knight, and queen encodings are emitted; LIFO storage makes queen the first returned promotion.

Castling is sequenced separately for the permitted standard-chess destinations. A side without either castling right bypasses the sequencer, and a denied individual side consumes no check cycle. Permission, king and rook placement, empty path, and attacks on the origin, transit, and final virtual board are checked before storage or direct validation.

## Pipeline and Paths

| Stage | Common work | Next path |
| --- | --- | --- |
| Command capture | Registers board, thread, ply, suppression move, and bucket tops; constructs the phase destination mask. | Direct validation or destination selection. |
| Destination select/context | Priority-selects one destination, removes it from the mask, computes destination tile, eight nearest rays, eight knight tiles, and the plausible-source mask. A zero-source destination remains in this stage for the next selection. | Candidate expansion only for a nonzero source mask. |
| Candidate expansion | Priority-selects and clears one source bit, reconstructs the explicit move, attaches attacker/victim/class metadata, launches a quiet-history read when required, and prepares the next destination context while expanding the final source. Empty and irrelevant lanes consume no cycles. | Places the candidate in writeback while the walker advances directly to a prepared productive destination when possible. |
| Noisy writeback | Runs shared bounded SEE, maps the pending move to bucket 7/6/1/0, writes the move RAM, and advances the selected top concurrently with walker work. Promotion variants retain this stage for four consecutive writes. | Frees the pending slot after the final encoding. |
| Quiet writeback | Receives the synchronous history result launched by expansion, applies the castling bonus when applicable, maps the pending move to bucket 5–2, writes RAM, and advances the top concurrently with walker work. | Frees the pending slot after the write. |
| Castle sequencer | Checks each standard castling side and routes a valid castle through quiet scoring. | Finish after both sides. |
| Completion | Empty destination tails and positions without permitted castles return directly. A pending final write forwards its incremented bucket top with the response on the write cycle. | Idle/next command. |

The pop frontend preserves global bucket priority and routes each request to the pipeline that owns the selected class. Eligible-bucket comparison and highest-bucket selection issue a synchronous RAM read, and the following cycle returns the tagged move and decremented top. Search control forwards a found response directly into board update during that response cycle instead of inserting a separate issue bubble. Pops are independent of generation, so a pop for one thread can overlap either or both class pipelines writing for other threads.

## Ordering

Quiet candidates issue a synchronous read from signed nine-bit `history[color][from][to]` RAM owned only by the quiet pipeline. History is implemented as two 4096-word banks and cleared serially over 4096 cycles after reset or New Game. A quiet beta cutoff produces reward `B = min(63, remaining_depth * 4)` for the winner and half-magnitude depth-scaled maluses for the first three earlier quiets that definitively failed at that node. Each entry applies the signed gravity update `H' = H + B - H * |B| / 256`, with the division implemented as a shift and saturation to the signed nine-bit range.

The updater accepts one combined winner-and-failures event, then performs its read-modify-writes over several background cycles. A same-color generator lookup always takes priority and leaves the update pending for retry, while the split color banks permit a generator lookup on one color concurrently with an update on the other. Controller-side one-entry records retain pending per-thread events, and search drops an event rather than waiting when its record is occupied.

Captures use one shared bounded visible SEE calculation. The classifier compares the immediate attacker and victim, the least valuable visible enemy recapturer, and one visible friendly defender. Removed pieces do not reveal a second slider. En passant uses a pawn victim. The coarse piece values are pawn 1, minor 3, rook 5, queen 9, and king 15.

| Bucket | Meaning |
| --- | --- |
| 7 | Queen promotions; nonnegative captures of rooks or queens. |
| 6 | Other nonnegative captures; underpromotions. |
| 5 | Quiet history score at least 128. |
| 4 | Quiet history score at least 64. |
| 3 | Quiet history score at least 16, including the fixed +16 castling term. |
| 2 | Remaining quiet moves. |
| 1 | Negative-SEE captures of rooks or queens. |
| 0 | Other negative-SEE captures, including losing en passant. |

Only the 14-bit `Move` is stored. Scores, links, classes, and consumed masks are not retained. Ordering within a bucket is deterministic LIFO.

## Bucket RAMs and Stack-Arena Semantics

Each bucket is a synchronous simple-dual-port 14-bit RAM with an independent compile-time power-of-two per-thread capacity, defaulting to 512 moves. The noisy pipeline owns buckets 0, 1, 6, and 7; the quiet pipeline owns buckets 2 through 5, so concurrent generation never contends for a bucket write port. Addresses concatenate the configured thread region with the bucket offset. Generation uses the write port while a pop for another thread may use the read port.

For every node the search stack stores eight tops. A push writes at `top` and increments it. A pop decrements the selected top and synchronously reads the move at that address. The node's lower bounds are the parent's current tops, or zero at the root; the node is empty in a bucket when its current top equals that lower bound.

The parent move is popped before descent, and the child copies the resulting parent tops as both its initial tops and lower bounds. Descendants can therefore reuse the released slot while still-unsearched ancestor moves below the parent's current tops remain protected. Restoring the packed parent search-stack entry restores its remaining move state. No allocator, free list, per-move link, overflow bucket, or move-consumed mask exists.

Before a write that would exceed a thread region, the module suppresses both the RAM write and top increment, sets sticky overflow, captures bucket and thread, increments a saturating overflow counter, and reports a simulation error when overflow assertions are enabled. Correct search operation assumes overflow never occurs.

## Initialization, Flush, and Instrumentation

Move RAM contents are never cleared. Reset and New Game serialize clearing only in the quiet pipeline's history RAM; bucket storage is reclaimed by resetting node tops. Flush cancels active variable-latency commands and pop state on Kill or New Game.

Optional counters record noisy and quiet moves, analyzed destinations, emitted candidates, history lookups, generation cycles, per-bucket writes, and per-bucket high-water tops. Overflow status and identification remain present when optional statistics are disabled.
