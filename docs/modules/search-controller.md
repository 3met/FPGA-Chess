# Search Controller (`search_controller`)

Status: planned final RTL spec.

The search controller owns the hardware search threads, the active board state visible to search, alpha/beta state, pipeline dispatch, and search-result selection.

## Operations

| Operation | Description |
| --------- | ----------- |
| Idle | Search controller is idle. Result ports hold the most recent completed search result. |
| Direct Board | Parent module directly applies a board operation. Used for setup, make move, undo move, and active-position maintenance. |
| Search Depth | Search current position to a fixed depth. |
| Search Fixed Time | Search until the fixed time limit expires. |
| Search on Clock | Search using clock and increment information from the engine layer. |
| Search Nodes | Search until a node limit is reached. |
| Perft | Count strictly legal moves to a fixed depth. Result is transmitted via node count. |
| Kill | Stop the current search as soon as pipeline state can be drained safely. |

## Ports

| Direction | Port Name | Size | Description |
| --------- | --------- | ---- | ----------- |
| Input | `clk` | 1 | Clock. |
| Input | `rst_n` | 1 | Synchronous active-low reset. |
| Input | `operation` | Enum | Operation for the search controller to start or continue. |
| Input | `direct_board_op` | `BoardOp` | Board operation to execute during Direct Board mode. |
| Input | `move_in` | `Move` | Move for Direct Board, root move hints, or legality/perft operations as needed. |
| Input | `board_wr_data` | 4 | Tile, turn, castle-perms, or en-passant data for direct board writes. |
| Input | `clock_time` | `TIME_BITS` | Time left on the clock for the side to move. |
| Input | `inc_time` | `TIME_BITS` | Increment for the side to move. |
| Input | `depth_limit` | Depth field | Maximum search depth. |
| Input | `node_limit` | `NODE_COUNT_BITS` | Maximum number of nodes to search. |
| Input | `time_limit` | `TIME_BITS` | Maximum fixed search duration. |
| Input | `kill` | 1 | Stops the current operation. |
| Output | `ready` | 1 | Indicates ready for another operation. Score and move outputs are valid for the previous completed search when asserted. |
| Output | `board_rd_data` | 4 | Data read from direct board access. |
| Output | `score` | `EvalScore` | Best score from the most recent search, root side-to-move point-of-view. |
| Output | `move_out` | `Move` | Best move from the most recent search. |
| Output | `nodes_count` | `NODE_COUNT_BITS` | Number of nodes searched. |
| Output | `completed_depth` | Depth field | Deepest fully completed root iteration. |
| Output | `end_reason` | Enum | Reason the search stopped. |

## Score Convention

Search uses side-to-move point-of-view scores internally. Raw static evaluation and incremental PST/material state are White-relative, and the search controller converts them at leaf/static-eval boundaries based on the board side to move.

TT scores use the same side-to-move point-of-view convention as search. Mate scores must be adjusted by ply when stored or loaded so mate distance remains comparable.

## Required Child Pipelines

- [`board_update_pipeline`](board-update-pipeline.md)
- [`move_generator`](move-generator.md)
- [`static_evaluator`](static-evaluator.md)
- [`tt_lookup`](tt-lookup.md)
- [`tt_store`](tt-store.md)
- [`timer`](timer.md)

## Registers

| Register Name | Size | Description |
| ------------- | ---- | ----------- |
| `state` | Enum | Current search-controller FSM state. |
| `curr_operation` | Enum | Operation currently running. |
| `curr_depth` | Depth field | Current iterative-deepening depth. |
| `target_depth` | Depth field | Search depth limit. |
| `alpha[THREAD_COUNT][MAX_PLY_COUNT]` | `EvalScore` | Alpha stack values per thread. |
| `beta[THREAD_COUNT][MAX_PLY_COUNT]` | `EvalScore` | Beta stack values per thread. |
| `node_count[THREAD_COUNT]` | `NODE_COUNT_BITS` | Node count per thread. |
| `thread_state[THREAD_COUNT]` | Struct | Per-thread search state, current ply, wait state, and active board snapshot. |
| `game_repetition_history` | Hash array | Active-game reversible-position hashes since the last irreversible move. |
| `thread_repetition_history[THREAD_COUNT][MAX_PLY_COUNT]` | Hash array | Search-line hashes used to detect repetition inside each thread's current line. |

## Open Design Items

- Exact per-thread FSM and root move assignment policy.
- Ready-thread arbitration between pipelines.
- Exact storage shape for active-game and per-thread repetition hash histories.
- Exact perft implementation strategy.
