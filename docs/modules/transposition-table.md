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

A matching entry may provide a move-ordering hint even when its depth or bound is insufficient for a cutoff. At the root, every matching entry is used only for move ordering: a new search compares legal root moves and never publishes a cached score/move pair directly. The search controller validates ordering moves through the normal board-update legality path.

Repetition history is not part of the Zobrist key, so the controller conservatively validates cutoffs that may have become history-dependent. A rejected score may still provide a legal move-ordering hint. The policy is described in [search-design.md](../architecture/search-design.md).

Lookup requests take priority over queued stores because a requesting thread cannot proceed until its response arrives.

## Store

A store request contains the full key, completed search depth, score, bound type, best move, generation, and root-relative ply. Stores are best-effort: search correctness never depends on a publication reaching memory.

The TT frontend accepts stores into a parameterized FIFO. A publication is dropped if that FIFO is full, allowing the search thread to continue without memory backpressure. Queued stores drain only when they do not delay a lookup. A dequeued external-table store is staged with its reduced index before probing the cache, keeping the FIFO BRAM, range reducer, and cache BRAM out of one timing path without changing blocking lookup latency.

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

The live Zobrist key remains 64 bits. `TT_TAG_BITS` selects the low key bits stored as the compact entry tag. Every remaining high key bit participates in a shared XOR-fold and xorshift index hash; power-of-two tables fold that hash into their address width, while non-power-of-two tables use multiply-high range reduction. Configurations with fewer index-hash entropy bits than address bits are invalid, and configurations with less than eight bits of entropy margin emit a simulation warning.

The compact entry fields are:

| Width | Field |
| ----- | ----- |
| `TT_TAG_BITS` | Low Zobrist-key tag. |
| 14 | Encoded best move. |
| 16 | Side-to-move score. |
| `ceil(log2(search stack depth))` | Search depth; six bits in the DE1-SoC profile. |
| 2 | Bound type. |
| 5 | Age/generation. |

The DE1-SoC profile uses a 32-bit tag, producing a 75-bit logical entry padded to five 16-bit words and fitting 6,710,886 entries in 64 MiB. Changing `TT_TAG_BITS` changes the compact width, physical alignment, burst length, and entry count together.

The on-chip full-key format stores the complete 64-bit key, best move, score, depth, bound, age, and auxiliary bits.

## Hit Verification

An entry hits only when:

- its bound type is not invalid,
- its generation is current,
- and its stored full key or compact low-bit tag matches the request.

Compact verification can admit a false hit if two distinct keys share both the hashed table index and stored tag. Full-key storage eliminates that possibility.

## Replacement

The TT stores one logical entry at each index. A store replaces the indexed entry when any of these conditions holds:

| Condition | Reason |
| --------- | ------ |
| Entry is invalid or belongs to another key | The slot contains no result for this position. |
| Entry belongs to an older generation and the new depth is at least `old_depth - 4` | Prefer fresh search information without discarding a substantially deeper result. |
| New depth exceeds the stored depth | Preserve the deepest available result. |
| Depths are equal and the stored result is not exact | Allow bounds to refresh peers and exact scores to replace bounds. |
| Depths are equal and both results are exact | Allow the incoming exact score and move to refresh the entry. |

Skipping a store is not an error. Generation comparison uses equality with the current generation; New Game advances that generation.

## Clearing

New Game makes older entries unavailable by advancing the five-bit generation and clears queued stores. On-chip storage may invalidate entries sequentially. External storage performs a physical validity sweep only when required at reset or when New Game arrives at generation 31, then restarts at generation 1. Requests remain unavailable while an invalidation pass is active.
