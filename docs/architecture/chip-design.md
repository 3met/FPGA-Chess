# Chip Design

The chip is a hardware chess engine controlled by a minimal host-side Python program. The host exposes UCI, validates and parses incoming positions and moves, logs activity, and translates UCI commands into a compact FPGA protocol. FPGA commands are assumed valid after host parsing.

The FPGA maintains the active game/search state between commands and performs the search work. Once a search command begins, the FPGA does not require further host communication until it finishes, except for asynchronous control such as kill/reset or output backpressure.

The internal design passes explicit board-state values through shared pipelines. A board position is represented as `FullBoard` plus side data such as a Zobrist key, incremental piece-square-table score, material information, search stack records, transposition-table metadata, and per-thread control state.

The target design has a parameterized number of search threads, with `THREAD_COUNT = 8` as the current documented default. Threads cooperate using Lazy SMP: each thread runs an independent iterative-deepening alpha/beta search, and the required shared transposition table is the only shared search knowledge between threads.

## Major Blocks

| Block                      | Role                                                                                                                                        |
| -------------------------- | ------------------------------------------------------------------------------------------------------------------------------------------- |
| Host Python process        | Implements UCI, validates/parses positions and moves, logs activity, and communicates with the FPGA.                                        |
| RX decode                  | Converts UART input into command/data bytes and handles asynchronous kill/reset commands.                                                   |
| TX encode                  | Converts FPGA output bytes into UART output and reports backpressure.                                                                       |
| Engine command layer       | Receives host commands, maintains engine-level state, and starts/stops searches.                                                            |
| Search controller          | Owns search threads, search stacks, alpha/beta state, pipeline dispatch, and result routing.                                                |
| Board update pipeline      | Applies push move, commit move, reverse move, and board setup operations.                                                                   |
| Move generation pipeline   | Produces one ordered candidate move per dispatch and reports whether that candidate is legal.                                               |
| Static evaluation pipeline | Computes White-relative full-position evaluation terms from a board-state input.                                                            |
| TT lookup pipeline         | Performs transposition-table lookup requests against external RAM and any internal cache.                                                   |
| TT store pipeline          | Performs transposition-table writes; stores may be stalled or deprioritized when memory bandwidth is needed by lookups.                     |
| External RAM interface     | Provides storage for the transposition table through a vendor-neutral wrapper around the selected SDRAM, DDR, or board memory interface.    |
| FPGA platform wrappers     | Isolate vendor-specific RAM, ROM, PLL, FIFO, UART, and external-memory IP so Intel/Altera and Xilinx builds can share the same logical RTL. |

## Search Pipelines

The five major search pipelines are board update, static evaluation, ordered move generation, TT lookup, and TT store.

Board update, static evaluation, and move generation are high-area pipelines and should be kept busy with work from many search threads. For the base design, each search thread may have at most one in-flight request in each pipeline. This avoids duplicate work for the same thread position and lets pipeline results be routed by `thread_id` without a wider request ID.

Pipeline parallelism means different threads can occupy different stages of the same pipeline at the same time. It does not mean a single thread issues multiple simultaneous board updates, evaluations, or move-generation requests for the same active position.

The main pipelines are designed for throughput and can accept a new request each cycle when input work is available and downstream resources are not stalled. TT lookup/store throughput is limited by external memory bandwidth.

## State Ownership

The FPGA maintains active game state between commands. The host can send setup, make-move, undo-move, and search commands; the Python host is responsible for parsing and validating UCI inputs before encoding those commands.

Search owns per-thread state. Each thread keeps an active search stack and stack records for undo rather than storing a full `FullBoard` at every ply. The board update pipeline transforms board states and move records but should not be treated as the long-term owner of the engine position.

Zobrist hashes are maintained incrementally because they are efficient to update. Piece-square-table and material evaluation are recomputed to reduce LUT usage. The remainder of the static evaluation is fully computed by the pipeline on dispatch.

Raw static evaluation and incremental PST/material state should be White-relative in the final design. Search should normalize scores to point-of-view format at search boundaries. This keeps evaluation modules simple while allowing the search controller to use a conventional side-to-move alpha/beta convention.

## Transposition Table

The transposition table used to store previously computed information is required for the Lazy SMP multithreading to be effective. The primary TT lives in external memory behind a vendor-neutral wrapper. A BRAM cache may be used to reduce external-memory pressure when a target FPGA has sufficient block memory.

TT lookups are more latency-sensitive than TT stores and receive priority when lookup/store bandwidth conflicts. Stores can be stalled when memory bandwidth is needed by lookups. The memory arbitration policy is a tunable design parameter and should be selected based on measured search throughput.

## Vendor Support

The logical design should be FPGA-vendor neutral. Vendor-specific resources must be isolated behind wrappers or generated modules with stable logical interfaces. Intel/Altera and Xilinx support should both be considered when defining RAMs, FIFOs, external memory controllers, clocking, and board-level I/O.
