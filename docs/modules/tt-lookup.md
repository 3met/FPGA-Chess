# TT Lookup Pipeline (`tt_lookup`)

The TT lookup pipeline performs transposition-table lookup requests for search threads. TT lookup is latency-sensitive because a thread often cannot continue until the response returns.

## Request

Each request includes:

| Field | Meaning |
| ----- | ------- |
| `thread_id` | Search thread that issued the lookup. |
| `zobrist_key` | Full hash key for the position. |
| `depth` | Remaining search depth for replacement and cutoff decisions. |
| `alpha` | Current alpha bound, if the search controller wants the TT pipeline to precompute cutoff usability. |
| `beta` | Current beta bound, if the search controller wants the TT pipeline to precompute cutoff usability. |
| `ply` | Current root-relative search ply, used to restore stored mate scores into root-relative form. |
| Route metadata | State needed to route the response back to the correct thread state. In the base design, `thread_id` is sufficient because each thread has at most one in-flight TT lookup request. |

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

The RTL implementation is `tt_load_store` under `hardware/rtl/tt/`. It uses a portable synchronous-read simple-dual-port RAM template with Intel and Xilinx block-RAM inference hints and one logical TT entry per memory word. The default compact profile stores 96-bit entries, and the optional full-key profile stores 128-bit entries. The default table has `TT_INDEX_BITS = 10`, or 1024 entries, and the parameter is intended to scale up to 16 compact-index bits before an external-memory wrapper is added.

The implemented lookup interface uses `lookup_req_valid`, `lookup_req_ready`, and `lookup_resp_valid`. Lookup requests are accepted whenever `clear` is not active. A lookup response is produced for each accepted request, with `hit` deasserted on empty, invalid, or verification-key mismatch entries.

Lookups have priority over stores when memory bandwidth conflicts. The synchronous RAM read and registered request metadata produce a response during the cycle immediately after request acceptance. If a store is queued or ready to write and a lookup arrives, the lookup runs first and the store remains delayed. When a lookup interrupts the write phase of a store read-modify-write operation, the old store entry is retained in a small register so the replacement decision and possible write can resume after the lookup. This preserves lookup correctness for same-index conflicts by preventing a store write in the same cycle as a lookup.

The first implementation includes a `clear` input for `ucinewgame` and reset-style invalidation. A rising edge on `clear` starts one sequential table clear. While `clear_busy` is asserted, lookup and store request readiness are deasserted, and the table is filled with invalid entries.

The pipeline verifies a 48-bit high-hash verification key before reporting a hit. The low `TT_INDEX_BITS` of the Zobrist key index the table, so compact mode leaves any middle hash bits outside the selected index and verification fields unchecked.

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

The 128-bit full-key profile is enabled with `USE_FULL_KEY = 1` when external memory naturally moves 128-bit records or when debugging TT correctness:

| Bits | Field | Meaning |
| ---- | ----- | ------- |
| `63:0` | Verification key | Full 64-bit Zobrist hash. |
| `79:64` | Best move | Encoded `Move`. |
| `95:80` | Score | Stored `EvalScore`, side-to-move point-of-view. |
| `101:96` | Depth | Stored search depth. |
| `103:102` | Bound type | Invalid, exact, lower-bound, or upper-bound. |
| `111:104` | Age/generation | Replacement-policy generation. |
| `127:112` | Aux | Optional cached static eval, replacement metadata, node type, or reserved bits. |

Physical packing may differ if the external-memory interface has a different native width, but the logical fields should be preserved. Padding is driven by the memory-controller beat width and burst alignment, not by SDRAM versus DDR as abstract memory types. For example, dense 96-bit entries are compact but awkward on a 64-bit beat interface because some entries cross beat boundaries; a 128-bit beat interface may make padded 128-bit entries faster and simpler even though it stores fewer entries.

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
