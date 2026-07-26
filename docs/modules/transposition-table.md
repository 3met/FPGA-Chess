# Transposition Table

The transposition table shares search results between threads, provides cutoffs, and supplies move-ordering hints. Lookup semantics and replacement policy are independent of the physical storage backend described in [tt-memory.md](tt-memory.md).

## Lookup

A lookup request contains:

| Field | Meaning |
| ----- | ------- |
| `thread_id` | Routing identity of the requesting search thread. |
| `zobrist_key` | Full 64-bit position key. |
| `depth` | Remaining search depth required for a score cutoff. |
| `alpha`, `beta` | Current search window. |
| `ply` | Root-relative ply used to restore mate distance. |

Every accepted lookup produces one tagged response. A response reports whether the indexed entry is valid for the requested key and generation, together with its score, bound type, searched depth, and best move.

A matching entry may provide a move-ordering hint even when its depth or bound is insufficient for a cutoff. The search controller validates that move through the normal board-update legality path.

Lookup requests take priority over queued stores because a requesting thread cannot proceed until its response arrives.

## Store

A store request contains the full key, completed search depth, score, bound type, best move, generation, and root-relative ply. Stores are best-effort: search correctness never depends on a publication reaching memory.

The TT frontend accepts stores into a parameterized FIFO. A publication is dropped if that FIFO is full, allowing the search thread to continue without memory backpressure. Queued stores drain only when they do not delay a lookup.

## Score and Bound Semantics

TT scores use the search controller's side-to-move point of view. Bound types are:

| Bound | Meaning |
| ----- | ------- |
| Invalid | Entry cannot be used. |
| Exact | Score equals the searched node value. |
| Lower | Score is at least the stored value. |
| Upper | Score is at most the stored value. |

Mate scores are normalized when stored so they are relative to the stored node rather than the original root. Lookup restores them relative to the current root ply. This preserves mate-distance ordering when the same position is reached at another ply.

## Logical Entry Formats

The live Zobrist key remains 64 bits. A storage profile may omit index bits from the stored verification key because those bits already select the entry.

The compact logical entry is 94 bits:

| Width | Field |
| ----- | ----- |
| 48 | High-hash verification key. |
| 14 | Encoded best move. |
| 16 | Side-to-move score. |
| 6 | Search depth. |
| 2 | Bound type. |
| 8 | Age/generation. |

The external 16-bit backend pads the compact entry to 96 physical bits. Other backends may choose alignment appropriate to their native memory width without changing the logical fields.

A 126-bit full-key profile stores the complete 64-bit key, best move, score, depth, bound, age, and 16 auxiliary bits. It is used when full-key verification or native memory alignment warrants the additional storage.

## Hit Verification

An entry hits only when:

- its bound type is not invalid,
- its generation is current,
- and its stored full or compact verification key matches the request.

Compact verification can admit a false hit if two distinct keys share both the table index and stored verification bits. The full-key profile eliminates that possibility.

## Replacement

The TT stores one logical entry at each index. A store replaces the indexed entry when any of these conditions holds:

| Condition | Reason |
| --------- | ------ |
| Entry is invalid or belongs to another key | The slot contains no result for this position. |
| Entry belongs to an older generation and the new depth is at least `old_depth - 4` | Prefer fresh search information without discarding a substantially deeper result. |
| New depth is at least the stored depth | Preserve the deepest available result. |
| Equal-depth new result is exact and the stored result is not | Prefer an exact score over a bound. |

Skipping a store is not an error. Generation comparison uses equality with the current generation; New Game advances that generation.

## Clearing

New Game makes older entries unavailable by advancing the generation and clears queued stores. On-chip storage may invalidate entries sequentially. External storage performs a physical validity sweep only when required at reset or generation wrap. Requests remain unavailable while an invalidation pass is active.
