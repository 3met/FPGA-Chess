# Move Generator (`move_generator`)

`move_generator` produces ordered pseudo-legal moves through independent noisy/direct and quiet lanes. Ordinary king safety, pins, discovered checks, and en passant discovered checks are validated after `board_update_pipeline` applies a candidate. Castling origin, transit, and destination safety are checked during generation because they cannot be inferred from the final board alone.

## RTL Organization

The top level coordinates noisy/direct and quiet generation lanes, move memory, and quiet history. Generation lanes produce ordered candidates while move memory owns per-thread storage, per-ply FIFO state, bucket sequencing, and destructive pops. While idle, each lane preloads its destination mask and thread tag independently of command validity; accepted commands retain the same launch cycle. Quiet-history updates run independently of generation.

## Commands

The noisy/direct and quiet interfaces use independent ready/valid channels. Requests carry the board, thread and ply tags, and an optional move to suppress. Responses return routing tags and direct-validation results; FIFO state never crosses the module boundary.

| Command | Behavior |
| ------- | -------- |
| `MOVE_GEN_VALIDATE_DIRECT` | Validate a supplied TT or root move without storing it. |
| `MOVE_GEN_GENERATE_NOISY` | Generate captures, en passant, and all promotions. |
| `MOVE_GEN_GENERATE_QUIET` | Generate ordinary non-captures and standard castling. |

Commands are variable latency. Completion is returned only after the final candidate has been classified and stored. The two class lanes may process different threads concurrently, and bucket pops may overlap generation. Generation commands for the same thread are serialized before acceptance so its memory has at most one writer; accepted generation never stalls for storage or reads.

An attempted direct move is suppressed from later generation only after successful validation. Equality includes origin, destination, and promotion encoding so promotion choices remain distinct.

## Generation

Generation visits central destinations first. Noisy and quiet lanes produce candidates independently; promotions are generated in queen, knight, rook, bishop order.

Noisy destinations include occupied enemy squares, valid en passant targets, and promotion destinations. Quiet destinations include ordinary empty squares and castling destinations. Castling additionally checks permissions, king and rook placement, empty paths, and attacks on the king's origin, transit, and destination squares.

Direct-move path checks share a decoded square-occupancy map, avoiding full-tile board-read multiplexers for slider clearance and pawn double pushes within the existing validation cycle.

Move memory scans buckets in descending priority. While generation can still add to the highest eligible bucket, an empty bucket makes the read wait for a move or generation completion before considering lower buckets. Writes continue without waiting for reads, including when the same bucket is being read. Each thread has independent storage and a pop channel, so threads can read concurrently and a wait affects only its thread. Flush and New Game cancel pending requests and responses.

## Ordering

Candidates are divided into eight global-priority buckets:

| Bucket | Meaning |
| ------ | ------- |
| 7 | Queen promotions and favorable captures of rooks or queens. |
| 6 | Other favorable captures and underpromotions. |
| 5 | Highest-score quiet moves. |
| 4 | High-score quiet moves. |
| 3 | Medium-score quiet moves, including untouched moves. |
| 2 | Unfavorable captures of rooks or queens. |
| 1 | Other unfavorable captures. |
| 0 | Low-score quiet moves. |

Capture classification uses a bounded static-exchange approximation. Quiet ordering adds signed history and the castling bonus in a wide signed score before classification. Three strictly increasing configured thresholds divide the quiet buckets; thresholds and reset priors may be negative. The low-score quiet bucket follows both unfavorable-capture groups. The history RAM stores signed entries initialized to its configured prior and saturates to its full signed range. The reset prior is independent of the bucket thresholds; an untouched move scores that prior plus any castling bonus. Depth-scaled gravity updates reward quiet beta-cutoff moves and penalize up to three earlier quiets that failed to cut off. Storage is configured by the engine profile and update policy by the search profile.

All history updates use `h′ = clamp(h + B − trunc(h × |B| / D), −D, D − 1)`, where `D = 2^(entry_bits − 1)`. The reward is bounded by remaining depth and the configured maximum; a failed quiet receives that reward divided by the malus divisor with a negative sign. Signed division truncates toward zero. Defaults are initialization priors, while gravity is centered on zero; defaults and maximum rewards must fit each signed entry width.


History lookups take priority over best-effort updates, so history maintenance does not stall generation. Gravity multiplication is registered with the captured RAM value, separating it from writeback saturation within the existing update latency. Write addresses are selected from the stable update context independently of lookup collision suppression; conflicts disable the write without gating its address or data.

Move memory tracks each node's progress through good noisy, regular quiet, bad noisy, and low quiet buckets. Noisy generation enables buckets 7–6. After they are exhausted, search may stop or generate quiet moves in buckets 5–3 and 0; exhausting regular quiets enables bad noisy buckets 2–1, followed by low quiet bucket 0. Search issues `pop(thread, ply)` without supplying bucket state, and each pop consumes the returned move even if later legality checks reject it.

Only the encoded `Move` is stored. Ordering within a bucket is deterministic FIFO, so center-first generation makes central moves available earlier and preserves that preference among otherwise equal moves without overriding bucket priority.

## Bucket Storage

Each thread has separate move storage and a per-ply pointer stack. Engine profiles configure storage capacity and bucket partitions; invalid partitions are rejected during build validation and elaboration.

Each pointer-stack entry records the FIFO bounds and bucket progress for one ply. A child begins at its parent's write tails, preventing it from reading or overwriting unsearched ancestor moves. Restoring a parent restores its unread moves, while later siblings may reuse descendant storage.

FIFO heads and tails increment locally within each bucket, with bucket selection enabling the update after the increment. This preserves same-cycle write forwarding and pointer-stack updates. Forwarding compares each bucket’s cached head and tail before selecting its one-bit empty flag, avoiding a selected-pointer mux ahead of the comparison. Registered generator ownership compares the candidate cache contexts before selecting the match bit, keeping FIFO service decisions off the ply-comparison path.

A write beyond its bucket partition sets a sticky overflow error bit but is not blocked or redirected. Contents for that thread are not guaranteed after overflow. Reset and New Game clear the bit; no overflow location or count is tracked.

## Lifecycle and Instrumentation

Move RAM and pointer-stack contents need not be cleared because node initialization defines the live range. Reset and New Game restore the quiet-history default; Kill and New Game cancel active generation and pop work.

Optional counters expose generation work, history lookups, bucket traffic, high-water marks, and overflow information without affecting search semantics.
