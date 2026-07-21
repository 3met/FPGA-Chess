# TT Store Pipeline (`tt_store`)

The TT store pipeline writes completed search results into the shared transposition table. Stores are less latency-sensitive than lookups and may be buffered or stalled when lookups need memory bandwidth.

## Request

Each store request includes:

| Field | Meaning |
| ----- | ------- |
| `thread_id` | Search thread publishing the result. |
| `zobrist_key` | Full hash key for the position. |
| `depth` | Completed search depth for this entry. |
| `score` | Stored score, side-to-move point-of-view. |
| `bound_type` | Exact, lower-bound, or upper-bound. |
| `best_move` | Best move found or best ordering hint. |
| `replacement_metadata` | Age/generation, node type, or other replacement-policy data. |
| `ply` | Current root-relative search ply, used to normalize mate scores before storage. |

## Behavior

The RTL implementation is the shared `tt_load_store` module under `hardware/rtl/tt/`. Stores update a portable synchronous-read simple-dual-port RAM backend with one logical entry per word. The RAM template carries Intel and Xilinx block-RAM inference hints. The default compact profile stores 94-bit entries, and `USE_FULL_KEY = 1` selects the 126-bit full-key profile. The external-memory wrapper preserves the same logical request, response, and compact entry format.

Stores use `store_req_valid` and `store_req_ready`. The FIFO is a portable synchronous-read block-RAM template with a parameterized depth of 256 entries by default, independently of the search-thread count. TT publication is best-effort: `store_req_ready` remains asserted while the frontend is operational, and an incoming store is dropped when the FIFO is full. Search correctness never depends on a store reaching memory.

Queued stores drain only during lookup-free cycles. The store path reads the old entry, applies replacement policy, and writes the new compact entry only if replacement is allowed. If a lookup arrives while a store is ready to write, the lookup runs first and the store write is delayed. Backend completions are not part of the search-thread control path; asynchronous memory failures use the global TT memory-error status.

The `clear` input starts one sequential invalidation pass on its rising edge and clears queued stores. Request readiness remains deasserted while `clear_busy` is asserted.

Scores stored in the TT use the search controller's side-to-move point-of-view convention. Mate scores must be adjusted consistently on store/lookup so mate distance remains correct.

## Logical Entry Format

The store pipeline writes the parameterized logical entry described in [tt-lookup.md](tt-lookup.md). The recommended default is the compact 94-bit entry with a 48-bit verification key. The implemented 126-bit full-key profile is valid when the external-memory interface makes that alignment preferable.

## Replacement Policy

The store pipeline should apply the single-entry depth/age replacement policy defined in [tt-lookup.md](tt-lookup.md). A store may be skipped when the existing entry is current-generation, deeper, and at least as useful as the new bound. Skipped stores are not errors.

## Open Design Item

- Whether to add a future 2-way bucket profile after measuring TT bandwidth and collision behavior.
