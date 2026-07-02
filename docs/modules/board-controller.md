# Board Controller (`board_controller`)

Status: partially implemented; this document describes the final target contract.

The board controller is a pipelined board-state transformer. It accepts a complete `FullBoard`, side data, and an operation, then outputs the transformed board and updated side data after a fixed latency. It does not own the long-term active board state.

## Ports

| Direction | Port Name | Description |
| --------- | --------- | ----------- |
| Input | `clk` | Clock. |
| Input | `board_op` | Operation code for what the board controller should do. |
| Input | `board_in` | Input `FullBoard` state. |
| Input | `board_hash_in` | Initial hash of the board. |
| Input | `pst_eval_in` | Current White-relative piece-square-table evaluation. |
| Input | `move_in` | Move to apply for push/commit operations, or destination square for set-tile operations. |
| Input | `set_data` | Tile, turn, castle perms, or en passant info depending on the set operation. |
| Input | `thread_id` | Search thread whose move-history record should be read or written. |
| Input | `search_depth` | Search ply before the current operation. |
| Output | `board_out` | Output `FullBoard` state. |
| Output | `board_hash_out` | Updated board hash. |
| Output | `pst_eval_out` | Updated White-relative PST evaluation. |

## Operations

| Operation | Inputs Required | Description |
| --------- | --------------- | ----------- |
| Push Move | `move_in` | Makes a reversible search move and writes a move-history record. |
| Commit Move | `move_in` | Makes an irreversible active-game move without writing a search undo record. |
| Set Tile | `move_in.end_pos`, `set_data` tile | Places a piece or `NULL_PIECE` on one square. |
| Set Turn | `set_data[0]` | Updates the side to move without changing tiles. |
| Set Castle Perms | `set_data[3:0]` | Updates castling permissions without changing tiles. |
| Set En Passant | `{ep_file[2:0], has_ep}` | Updates en passant state without changing tiles. |
| Reverse Move | `thread_id`, `search_depth` | Reverses the previous pushed move for the thread. |
| Idle | None | Does nothing. |

## Pipeline

| Pipeline Stage | Description |
| -------------- | ----------- |
| 0 | Register inputs and fetch previous move data for reverse operations. |
| 1 | Prepare side-data updates and preserve input context. |
| 2 | Alignment stage. |
| 3 | Compute primary tile updates and fetch Zobrist/PST data. |
| 4 | Update first extra tile for en passant or castling and write move record. |
| 5 | Update second extra tile for castling and account for captured material. |
| 6 | Output board data, board hash, and PST evaluation. |

## Board Setup

The final engine should set up a board by issuing explicit Set Tile, Set Turn, Set Castle Perms, and Set En Passant operations, or by using a higher-level Set Board command that the engine layer decomposes into those operations. Board-controller reset should not be required to create a legal position.

## Hashing

Zobrist hashing is required in the final design. Tile, turn, castling, and en passant hash components should be updated incrementally as part of board operations.

Current RTL note: the board controller has placeholder 32-bit Zobrist constants but does not yet implement complete hash updates. The final design should use 64-bit hashes.

## Move History

Push Move writes enough data to reverse the move later, including origin, destination, captured piece, castling permissions, en passant state, halfmove clock, and special-move flag. Reverse Move reads the record for `thread_id` and `search_depth - 1`.

Each thread may have one reversible move per ply. Search must reverse all pushed moves before reusing that ply record for a different line.

## Current RTL Notes

The current RTL maintains `pst_eval` from the active-color perspective. The final design should change this to White-relative PST evaluation or perform an explicit conversion at this module boundary.
