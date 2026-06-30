### Engine Ports

A list of ports on the engine module.

| Direction | Port Name          | Size (bits) | Descriptions and Usage                                                                                                                                             |
| --------- | ------------------ | ----------- | ------------------------------------------------------------------------------------------------------------------------------------------------------------------ |
| Input     | `clk`              | 1           |                                                                                                                                                                    |
| Input     | `rst_n`            | 1           | Synchronous active-low reset                                                                                                                                       |
| Input     | `data_in`          | 8           | Data input into the engine. Data can include operation codes, board data, etc.. Every operation is directly followed by data for a predetermined number of cycles. |
| Input     | `data_in_valid`    | 1           | Indicates if `data_in` is valid                                                                                                                                    |
| Input     | `kill`             | 1           |                                                                                                                                                                    |
| Input     | `ready_for_result` | 1           | Indicates that the engine can continue streaming result. If this is not asserted, the engine should pause.                                                         |
| Output    | `error_flag`       | 1           | Indicates the engine is in an error state (remove?)                                                                                                                |
| Output    | `ready`            | 1           | Indicates the engine is ready for the next command or piece of data. Asserted as soon as current command is complete.                                              |
| Output    | `data_out`         | 8           | Data the engine outputs.                                                                                                                                           |
| Output    | `data_out_valid`   | 1           | Indicates that `data_out` is valid                                                                                                                                 |

---
### Engine Commands

*Note: For multi-byte values, the little-endian convention is used*

How to deal with two board squares arriving in the same byte?

| Command                | Description                                         | Inputs (In Order)                      |
| ---------------------- | --------------------------------------------------- | -------------------------------------- |
| Get Status             | Returns the status of the engine                    |                                        |
| Write to Board Memory  | Write a board position to board memory              | Board Memory Address<br><br>Board Data |
| Read from Board Memory | Read a board position form board memory             | Board Memory Address                   |
| Load Board from Memory | Load a position from board memory to PE array       | Board Memory Address                   |
| Copy Board to Memory   | Copy the active board to memory                     | Board Memory Address                   |
| Make Move              | Make a move on active board                         | Move Data                              |
| Reverse Move           | Reverse a move on active board                      |                                        |
| Search Depth           | Searches Current Position to a given depth          | Depth to Search                        |
| Search Fixed Time      | Searches for a fixed amount of time before stopping | Time to Search                         |
| Search on Clock        | Completes a search given chess clock information    | `wtime`, `btime`, `winc`, `binc`       |
| Search set Nodes       | Searches a set number of nodes                      | Nodes Count to Search                  |
| Perft                  | Count strictly legal moves to a certain depth.      | Depth to Search                        |
| Kill                   | Kills the current search                            |                                        |
| Get search result      | Returns result of most recent search                |                                        |

---
### Engine States

A list of states the engine can occupy

| State                  | Description                                                                     |
| ---------------------- | ------------------------------------------------------------------------------- |
| Engine Error (remove?) | Indicates a fatal error with the engine                                         |
| Idle                   | Engine is awaiting a task                                                       |
| Write Board Memory     | Write a board position to board memory                                          |
| Read Board Memory      | Read a board position from board memory                                         |
| Load Board from Memory | Load a position from board memory to PE array                                   |
| Copy Board to Memory   | Copy the active board to memory                                                 |
| Make Move              | Make a move on PE array                                                         |
| Reverse Move           | Reverse a move on PE array                                                      |
| Search                 | Sets search parameters, waits for search to complete, then saves search result. |
| Perft                  | Count strictly legal moves to a certain depth.                                  |
| Output Result          | Outputs the result one byte at a time.                                          |
| Output Paused          | Pause output as parent isn't ready for data.                                    |
| Input Paused           | Paused while waiting for more input data.                                       |

---
### Engine Registers

| Register Name | Size (bits) | Description                                          |
| ------------- | ----------- | ---------------------------------------------------- |
| `state`       |             | Current Engine State                                 |
| `wtime`       | `TIME_BITS` | Time left on the clock for White (in milliseconds).  |
| `btime`       | `TIME_BITS` | Time left on the clock for Black (in milliseconds).  |
| `winc`        | `TIME_BITS` | Time increment per move for While (in milliseconds). |
| `binc`        | `TIME_BITS` | Time increment per move for Black (in milliseconds). |
| `depth_limit` |             | The max depth to search.                             |
| `node_limit`  |             | The max number of evaluations to make.               |
| `time_limit`  | `TIME_BITS` | Time max amount of time to spend.                    |

---
### Engine Child Modules

- [`search_controller`](search_controller)

