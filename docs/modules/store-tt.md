# Store TT Pipeline (`store_tt`)

Status: planned required final RTL spec.

The store TT pipeline writes completed search results into the shared transposition table. Stores are less latency-sensitive than loads and may be buffered or stalled when memory bandwidth is needed for lookup requests.

## Request

Each store request includes:

| Field | Meaning |
| ----- | ------- |
| `thread_id` | Search thread publishing the result. |
| `board_hash` | Full hash key for the position. |
| `depth` | Completed search depth for this entry. |
| `score` | Stored score, side-to-move point-of-view. |
| `bound_type` | Exact, lower-bound, or upper-bound. |
| `best_move` | Best move found or best ordering hint. |
| `replacement_metadata` | Age/generation, node type, or other replacement-policy data. |

## Behavior

Stores update the primary external-memory TT. A BRAM cache should also be updated or invalidated when the selected cache design requires it.

The store pipeline must not block latency-sensitive TT loads unless required by a memory hazard that cannot be safely bypassed. Under sustained memory pressure, stores may be dropped only if the replacement policy explicitly allows that behavior.

Scores stored in the TT use the search controller's side-to-move point-of-view convention. Mate scores must be adjusted consistently on store/load so mate distance remains correct.

## Logical Entry Format

The store pipeline writes the parameterized logical entry described in [load-tt.md](load-tt.md). The recommended default is the compact 96-bit entry with a 48-bit verification key. A 128-bit full-key profile is valid when the external-memory interface makes that alignment preferable.

## Replacement Policy

The store pipeline should apply the single-entry depth/age replacement policy defined in [load-tt.md](load-tt.md). A store may be skipped when the existing entry is current-generation, deeper, and at least as useful as the new bound. Skipped stores are not errors.

## Open Design Items

- Store buffering depth.
- Store stall versus drop behavior under sustained memory pressure.
- External-memory physical packing for 96-bit entries and any target-specific aligned entry profile.
- Whether to add a future 2-way bucket profile after measuring TT bandwidth and collision behavior.
