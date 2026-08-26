# Search Controller (`search_controller`)

The search controller owns the active position, search threads and stacks, repetition state, shared-pipeline scheduling, and result selection. The search algorithm is specified in [search-design.md](../architecture/search-design.md); this document defines the controller boundary and orchestration responsibilities.

## Operations

| Operation | Behavior |
| --------- | -------- |
| Board Update | Apply position setup or a game move to the active position. |
| New Game | Cancel active work, clear game-dependent state, advance the TT generation, and restore the starting position. |
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
| Input | `tt_memory_ready`, `tt_memory_error` | Selected TT backend status. |
| Request/response | `tt_mem_*` | Vendor-neutral TT memory channels described in [tt-memory.md](tt-memory.md). |

## State Ownership

The active board is canonical controller state between commands. Direct-board operations transform it through `board_update_pipeline`, including its cached king squares; shared pipelines do not retain canonical positions.

Each search thread owns its current board and incremental state, alpha/beta window, iterative-deepening state, node count, lifecycle phase, and block-RAM search stack. Stack records hold enough state to reverse a child and resume its parent instead of storing a complete board at every ply. Each node records actual remaining depth because reductions and quiescence entry make it independent of ply.

The primary thread owns the reported move, score, and completed depth. Helpers cooperate only through the TT and never delay or overwrite the primary result. Threads retry aspiration failures or begin new iterations independently.

## Shared-Pipeline Scheduling

The controller schedules work across:

- [board update](board-update-pipeline.md)
- [move generation](move-generator.md)
- [NNUE evaluation](nnue-evaluator.md)
- [transposition-table lookup and store](transposition-table.md)
- [repetition checking](repetition-checker.md)
- [timer](timer.md)

A thread has at most one in-flight request in each subsystem. Requests carry thread, ply, and operation metadata so completions can be routed independently of the controller's current dispatch choice. Work that unblocks an existing node takes priority over best-effort TT publication and history maintenance.

Before search, NNUE builds a valid root accumulator for every thread. Legal child preparation joins NNUE and repetition work before the child becomes runnable. Null children reuse the parent's accumulator. Reset, New Game, Kill, and search restart invalidate tags and pending returns so late responses cannot mutate a later operation.

## Node Lifecycle

A main-search node follows this logical order:

1. Check terminal draw state and probe the TT.
2. Try eligible pruning operations and direct ordering moves.
3. Generate and search noisy moves.
4. Generate and search quiet moves.
5. Search deferred unfavorable captures.
6. Return checkmate, stalemate, or the completed alpha/beta result.

Move generation is pseudo-legal. The controller speculatively applies each candidate and rejects it if the moving side remains in check. A legal child is recorded in repetition history and prepares its NNUE state before TT lookup, evaluation, or deeper search. On return, the controller reverses the board and accumulator changes and folds the child score into the saved parent.

History-sensitive TT scores are validated according to [transposition-table.md](transposition-table.md). A rejected score may still supply a legal ordering move. Null children bypass ordinary legality, repetition, legal-node counting, best-move selection, and move-history updates.

Quiescence omits quiet generation and both bad-noisy buckets except for legal evasions while in check. Perft uses the same generation, legality, and reversal paths but counts fixed-depth leaves instead of evaluating positions.

## Stops and Results

Depth, node, and time limits are checked at safe search boundaries. If a pass is interrupted, the controller returns the primary thread's most recent fully completed iteration when one exists. The reported depth is therefore a completed depth rather than the deepest partial work reached. Completed primary iterations retain the best root move and its searched child reply as the two-move principal-variation prefix returned for UCI pondering.

Kill stops new work and completes only after outstanding responses have been invalidated or can no longer change the active operation. A killed search snapshots its best completed iteration, or a usable partial root move when no iteration completed, into the cached search result before retiring.

Checkmate, stalemate, the 50-move rule, and threefold repetition are terminal. Score representation and mate-distance handling follow [search-design.md](../architecture/search-design.md).

## Configuration and Instrumentation

Thread count, stack depth, repetition capacity, aspiration policy, LMR policy, null-move policy, time allocation, move-history policy, clock frequency, TT backend, TT policy, TT tag width, and optional statistics are synthesis parameters. Per-FPGA engine profiles select structural values and reference reusable search-policy profiles. Build-generated packed identifier widths follow the selected thread count and stack depth.

Optional statistics report pipeline activity, search phases, TT/cache behavior, move-generation work, and overflow state without affecting search semantics.
