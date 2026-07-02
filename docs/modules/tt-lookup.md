# TT Lookup Pipeline (`tt_lookup`)

Status: planned required final RTL spec.

The TT lookup pipeline performs transposition-table lookup requests for search threads. TT lookup is latency-sensitive because a thread often cannot continue until the response is routed back.

## Request

Each request includes:

| Field | Meaning |
| ----- | ------- |
| `thread_id` | Search thread that issued the lookup. |
| `zobrist_key` | Full hash key for the position. |
| `depth` | Remaining search depth for replacement and cutoff decisions. |
| `alpha` | Current alpha bound, if the search controller wants the TT pipeline to precompute cutoff usability. |
| `beta` | Current beta bound, if the search controller wants the TT pipeline to precompute cutoff usability. |
| Route metadata | Any state needed to route the response back to the correct thread state. In the base design, `thread_id` is sufficient because each thread has at most one in-flight TT lookup request. |

## Response

Each lookup returns a response to the requesting thread.

| Field | Meaning |
| ----- | ------- |
| `thread_id` | Requesting thread. |
| `valid` | Response is valid. |
| `hit` | TT key matched the requested Zobrist key. |
| `score` | Stored score, side-to-move point-of-view. |
| `bound_type` | Exact, lower-bound, upper-bound, or invalid. |
| `depth` | Stored search depth. |
| `best_move` | Best move or move-ordering hint. |
| `replacement_metadata` | Age/generation or other metadata needed by store policy. |

## Behavior

The primary TT storage is external memory behind a vendor-neutral wrapper. A BRAM cache is optional but recommended when the target FPGA has enough block memory to reduce external-memory pressure.

Lookups have priority over stores when external memory bandwidth conflicts. If stores and lookups target the same cache line or external-memory bank, lookup correctness must be preserved even when a store is delayed.

The pipeline must verify hash-key equality before reporting a hit. Partial-key schemes are allowed only if the collision risk is accepted and documented with the chosen TT format.

## Logical Entry Format

TT entry storage should be parameterized. The live Zobrist key should remain 64 bits, but the TT entry does not always need to store all 64 bits because table index bits already come from the key.

The recommended default is a compact 96-bit entry:

| Bits | Field | Meaning |
| ---- | ----- | ------- |
| `47:0` | Verification key | `TT_VERIFY_BITS = 48` high hash bits for hit verification. |
| `63:48` | Best move | Encoded `Move`, with reserved bits available for future flags. |
| `79:64` | Score | Stored `EvalScore`, side-to-move point-of-view. |
| `85:80` | Depth | Stored search depth. |
| `87:86` | Bound type | Invalid, exact, lower-bound, or upper-bound. |
| `95:88` | Age/generation | Replacement-policy generation. |

A 128-bit full-key profile is also valid when external memory naturally moves 128-bit records or when debugging TT correctness:

| Bits | Field | Meaning |
| ---- | ----- | ------- |
| `63:0` | Verification key | Full 64-bit Zobrist hash. |
| `79:64` | Best move | Encoded `Move`. |
| `95:80` | Score | Stored `EvalScore`, side-to-move point-of-view. |
| `101:96` | Depth | Stored search depth. |
| `103:102` | Bound type | Invalid, exact, lower-bound, or upper-bound. |
| `111:104` | Age/generation | Replacement-policy generation. |
| `127:112` | Aux | Optional cached static eval, replacement metadata, node type, or reserved bits. |

Physical packing may differ if the external-memory interface has a different native width, but the logical fields should be preserved. Padding is driven by the memory-controller beat width and burst alignment, not by SDRAM versus DDR as abstract memory types. For example, dense 96-bit entries are compact but awkward on a 64-bit beat interface because some entries cross beat boundaries; a 128-bit beat interface may make a padded 128-bit entry faster and simpler even though it stores fewer entries.

## Replacement Policy

The first implementation should use a single-entry-per-index depth/age replacement policy. This keeps lookup bandwidth to one entry per TT access and avoids requiring bucket reads before the memory shape is settled.

On store, replace the existing entry when any of these conditions is true:

| Condition | Reason |
| --------- | ------ |
| Existing entry is invalid or fails key verification for the indexed slot | Empty or unrelated entry. |
| Existing entry age differs from the current search generation and the new entry depth is at least `old_depth - 4` | Prefer fresh results unless the old result is much deeper. |
| New entry depth is greater than or equal to existing entry depth | Preserve deeper search information. |
| New entry is an exact bound and the existing entry is not exact at the same depth | Prefer exact scores over bounds. |

The generation counter should advance on `ucinewgame` and may also advance once per root search if wraparound behavior is acceptable. Age comparison only needs equality versus current generation for the first implementation.

## Open Design Items

- External memory banking and arbitration.
- BRAM cache structure.
- External-memory physical packing for 96-bit entries and any target-specific aligned entry profile.
- Whether to add a future 2-way bucket profile after measuring TT bandwidth and collision behavior.
