# Search Controller (`search_controller`)

The search controller owns the active position, hardware search threads, search stacks, alpha/beta state, repetition state, shared-pipeline scheduling, and result selection. The search algorithm is specified in [search-design.md](../architecture/search-design.md); this document defines the controller boundary and orchestration responsibilities.

## Operations

| Operation | Behavior |
| --------- | -------- |
| Direct Board | Applies a setup or game move operation to the active position. |
| New Game | Cancels active work, clears game-dependent search state, advances the TT generation, and restores the standard starting position. |
| Search Depth | Searches the active position to a bounded fixed depth. |
| Search Fixed Time | Searches until the fixed-time budget expires. |
| Search on Clock | Derives and enforces a budget from the supplied clock and increment. |
| Search Nodes | Searches until the node budget is reached. |
| Perft | Counts strictly legal leaf positions through the normal move-generation and board-update paths without modifying the active position. |
| Kill | Cancels active search or perft work and drains or invalidates outstanding pipeline responses. |

The request uses a ready/valid handshake. `req_ready` means the complete typed request was captured. Exactly one `resp_valid` completion is produced for every accepted operation.

## Ports

| Direction | Port | Description |
| --------- | ---- | ----------- |
| Input | `clk`, `rst_n` | Controller clock and synchronous active-low reset. |
| Input | `req_valid`, `req` | Typed operation request from the engine command layer. |
| Output | `req_ready` | Request acceptance. |
| Output | `resp_valid`, `resp` | Operation completion and result. |
| Input | `tt_memory_ready`, `tt_memory_error` | Selected TT backend status. |
| Request/response | `tt_mem_*` | Vendor-neutral TT burst-memory channels described in [tt-memory.md](tt-memory.md). |

## State Ownership

The active board is canonical controller state between commands. Direct-board operations transform it through `board_update_pipeline`; pipeline modules do not retain canonical positions.

Each search thread owns a current board, Zobrist key, incremental evaluation state, alpha/beta state, node count, lifecycle phase, and a block-RAM search stack. Stack records hold the information needed to resume a parent after reversing a child, rather than storing a complete board at every ply.

Each node records its actual remaining depth. That value controls main-search versus quiescence behavior, late-move reductions, and TT depth; it is not inferred from ply.

Each packed node record also retains the first three ordinary quiet moves that were searched completely without cutting off. The count is cleared when a node is entered, while the stale move-address fields need not be cleared. A quiet is appended only after all PVS or LMR re-searches for that logical move are complete; qsearch, illegal moves, captures, promotions, and unsearched moves are excluded.

The primary thread owns the reported principal variation, score, and completed depth. Helper threads cooperate through the shared TT and never overwrite the primary result directly.

## Shared-Pipeline Scheduling

The controller schedules threads across:

- [board update](board-update-pipeline.md)
- [move generation](move-generator.md)
- [static evaluation](static-evaluator.md)
- [transposition-table lookup and store](transposition-table.md)
- [repetition checking](repetition-checker.md)
- [timer](timer.md)

A thread has at most one in-flight request in each shared subsystem. Every request carries enough thread and operation metadata to route its completion independently of whichever thread is being dispatched when the response arrives.

Ready threads are selected independently for different pipelines, allowing unrelated thread work to overlap. Lookup responses and returned child scores take priority because they unblock existing search work. TT stores are best-effort and never block a thread after the TT frontend accepts the publication.

Reset, New Game, Kill, and search initialization invalidate outstanding tags, pending returns, and in-flight state so a late response cannot mutate a later operation.

## Node Lifecycle

At a search node, the controller:

1. Checks draw state and probes the TT.
2. Tries the TT or previous-iteration ordering move directly when available.
3. Generates and searches noisy moves.
4. Generates and searches quiet moves.
5. Searches deferred bad captures.
6. Scores checkmate, stalemate, or the completed alpha/beta result.

Move generation produces pseudo-legal candidates. The controller speculatively applies each candidate through board update and rejects it if the moving side remains in check. A rejected candidate does not alter thread state or increment the search node count.

A legal child is written to repetition line history before TT lookup, evaluation, or deeper search. On return, the controller reverses the move and folds the child score into the saved parent. A real legal child increments the search node count even if repetition or a TT cutoff resolves it without deeper evaluation.

When a searched quiet move causes a beta cutoff, the controller snapshots the winner, the node's retained failed quiets, color, and depth into the existing per-thread best-effort history-update slot. Search never waits for that slot or for history RAM maintenance; an event is dropped if the thread's slot is still occupied.

Quiescence search uses captures and promotions and omits quiet generation and direct TT move ordering. Perft uses the same legality and board-update paths but counts fixed-depth leaves instead of evaluating positions.

## Stops and Results

Depth, node, and time limits are checked at safe search boundaries. The reported depth is the deepest fully completed primary-thread iteration. If a deeper iteration is interrupted, the controller preserves the completed result and may also retain a legal root move whose child result completed during the partial iteration.

Kill stops issuing new search work, invalidates work that cannot safely complete, and produces a completion only after late responses can no longer alter the active operation.

Checkmate, stalemate, the 50-move rule, and threefold repetition are terminal search results. Score representation and mate-distance handling follow [search-design.md](../architecture/search-design.md).

## Configuration and Instrumentation

Thread count, stack depth, repetition-history depth, LMR constants, clock frequency, TT backend selection, and optional statistics are synthesis parameters. Capacity types define the maximum encodable thread and ply identifiers; a target may instantiate fewer contexts.

Optional statistics report pipeline activity, search phases, TT/cache behavior, move-generation activity, and overflow state through the engine debug interface. Statistics do not affect search semantics.
