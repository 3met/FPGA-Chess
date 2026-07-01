# Chip Design

The chip is a hardware chess search engine controlled by a minimal host-side Python program. The Python program exposes a UCI interface, validates and parses incoming positions and moves, logs activity, and translates UCI-level commands into a compact FPGA command protocol. The FPGA maintains game/search state between commands and performs the search work.

The internal design uses explicit board-state values passed through shared pipelines. A board position is represented as `FullBoard` plus side data such as Zobrist board hash, incremental piece-square-table score, material information, search stack records, and per-thread control state.

The engine has many parameterized search threads. The target range is roughly 15-30 threads, but the exact count should be selected per FPGA build. Threads cooperate using Lazy SMP: each thread runs an independent iterative-deepening alpha/beta search, and the transposition table is the only shared search knowledge between threads.

## Major Blocks

| Block | Role |
| ----- | ---- |
| Host Python process | Implements UCI, validates/parses positions and moves, logs activity, and communicates with the FPGA. |
| Engine command layer | Receives host commands, maintains engine-level state, and starts/stops searches. |
| Search controller | Owns search threads, search stacks, alpha/beta state, pipeline dispatch, and result routing. |
| Board update pipeline | Applies push move, commit move, reverse move, and board setup operations. |
| Move generation pipeline | Produces one ordered candidate move per dispatch and reports whether that candidate is legal. |
| Static evaluation pipeline | Computes full-position evaluation terms from a board-state input, likely using parallel per-square hardware internally. |
| Load TT pipeline | Performs transposition-table lookup requests against external RAM and any internal cache. |
| Store TT pipeline | Performs transposition-table writes; stores may be stalled or deprioritized when memory bandwidth is needed by loads. |
| External RAM interface | Provides storage for the transposition table, likely using SDRAM or DDR. |
| FPGA platform wrappers | Isolate vendor-specific RAM, ROM, PLL, FIFO, UART, and external-memory IP so Intel/Altera and Xilinx builds can share the same logical RTL. |

## Search Pipelines

The five major search pipelines are board update, static evaluation, ordered move generation, load TT, and store TT.

Board update, static evaluation, and move generation are high-area pipelines and should be kept busy by dispatching work from many search threads. For the base design, each search thread may have at most one in-flight request in each pipeline. This avoids spending pipeline slots on duplicate work for the same thread position and allows pipeline results to be routed using `thread_id` without requiring a wider request ID.

Pipeline-parallelism means different threads can occupy different stages of the same pipeline at the same time. It does not mean a single thread issues multiple simultaneous board updates, evaluations, or move-generation requests for the same active position.

The main pipelines should be designed as throughput pipelines that can accept a new request each cycle when input work is available and downstream resources are not stalled. The latency may be many cycles; the throughput goal is one accepted request per cycle. TT load/store throughput is limited by external memory bandwidth.

## State Ownership

The FPGA maintains the active game state between commands. The host can send setup, make-move, undo-move, and search commands; the Python host is responsible for parsing and validating UCI inputs before encoding those commands.

Search owns per-thread state. Each thread keeps an active search stack and stack records for undo rather than storing a full `FullBoard` at every ply. The board update pipeline transforms board states and move records but should not be treated as the long-term owner of the engine position.

Zobrist hashes are maintained incrementally because they are efficient to update. Piece-square-table and material evaluation may be recomputed rather than maintained incrementally if that reduces LUT usage. Static evaluation is hybrid: some terms are carried or recomputed incrementally through board update, while other terms are fully computed by the static evaluation pipeline on dispatch.

Evaluation scores should be treated as point-of-view scores at search boundaries unless a module explicitly documents otherwise. The existing RTL is mixed: `board_controller` maintains `pst_eval` from the active-color perspective, while `static_evaluator` currently outputs a White-relative score.

## Transposition Table

The transposition table is the shared Lazy SMP data structure. The primary TT lives in external SDRAM/DDR. A BRAM cache may be used to reduce external-memory pressure.

TT loads are more latency-sensitive than TT stores and receive priority when load/store bandwidth conflicts. Stores can be stalled when memory bandwidth is needed by loads. The memory arbitration policy is a tunable design parameter and should be selected based on measured search throughput.

## Vendor Support

The logical design should be FPGA-vendor neutral. Vendor-specific resources must be isolated behind wrappers or generated modules with stable logical interfaces. Intel/Altera and Xilinx support should both be considered when defining RAMs, FIFOs, external memory controllers, clocking, and board-level I/O.
