# Search Controller (`search_controller`)

The search controller owns the active position, search threads and stacks, repetition state, shared-pipeline scheduling, and result selection. The search algorithm is specified in [search-design.md](../architecture/search-design.md); this document defines the controller boundary and orchestration responsibilities.

## Operations

| Operation | Behavior |
| --------- | -------- |
| Board Update | Apply position setup or a game move to the active position. |
| New Game | Cancel active work, clear game-dependent state, physically invalidate the TT, and restore the starting position. |
| Search Depth | Search to a fixed depth. |
| Search Fixed Time | Search until a fixed-time budget expires. |
| Search on Clock | Derive and enforce a budget from clock and increment values. |
| Search Nodes | Search until the node budget is reached. |
| Perft | Count legal leaves through the production move and board paths without changing the active position. |
| Kill | Cancel active search or perft work and invalidate or drain outstanding responses. |

Requests and responses use ready/valid handshakes. Every accepted operation produces exactly one completion.

## Ports

| Direction | Port | Description |
| --------- | ---- | ----------- |
| Input | `clk`, `rst_n` | Controller clock and synchronous active-low reset. |
| Input | `req_valid`, `req` | Typed operation request from the command layer. |
| Output | `req_ready` | Request acceptance. |
| Output | `resp_valid`, `resp` | Operation completion and result. |
| Input | `tt_memory_clk`, `tt_memory_rst_n` | External-memory interface clock and local reset. |
| Input | `tt_memory_ready`, `tt_memory_error` | External-memory backend status synchronized to the engine clock. |
| Request/response | `tt_mem_*` | Vendor-neutral TT memory channels described in [tt-memory.md](tt-memory.md). |

## State Ownership

The active board is canonical controller state between commands. Board operations use [board_update_pipeline](board-update-pipeline.md) to update it and its incremental state. New Game restores the starting position and clears repetition history.

Each search thread owns its current position, search stack, alpha/beta window, iterative-deepening state, and node count. The stack retains the state needed to reverse a child and resume its parent.

The primary thread owns the published result and last completed iteration. Helper threads cooperate through the TT and never delay or overwrite the primary result. Threads advance through iterative deepening independently.

The controller uses [time_management](time-management.md) to allocate clock budgets and adjust stopping decisions after completed primary iterations. The hard deadline remains active during allocation.

## Shared-Pipeline Scheduling

The controller schedules work across:

- [board update](board-update-pipeline.md)
- [move generation](move-generator.md)
- [NNUE evaluation](nnue-evaluator.md)
- [transposition-table lookup and store](transposition-table.md)
- [repetition checking](repetition-checker.md)
- [time management](time-management.md)

A thread has at most one in-flight request in each subsystem, with generation and move reads tracked independently. Requests carry thread, ply, and operation metadata so completions can be routed independently of the controller's current dispatch choice. Work that unblocks an existing node takes priority over best-effort TT publication and history maintenance.

Before search, NNUE builds a root accumulator for every thread. Legal child preparation completes NNUE and repetition work before the child becomes runnable. Null children reuse the parent's accumulator.

Reset, New Game, Kill, and search restart prevent outstanding responses from changing a later operation. Each thread retains TT transport ownership until its accepted probe returns, even after search cancellation. A new probe for that thread waits for the old response to drain; canceled responses are discarded.

## Node Lifecycle

The controller applies the search policy described in [search-design.md](../architecture/search-design.md), coordinating terminal checks, TT lookup, pruning, move generation, child search, and return to the parent.

Move generation produces pseudo-legal candidates. The controller applies each candidate speculatively and rejects it if the moving side remains in check. Accepted children update repetition and NNUE state; returning from a child restores the parent position and folds the child score into its result.

Generation and move reads can overlap. Generation and direct-validation commands share lane arbitration; each thread accepts bucket pops through its own ready/valid channel independently of command selection. The controller initializes a node's move storage before descent and waits for parent generation to complete before a child can allocate move storage, descend, or reverse the parent. Cancellation covers both generation and reads. Bucket ordering and storage ownership are defined in [move-generator.md](move-generator.md).

TT moves pass through the same legality checks as generated moves. The controller enforces the root and repetition-sensitive cutoff restrictions described in [transposition-table.md](transposition-table.md).

Perft uses the same generation, legality, and reversal paths but counts fixed-depth leaves instead of evaluating positions.

## Stops and Results

Depth, node, and time limits are checked at safe search boundaries. Hard time limits return the last completed primary iteration. Node limits and explicit kills may use a fully resolved root candidate from the interrupted iteration when it satisfies the result-selection rules in [search-design.md](../architecture/search-design.md); otherwise they return the completed result. A partial result does not advance the reported completed depth.

Completed primary iterations retain the best root move and its searched child reply as a two-move principal-variation prefix for UCI pondering.

Kill stops new work and completes only after outstanding responses can no longer change the active operation. A killed search selects and snapshots its result before completing.

Node-limited search can commit at most one additional node beyond its requested count.

## Configuration and Instrumentation

Synthesis parameters cover engine structure, search policy, time allocation, move ordering, TT configuration, and optional statistics. Engine profiles select structural values and reference reusable search-policy profiles.

Optional statistics report pipeline activity, search phases, TT/cache behavior, move-generation work, and overflow state without affecting search semantics.
