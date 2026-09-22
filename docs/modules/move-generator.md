# Move Generator (`move_generator`)

`move_generator` produces ordered pseudo-legal moves through independent noisy/direct and quiet lanes. Ordinary king safety, pins, discovered checks, and en passant discovered checks are validated after `board_update_pipeline` applies a candidate. Castling origin, transit, and destination safety are checked during generation because they cannot be inferred from the final board alone.

## RTL Organization

The top level coordinates noisy/direct and quiet generation lanes, move memory, and quiet history. Generation lanes produce ordered candidates while move memory owns per-thread storage, per-ply FIFO state, bucket sequencing, and destructive pops. Quiet-history updates run independently of generation.

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

Generation is destination-centric and visits central squares before moving outward. Each class lane selects relevant destination squares, captures the ray and knight context from a registered scan address, then derives an exact source mask from those registered tiles. Source expansion constructs moves from that mask without repeating geometry checks. The next destination address is prefetched during source preparation, allowing its context to replace the current context as the final source enters writeback; board lookup and source eligibility remain in separate timing stages without a second context bank. Empty or unproductive destinations are skipped without producing a move. Promotions are generated in queen, knight, rook, bishop order.

Noisy destinations include occupied enemy squares, valid en passant targets, and promotion destinations. Quiet destinations include ordinary empty squares and castling destinations. Castling additionally checks permissions, king and rook placement, empty paths, and attacks on the king's origin, transit, and destination squares.

Move memory scans buckets in descending priority. While generation can still add to the highest eligible bucket, an empty bucket makes the read wait for a move or generation completion before considering lower buckets. Writes continue without waiting for reads, including when the same bucket is being read. Each thread has independent storage and a pop channel, so threads can read concurrently and a wait affects only its thread. Flush and New Game cancel pending requests and responses.

## Ordering

Candidates are divided into eight global-priority buckets:

| Bucket | Meaning |
| ------ | ------- |
| 7 | Queen promotions and favorable captures of rooks or queens. |
| 6 | Other favorable captures and underpromotions. |
| 5 | Highest-history quiet moves. |
| 4 | High-history quiet moves. |
| 3 | Moderate-history quiet moves, including castling. |
| 2 | Remaining quiet moves. |
| 1 | Unfavorable captures of rooks or queens. |
| 0 | Other unfavorable captures. |

Capture classification uses a bounded visible static-exchange approximation. Quiet ordering uses one signed history RAM indexed by a wiring-only XOR-fold hash of `{thread, color, origin, destination}`; collisions are intentionally untagged. The engine profile configures the power-of-two entry count and signed entry width, with 8,192 eight-bit entries by default. Beta cutoffs update the successful quiet and a small number of earlier failed quiets with depth-scaled gravity updates whose limit and arithmetic widths derive from the entry width.

History lookups have unconditional priority over the update pipeline's read port. Incoming updates are best-effort: an update presented while the pipeline is occupied is dropped, an update read waits behind lookups, and a write colliding with a lookup is dropped so generation never stalls or observes ambiguous read-during-write data.

Move memory tracks each node's progress through good noisy, quiet, and bad noisy buckets. Noisy generation enables buckets 7–6. After they are exhausted, search may stop or generate quiet moves in buckets 5–2; exhausting quiet moves enables buckets 1–0. Search issues `pop(thread, ply)` without supplying bucket state, and each pop consumes the returned move even if later legality checks reject it.

Only the encoded `Move` is stored. Ordering within a bucket is deterministic FIFO, so center-first generation makes central moves available earlier and preserves that preference among otherwise equal moves without overriding bucket priority.

## Bucket Storage

Each thread has its own move RAM and pointer stack. Fixed unequal bucket partitions derive from the per-device `move_memory.entries_per_thread` and `move_memory.bucket_ratios_descending` settings. Defaults are 2,048 entries per thread and ratios 32/64/32/64/64/192/16/48 for buckets 7 through 0. Ratios must be positive, their sum must divide the memory size, and every resulting partition must fit its pointer type; invalid settings fail build validation and synthesis elaboration.

Each pointer-stack entry records the FIFO bounds and bucket progress for one ply. A child begins at its parent's write tails, preventing it from reading or overwriting unsearched ancestor moves. Restoring a parent restores its unread moves, while later siblings may reuse descendant storage.

A write beyond its bucket partition sets a sticky overflow error bit but is not blocked or redirected. Contents for that thread are not guaranteed after overflow. Reset and New Game clear the bit; no overflow location or count is tracked.

## Lifecycle and Instrumentation

Move RAM and pointer-stack contents need not be cleared because node initialization defines the live range. Reset and New Game clear quiet-history state; Kill and New Game cancel active generation and pop work.

Optional counters expose generation work, history lookups, bucket traffic, high-water marks, and overflow information without affecting search semantics.
