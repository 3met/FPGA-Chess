# Current Architecture

# Current Architecture

The current internal design uses explicit board-state values passed through pipelined modules. A board position is represented as `FullBoard` plus side data such as board hash, piece-square-table evaluation, and search history.

The active board-update path is `board_controller`. It accepts a board state and an operation, then outputs the updated board state after a fixed pipeline latency.

Move generation and static evaluation should operate from board-state inputs. The static evaluator may use a PE-style internal array for parallel per-square calculations, but it should not own the canonical board state.

## Major Internal Modules

| Module | Role |
| ------ | ---- |
| `search_controller` | Owns the search algorithm and schedules board updates, move generation, evaluation, and limits. |
| `board_controller` | Applies board mutations such as push move, commit move, reverse move, and setup writes. |
| `move_generator` | Generates ordered pseudo-legal or legal candidate moves from a board-state input. |
| `static_evaluator` | Computes non-incremental evaluation terms from a board-state input, likely using parallel per-square hardware internally. |
| `timer` | Tracks elapsed search time. |

## State Ownership

Search owns the active search stack and decides which board state is current for each ply. `board_controller` transforms board states but should not be treated as the long-term owner of the engine position.

Incremental values such as board hash and PST evaluation travel with the board state through the pipeline. Search decides when those values are committed, copied, or discarded.
