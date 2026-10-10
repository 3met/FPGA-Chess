# Transposition-Table Memory

`tt_external_load_store` owns the engine-clock cache, request metadata, response assembly, and replacement policy. `tt_memory_cdc_bridge` owns exactly five asynchronous FIFOs and the memory-clock scheduler. The external controller implements the burst protocol without chess-specific replacement logic.

## Indexing and Layout

The most significant Zobrist bit selects one of two cache banks and one of two interleaved sets of external entries. The remaining untagged hash bits are mixed and range-reduced within that set. Low key bits form the configurable position tag. The cache set derives from the external entry index. Each set has two independently tagged slots, each holding one TT way, its external way selector, and the external index bits not already identified by bank and set. An invalid bound identifies an empty slot.

Requests cross into the memory domain as logical entry indices, with a way selector for writes. The memory scheduler shares the physical address calculation across request classes. External addresses count memory words. For logical way width `L` and word width `W`, each way occupies `ceil(L/W)` words and a complete entry occupies three times that number. Entry `e`, way `w`, word `k` uses address `e * entry_words + w * way_words + k`. Only the high bits of each way's final word are padded; fields remain packed without individual alignment or extra padding between entries. The controller splits bursts at physical row boundaries.

The cache size parameter counts total index bits including the bank bit. Each bank reads both cache candidates synchronously and writes one selected slot independently. Cache records have no memory-word padding. Data and LRU read/write collisions forward the new values independently of inferred RAM behavior.

## Cache Arbitration

Incoming probe selection is registered before hashing and cache access. At most one probe and one store read issue each engine cycle. Probes have priority when both need the same bank. The search arbiter prefers a ready thread whose probe avoids the staged store's bank; otherwise it chooses its ordinary round-robin probe.

Probes compare both cache candidates against the external-entry identity and position tag without an additional pipeline stage. A miss records engine-local request metadata and queues the logical entry index. If either the request FIFO or metadata queue lacks space, the thread receives a miss immediately.

Stores first read the cache. A matching cache tag and position way feeds the shared replacement datapath. Otherwise the store records its metadata and queues a complete external group read. Full store queues drop publications. A complete store response compares all three ways using the same replacement datapath, after cache-hit stores.

Only a successful external probe's matching way and an accepted store's updated way are admitted. Admission reads use bank cycles left idle by engine probes and stores, preferring store admissions. Existing positions are updated; otherwise an empty slot is preferred before the least recently used slot. Cache-hit store publications take priority over admissions; store publications take priority over probe fills in the same bank. Preempted admissions retry unless a newer fill supersedes them. Fills are best-effort and may overwrite newer heuristic information.

One LRU bit per set resides in a separate synchronous RAM read alongside the cache data. A retiring probe/store hit or successful admission marks the accessed slot most recently used. Because only one read retires per bank per cycle, LRU needs one write port; cache-hit store publication does not require another touch.

## Clock-Domain Crossing

| FIFO | Direction | Payload |
| ---- | --------- | ------- |
| Probe read | Engine to memory | Logical entry index. |
| Probe response | Memory to engine | One external memory word. |
| Store read | Engine to memory | Logical entry index. |
| Store response | Memory to engine | One external memory word. |
| Way writeback | Engine to memory | Logical entry index, way selector, and one complete padded way. |

Probe and store metadata remain in separate ordered engine-clock queues. Probe responses reuse one way comparator as each complete way arrives and return the first hit immediately; a miss waits for all three ways. The memory bridge forwards captured words directly into the reserved response FIFO while the SDRAM burst continues, without assembling another full entry. Request metadata remains queued until the full response drains, preventing duplicate replies or misrouting after an early hit. Store replacement waits for the complete external group. A matching probe way can enter the cache while the remaining response words drain. Neither response FIFO contains routing bits or completion bits. A prematurely completed backend read pads missing words with zero; words already streamed cannot be withdrawn by a later completion error.

The memory scheduler considers eligible probe reads first, then store reads, then one-way writes. Before issuing a read it reserves enough response FIFO capacity for the entire three-way group using a conservative synchronized read pointer. Capacity eligibility is registered before request arbitration and accounts for the response word pushed on that same edge, preventing stale eligibility from overcommitting a FIFO. A blocked response class does not prevent eligible traffic in another class. One-way writes are dropped at enqueue when their FIFO is full.

A single backend transaction runs at a time, and its words stream in order to the selected response FIFO. The scheduler waits for terminal completion before starting another transaction. Read and completion handshakes remain inside the memory clock domain. Gray-pointer paths require bounded delay and skew in board constraints; reset releases independently in each clock domain.

## External-Memory Protocol

The vendor-neutral protocol has ready/valid request, write-word, read-word, and completion channels. Addresses and lengths are in external memory words. A read transfers a complete three-way group; a replacement write transfers one selected padded way. Burst-length width derives from the supported field widths. The controller buffers unpausable physical bursts, handles row-boundary splitting and refresh, and produces one terminal completion per accepted request.

Clock frequencies, SDRAM geometry/timing, PLLs/MMCMs, phases, pins, and initialization settings belong to target wrappers and configuration. Generic TT RTL contains no board clock assumptions.
