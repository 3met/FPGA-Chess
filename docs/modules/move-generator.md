# Move Generator (`move_generator`)

`move_generator` produces ordered pseudo-legal moves through independent noisy/direct and quiet pipelines. Ordinary king safety, pins, discovered checks, and en passant discovered checks are validated after `board_update_pipeline` applies a candidate. Castling origin, transit, and destination safety are checked during generation because they cannot be inferred from the final board alone.

## Commands

The noisy/direct and quiet interfaces use independent ready/valid channels. Requests carry the board, thread and ply tags, current bucket state, and an optional move to suppress; responses return the routing tags and updated bucket state.

| Command | Behavior |
| ------- | -------- |
| `MOVE_GEN_VALIDATE_DIRECT` | Validate a supplied TT or root move without storing it. |
| `MOVE_GEN_GENERATE_NOISY` | Generate captures, en passant, and all promotions. |
| `MOVE_GEN_GENERATE_QUIET` | Generate ordinary non-captures and standard castling. |

Commands are variable latency. Completion is returned only after the final candidate has been classified and stored. The two class pipelines may process different threads concurrently, and bucket pops may overlap generation.

An attempted direct move is suppressed from later generation only after successful validation. Equality includes origin, destination, and promotion encoding so promotion choices remain distinct.

## Generation

Generation is destination-centric. Each class pipeline selects relevant destination squares, then builds the ray and knight context from the registered destination before emitting explicit candidates. Empty or unproductive destinations are skipped without producing a move. Promotions emit all four legal choices.

Noisy destinations include occupied enemy squares, valid en passant targets, and promotion destinations. Quiet destinations include ordinary empty squares and castling destinations. Castling additionally checks permissions, king and rook placement, empty paths, and attacks on the king's origin, transit, and destination squares.

The pop frontend selects the highest non-empty eligible bucket and returns one tagged move. Search may forward the result directly to board update. Popping consumes the candidate even if later king-safety validation rejects it.

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

Capture classification uses a bounded visible static-exchange approximation. Quiet ordering uses a signed history table indexed by color, origin, and destination. Beta cutoffs update the successful quiet and a small number of earlier failed quiets with depth-scaled gravity updates. History maintenance is best-effort and never blocks search.

Only the encoded `Move` is stored. Ordering within a bucket is deterministic LIFO; fixed destination selection gives a reproducible preference among otherwise equal moves but never overrides bucket priority.

## Bucket Storage

Each bucket is a synchronous simple-dual-port RAM divided into fixed per-thread regions. The noisy pipeline owns the capture/promotion buckets and the quiet pipeline owns the quiet buckets, avoiding write-port contention between the generators.

Every search node stores the eight current bucket tops. The parent's tops form the child's lower bounds, so descendants may reuse slots released by popped parent moves without overwriting unsearched ancestor moves. Restoring the parent stack record restores its remaining candidates; no allocator or per-move links are required.

A write that would exceed a thread's region is suppressed and sets sticky overflow diagnostics. Correct search assumes the configured region is large enough for every reachable line.

## Lifecycle and Instrumentation

Move RAM contents need not be cleared because node tops define live storage. Reset and New Game clear quiet-history state; Kill and New Game cancel active generation and pop work.

Optional counters expose generation work, history lookups, bucket traffic, high-water marks, and overflow information without affecting search semantics.
