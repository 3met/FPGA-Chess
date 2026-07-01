### Functionality in Module

- Conducts alpha/beta search
- Counts number of nodes
- Does not search past time limit, node limit, or depth limit depending on operation
- Can write data to the board
### Search Controller Operations

| Command           | Description                                                                            |
| ----------------- | -------------------------------------------------------------------------------------- |
| Idle              | Search module should idle. Ports should output the result from previous search.        |
| Direct Board      | Parent module directly commands the board. This is used to update the board.           |
| Search Depth      | Searches Current Position to a given depth.                                            |
| Search Fixed Time | Searches for a fixed amount of time before stopping.                                   |
| Search on Clock   | Completes a search given chess clock information.                                      |
| Search Nodes      | Searches a set number of nodes.                                                        |
| Perft             | Count strictly legal moves to a certain depth. Results are transmitted via node count. |
| Kill              | Kills the current search                                                               |

---
### Search Controller Ports

A list of ports on the engine module.

| Direction | Port Name         | Size (bits)       | Descriptions and Usage                                                                                                  |
| --------- | ----------------- | ----------------- | ----------------------------------------------------------------------------------------------------------------------- |
| Input     | `operation`       |                   | Operation for the search engine to complete.                                                                            |
| Input     | `direct_board_op` |                   | Operation for the board to complete. Allows parent module to directly access board using `move_in` and `board_wr_data`. |
| Input     | `move_in`         |                   | A move for the board to make.                                                                                           |
| Input     | `board_wr_data`   | 4                 | Data to be written to the board such a tile data, en passant data, current turn data, etc..                             |
| Input     | `clock_time`      | `TIME_BITS`       | Time left on the clock for engine (in milliseconds).                                                                    |
| Input     | `inc_time`        | `TIME_BITS`       | Time increment per move for engine (in milliseconds).                                                                   |
| Input     | `depth_limit`     |                   | The max depth to search.                                                                                                |
| Input     | `node_limit`      | `NODE_COUNT_BITS` | The max number of evaluations to make.                                                                                  |
| Input     | `time_limit`      | `TIME_BITS`       | Time max amount of time to spend.                                                                                       |
| Input     | `kill`            | 1                 |                                                                                                                         |
| Output    | `ready`           | 1                 | Indicates ready for another command. Score from previous search should be valid when `ready` is asserted.               |
| Output    | `board_rd_data`   |                   | Data read from a tile.                                                                                                  |
| Output    | `score`           |                   | Score from the most recent search.                                                                                      |
| Output    | `move_out`        |                   | Best move found from the most recent search.                                                                            |
| Output    | `nodes_count`     | `NODE_COUNT_BITS` | Number of nodes searched.                                                                                               |

---
### Search Controller Registers

| Register Name          | Size (bits)       | Description                                           |
| ---------------------- | ----------------- | ----------------------------------------------------- |
| `state`                |                   | Holds the current state of the search controller FSM. |
| `curr_operation`       |                   | Store the current operation.                          |
| `curr_depth`           |                   | The depth of the current search.                      |
| `target_depth`         |                   | The target depth of the current search.               |
| `alpha[MAX_PLY_COUNT]` |                   | Alpha values for the alpha/beta search.               |
| `beta[MAX_PLY_COUNT]`  |                   | Beta values for the alpha/beta search.                |
| `node_count`           | `NODE_COUNT_BITS` | Store the number of nodes searched.                   |
### Search Controller Child Modules
- [`board_controller`](board-controller.md)
- [`move_generator`](move-generator.md)
- [`static_evaluator`](static-evaluator.md)
- [`timer`](timer.md)
