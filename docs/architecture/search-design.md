# Search Design

## Search Model

Each hardware search thread runs a simple iterative-deepening alpha/beta search. Threads cooperate through Lazy SMP using only the shared transposition table.

The number of threads is parameterized at build time. The expected design range is roughly 15-30 threads, but the exact value depends on FPGA resources and pipeline/memory bandwidth.

## Thread State

Each thread owns its search stack, alpha/beta values, depth counters, node counters, current board state, move history stack records, and pipeline wait state.

Search uses stack records for undo rather than storing a full board state at every ply. A push move sends the current board state and move into the board update pipeline, and a reverse move uses the stored move record to recover the previous state.

For the base design, a thread may have at most one in-flight request per major pipeline. This rule lets pipeline results be routed by `thread_id` alone. If future designs allow multiple in-flight requests from the same thread to the same pipeline, requests must add a generation counter or request ID so stale results can be discarded safely.

## Pipeline Scheduling

The search controller feeds five shared pipelines: board update, move generation, static evaluation, load TT, and store TT.

Board update, move generation, and static evaluation are high-area pipelines and should be kept busy by scheduling work across many threads. These pipelines should target one accepted request per cycle when work is available. TT pipelines are constrained by external memory bandwidth.

Pipeline arbitration prioritizes TT loads over TT stores, because loads block search progress while stores can usually be delayed.

## Move Generation and Legality

The move generator accepts a legal input position and emits one ordered candidate move per dispatch. The generator also reports whether the emitted candidate is legal. If the candidate is illegal, it is still considered dispatched/consumed for that node, and the thread should send the position through move generation again to obtain the next candidate.

Illegal-move filtering is intended to cover cases such as pinned pieces, king moves into attacked squares, and check/double-check restrictions. The board update pipeline should not be responsible for selecting a replacement move after an illegal move is rejected.

## Transposition Table Use

The TT is the only shared Lazy SMP structure between threads. TT lookup can provide cutoffs, scores, and move-ordering hints. TT stores publish completed node results for use by other threads.

The primary TT is stored in external SDRAM/DDR, with a BRAM cache when the target FPGA has enough block memory to make caching useful.

## Design Parameters

- Exact `THREAD_COUNT` default.
- Pipeline arbitration policy across ready threads.
- TT load/store memory banking, cache structure, and replacement policy.
- Whether future designs allow multiple in-flight requests per thread per pipeline.
