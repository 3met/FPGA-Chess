# Move Generator (`move_generator`)

`move_generator` is a shared, variable-latency destination-centric generator, move-ordering datapath, and eight-bucket move store. It emits pseudo-legal moves; `board_update_pipeline` remains responsible for ordinary king safety, pins, discovered checks, and en-passant discovered checks. Castling origin, transit, and destination safety are checked in the generator because those conditions cannot be reconstructed from only the final board.

## Commands

The ready/valid command interface captures one `FullBoard`, `thread`, `ply`, suppression move, and eight current bucket tops.

| Command | Behavior |
| --- | --- |
| `MOVE_GEN_VALIDATE_DIRECT` | Pseudo-legally validates the supplied TT/root move and returns it directly without writing a bucket. |
| `MOVE_GEN_GENERATE_NOISY` | Generates captures, en passant, and all promotion choices. |
| `MOVE_GEN_GENERATE_QUIET` | Generates ordinary non-captures and standard castling. |

The response is tagged with thread and ply. Generation completion is produced only from the final state after the last candidate has been classified and its RAM write has committed; there is no fixed-latency assumption.

An attempted direct move is passed as the exact 14-bit suppression move on later generation commands. Equality includes source, destination, and promotion encoding, so promotion variants remain distinct. A failed direct pseudo-legality validation is not suppressed.

## Destination Context and Generation

One 64-bit priority selector schedules only destinations in the active phase. The noisy destination mask contains enemy-occupied non-king squares, an en-passant target only when an adjacent pawn can capture it, and empty rank-8 promotion squares for White or rank-1 promotion squares for Black only when the required pawn push exists. The quiet mask contains empty squares, with pawn promotions filtered into the noisy phase.

For each selected destination, shared combinational geometry constructs a context containing the 6-bit destination, 4-bit destination tile, eight nearest occupied ray records `{Tile, distance_minus_one[2:0]}`, and eight fixed knight-source tiles. One destination-indexed 8-by-7 first-occupant network computes the rays. The same selection cycle constructs the 16-bit source mask; pawn bits include the exact single-push, starting-rank double-push, capture, en-passant, and promotion distance constraints. A zero mask consumes the destination without entering candidate expansion. For a nonzero mask, the context is registered and the generator emits at most one explicit candidate per cycle. Candidate expansion retains defensive geometry validation and carries whether it removed the final source, allowing the scoring/write return path to select the next destination directly instead of spending an empty expansion cycle. A promotion source is retained while bishop, rook, knight, and queen encodings are emitted; LIFO storage makes queen the first returned promotion.

Castling is sequenced separately for the two standard-chess destinations. Permission, king and rook placement, empty path, and attacks on the origin, transit, and final virtual board are checked before storage or direct validation.

## Pipeline and Paths

| Stage | Common work | Next path |
| --- | --- | --- |
| Command capture | Registers board, thread, ply, suppression move, and bucket tops; constructs the phase destination mask. | Direct validation or destination selection. |
| Destination select/context | Priority-selects one destination, removes it from the mask, computes destination tile, eight nearest rays, eight knight tiles, and the plausible-source mask. A zero-source destination remains in this stage for the next selection. | Candidate expansion only for a nonzero source mask. |
| Candidate expansion | Priority-selects and clears one source bit, reconstructs the explicit move, and attaches attacker/victim/class and last-source data. Empty and irrelevant lanes consume no cycles. | Noisy score, early quiet-history read, next source, or next destination. |
| Noisy score/write | Runs shared bounded SEE, maps the move to bucket 7/6/1/0, writes the move RAM, and advances the selected top. Promotion variants repeat this stage. | Next source, or next destination after the last source. |
| Quiet history return/write | Receives the synchronous history result launched directly by expansion, applies the castling bonus when applicable, maps to bucket 5–2, writes RAM, and advances the top. | Next source, next destination after the last source, or castle sequencer. |
| Castle sequencer | Checks each standard castling side and routes a valid castle through quiet scoring. | Finish after both sides. |
| Finish fence | Returns final tagged tops only after the last write state has completed. | Idle/next command. |

The pop path is independent of generation: eligible-bucket comparison and highest-bucket selection issue a synchronous RAM read, and the following cycle returns the tagged move and decremented top. Search control forwards a found response directly into board update during that response cycle instead of inserting a separate issue bubble. A pop for one thread can overlap generation writes for another thread.

## Ordering

Quiet candidates issue a synchronous read from shared signed nine-bit `history[color][from][to]` RAM. History is implemented as two 4096-word banks and cleared serially over 4096 cycles after reset or New Game. A quiet beta cutoff adds `min(63, remaining_depth * 4)` with saturation at +255; no malus is applied. Update read-modify-write has priority over a same-bank candidate lookup, and controller-side one-entry records retain pending per-thread updates.

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

Each bucket is a synchronous simple-dual-port 14-bit RAM with an independent compile-time power-of-two per-thread capacity, defaulting to 512 moves. Addresses concatenate the configured thread region with the bucket offset. Generation uses the write port while a pop for another thread may use the read port.

For every node the search stack stores eight tops. A push writes at `top` and increments it. A pop decrements the selected top and synchronously reads the move at that address. The node's lower bounds are the parent's current tops, or zero at the root; the node is empty in a bucket when its current top equals that lower bound.

The parent move is popped before descent, and the child copies the resulting parent tops as both its initial tops and lower bounds. Descendants can therefore reuse the released slot while still-unsearched ancestor moves below the parent's current tops remain protected. Restoring the packed parent search-stack entry restores its remaining move state. No allocator, free list, per-move link, overflow bucket, or move-consumed mask exists.

Before a write that would exceed a thread region, the module suppresses both the RAM write and top increment, sets sticky overflow, captures bucket and thread, increments a saturating overflow counter, and reports a simulation error when overflow assertions are enabled. Correct search operation assumes overflow never occurs.

## Initialization, Flush, and Instrumentation

Move RAM contents are never cleared. Reset and New Game serialize history clearing; bucket storage is reclaimed by resetting node tops. Flush cancels active variable-latency command and pop state on Kill or New Game.

Optional counters record noisy and quiet moves, analyzed destinations, emitted candidates, history lookups, generation cycles, per-bucket writes, and per-bucket high-water tops. Overflow status and identification remain present when optional statistics are disabled.
