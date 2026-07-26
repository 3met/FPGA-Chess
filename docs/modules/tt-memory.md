# Transposition-Table Memory

The TT memory subsystem implements the logical lookup and best-effort store contract in [transposition-table.md](transposition-table.md). Search is independent of the physical memory technology: a target may use inferred on-chip RAM or a cached external-memory backend without changing the search-controller interface.

## Backends

The on-chip backend stores one logical entry per indexed RAM word. It is suitable for simulation, portable synthesis, and targets without external memory.

The external backend stores compact entries through a vendor-neutral 16-bit burst protocol. It contains a direct-mapped on-chip cache indexed independently from the external table. Cache tags identify the complete external entry index, and a key match is still required before a lookup is reported as a hit.

Both backends preserve the same lookup result, mate-score normalization, generation handling, and replacement semantics.

## External-Memory Protocol

The protocol consists of four independent ready/valid channels:

| Channel | Direction | Contents |
| ------- | --------- | -------- |
| Request | Frontend to memory | Read/write flag, word address, and burst length. |
| Write data | Frontend to memory | 16-bit words and an end-of-burst marker. |
| Read data | Memory to frontend | 16-bit words and an end-of-burst marker. |
| Completion | Memory to frontend | One terminal status for every accepted request. |

At most one transaction is issued by the TT frontend at a time. A backend may apply backpressure before accepting a request or write word and the frontend may apply backpressure to returned read data and completion. Once a physical SDR write burst begins, any required buffering is the backend's responsibility.

Every request produces exactly one completion, including reads. Read data precedes its completion. A failed read produces a miss-equivalent lookup response and sets the persistent memory-error status; failed stores do not affect search correctness.

## Clock-Domain Crossing

When the search and memory controllers use different clocks, a bridge transfers commands, write words, read words, and completions through separate asynchronous FIFOs. Packet boundaries are carried with the data rather than reconstructed from clock timing.

The read-data FIFO holds at least one maximum-length physical burst because an SDR SDRAM device cannot pause after a read burst has begun. Backend readiness and persistent error status are synchronized into the request clock domain.

Each clock domain has its own reset. The subsystem does not report memory ready until the backend has completed initialization and the synchronized ready indication has reached the search domain.

## Cache and Arbitration

Lookups take priority over queued stores. Stores are buffered and consumed only when no lookup is waiting; a full store queue drops new publications while still accepting them from search.

On a cache miss, the frontend reads the existing external entry before responding to a lookup or deciding whether a store may replace it. Accepted replacements update the cache and external memory. The cache is therefore a write-through performance layer, not an independent source of TT state.

## Clearing

New Game advances the logical TT generation. Cached entries from older generations do not hit. When the finite generation counter wraps, the external validity metadata is cleared before requests resume. Reset also invalidates the on-chip cache before the frontend becomes available.
