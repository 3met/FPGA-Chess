# Store TT Pipeline

The store TT pipeline writes completed search results into the shared transposition table.

## Behavior

Each store request includes at least `thread_id`, board hash, depth, score, bound type, best move, and replacement metadata as defined by the TT entry format.

Stores are less latency-sensitive than loads. The store pipeline stalls when external memory bandwidth is needed by load requests.

The primary TT storage is external SDRAM/DDR. The BRAM cache is updated on store when the cache design requires it.

## Design Parameters

- Store buffering depth.
- Store stall behavior under sustained memory pressure.
- TT entry format.
- Replacement policy.
