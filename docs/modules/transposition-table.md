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

On a miss, `hit` is false and the bound, depth, and best move fields are unspecified. Consumers use those fields only on a hit.

A matching entry may provide a move-ordering hint even when its depth or bound is insufficient for a cutoff. At the root, every matching entry is used only for move ordering: a new search compares legal root moves and never publishes a cached score/move pair directly. The search controller validates ordering moves through the normal board-update legality path.

Repetition history is not part of the Zobrist key. The controller rejects score cutoffs at positions that already occurred in the current reversible history, and selectively validates other history-sensitive cutoffs. A rejected score may still provide a legal move-ordering hint. The policy is described in [search-design.md](../architecture/search-design.md).

Lookup requests take priority over queued stores because a requesting thread cannot proceed until its response arrives.

## Store

A store request contains the full key, completed search depth, score, bound type, best move, generation, and root-relative ply. Stores are best-effort: search correctness never depends on a publication reaching memory.

Stores are queued and drain when they do not delay lookups. A full queue drops new publications without blocking search.

## Score and Bound Semantics

TT scores use the search controller's side-to-move point of view. Bound types are:

| Bound | Meaning |
| ----- | ------- |
| Invalid | Entry cannot be used. |
| Exact | Score equals the searched node value. |
| Lower | Score is at least the stored value. |
| Upper | Score is at most the stored value. |

Mate scores are normalized when stored so they are relative to the stored node rather than the original root. Lookup restores them relative to the current root ply. This preserves mate-distance ordering when the same position is reached at another ply.

## Entry Storage

Entries contain a position key or compact tag, best move, score, searched depth, bound, and generation. On-chip storage retains the full key; external storage uses a configurable compact tag and hashes the remaining key bits into the table index. Capacity and physical alignment derive from the selected storage profile.

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
| Entry is invalid, belongs to another key, or is unavailable after New Game | The slot contains no usable result for this position. |
| A usable inferred-RAM entry has an older age and falls within the configured depth tolerance | Prefer fresh search information without discarding a substantially deeper result. |
| New depth exceeds the stored depth | Preserve the deepest available result. |
| Depths are equal and the stored result is not exact | Allow bounds to refresh peers and exact scores to replace bounds. |
| Depths are equal and both results are exact | Allow the incoming exact score and move to refresh the entry. |

Skipping a store is not an error. Generation comparison uses equality with the current generation; New Game advances that generation.

## Clearing

New Game advances the generation and discards queued stores. Reset or generation wrap may require a physical invalidation pass; requests remain unavailable until it finishes.
