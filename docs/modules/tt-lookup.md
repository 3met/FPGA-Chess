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
| `thread_id` | Routing metadata identifying the requesting thread; the controller uses it to capture the result in that thread's pending slot. |
| `valid` | Response is valid. |
| `hit` | TT key matched the requested Zobrist key. |
| `score` | Stored score, side-to-move point-of-view. |
| `bound_type` | Exact, lower-bound, upper-bound, or invalid. |
| `depth` | Stored search depth. |
| `best_move` | Best move or move-ordering hint. |

## Behavior

The portable fallback implementation is `tt_load_store` under `hardware/rtl/tt/` and uses inferred block RAM. The DE1 build selects `tt_external_load_store`, which stores 5,592,405 compact entries in the FPGA-side 64 MiB SDRAM. Each 94-bit logical entry occupies six aligned 16-bit words with two padding bits. A 1024-line direct-mapped BRAM cache stores the full external index tag; generation matching uses the age field already present in the cached 96-bit record rather than a duplicate metadata RAM. Misses and write-through stores use the explicit burst-memory protocol.

The implemented lookup interface uses `lookup_req_valid`, `lookup_req_ready`, and `lookup_resp_valid`. Lookup requests are accepted whenever `clear` is not active. A lookup response is produced for each accepted request, with `hit` deasserted on empty, invalid, or verification-key mismatch entries.

The load/store frontend also emits one-cycle `cache_access`, `cache_hit`, and `cache_access_is_store` instrumentation signals. The search statistics use only lookup probes for the reported cache hit rate; store probes are identified separately because stores use the same cache but do not measure lookup effectiveness. The inferred-RAM backend ties the signals low because it has no separate frontend cache.

Lookups have priority over stores when memory bandwidth conflicts. An external lookup or store remains outstanding until its tagged completion returns, and all search contexts share cache and SDRAM entries. A store applies the depth/generation replacement policy from the cached entry when its external index is resident, otherwise it reads the old SDRAM entry, and writes through the cache and SDRAM when replacement is selected.

The `clear` input implements `ucinewgame`. The BRAM fallback sequentially invalidates its entries. The external frontend increments the stored generation immediately; power-up and generation wrap perform a low-area serial sweep of the external validity/metadata word, with requests held off until the sweep completes.

The pipeline verifies a 48-bit high-hash verification key before reporting a hit. The low `TT_INDEX_BITS` of the Zobrist key index the table, so compact mode leaves any middle hash bits outside the selected index and verification fields unchecked.

## Logical Entry Format

TT entry storage should be parameterized. The live Zobrist key should remain 64 bits, but the TT entry does not always need to store all 64 bits because table index bits already come from the key.

The recommended default is a compact 94-bit entry:

| Bits | Field | Meaning |
| ---- | ----- | ------- |
| `47:0` | Verification key | `TT_VERIFY_BITS = 48` high hash bits for hit verification. |
| `61:48` | Best move | Encoded `Move`. |
| `77:62` | Score | Stored `EvalScore`, side-to-move point-of-view. |
| `83:78` | Depth | Stored search depth. |
| `85:84` | Bound type | Invalid, exact, lower-bound, or upper-bound. |
| `93:86` | Age/generation | Replacement-policy generation. |

The 126-bit full-key profile is enabled with `USE_FULL_KEY = 1` when external memory naturally moves 128-bit records or when debugging TT correctness:

| Bits | Field | Meaning |
| ---- | ----- | ------- |
| `63:0` | Zobrist key | Full 64-bit Zobrist hash. |
| `77:64` | Best move | Encoded `Move`. |
| `93:78` | Score | Stored `EvalScore`, side-to-move point-of-view. |
| `99:94` | Depth | Stored search depth. |
| `101:100` | Bound type | Invalid, exact, lower-bound, or upper-bound. |
| `109:102` | Age/generation | Replacement-policy generation. |
| `125:110` | Aux | Cached static eval, replacement metadata, node type, or reserved bits. |

Physical packing may differ if the external-memory interface has a different native width, but the logical fields should be preserved. Padding is driven by the memory-controller beat width and burst alignment, not by SDRAM versus DDR as abstract memory types. For example, dense 96-bit entries are compact but awkward on a 64-bit beat interface because some entries cross beat boundaries; a 128-bit beat interface may make padded 128-bit entries faster and simpler even though it stores fewer entries.

## Replacement Policy

The implementation uses a single-entry-per-index depth/age replacement policy. This keeps lookup bandwidth to one entry per TT access and avoids requiring bucket reads.

On store, replace the existing entry when any of these conditions is true:

| Condition | Reason |
| --------- | ------ |
| Existing entry is invalid or fails key verification for the indexed slot | Empty or unrelated entry. |
| Existing entry age differs from the current search generation and the new entry depth is at least `old_depth - 4` | Prefer fresh results unless the old result is much deeper. |
| New entry depth is greater than or equal to existing entry depth | Preserve deeper search information. |
| New entry is an exact bound and the existing entry is not exact at the same depth | Prefer exact scores over bounds. |

The generation counter advances on `ucinewgame`. Age comparison uses equality versus the current generation.

## Open Design Items

- Measurement-driven cache sizing and memory arbitration tuning.
- Whether to add a future 2-way bucket profile after measuring TT bandwidth and collision behavior.
