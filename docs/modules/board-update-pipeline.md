# Board Update Pipeline (`board_update_pipeline`)

The board update pipeline is a pipelined board-state transformer. It accepts a complete `FullBoard`, side data, and an operation, then outputs the transformed board and updated side data after fixed latency. It does not own long-term active board state.

## Ports

| Direction | Port Name | Description |
| --------- | --------- | ----------- |
| Input | `clk` | Clock. |
| Input | `board_op` | Operation code for what the board update pipeline should do. |
| Input | `board_in` | Input `FullBoard` state. |
| Input | `zobrist_key_in` | Input Zobrist key for the board position. |
| Input | `pst_eval_in` | Current White-relative piece-square-table evaluation. |
| Input | `piece_count_in` | Current total number of occupied squares, from 0 through 32. |
| Input | `move_in` | Move to apply for push/commit operations, or destination square for set-tile operations. |
| Input | `set_data` | Tile, turn, castle perms, en passant info, or halfmove clock depending on the set operation. This signal is 7 bits wide; narrow setup values use the low bits. |
| Input | `thread_id` | Search thread whose move-history record should be read or written. |
| Input | `search_ply` | Search ply before the current operation. |
| Output | `board_out` | Output `FullBoard` state. |
| Output | `zobrist_key_out` | Updated Zobrist key for the board position. |
| Output | `pst_eval_out` | Updated White-relative PST evaluation. |
| Output | `piece_count_out` | Updated total number of occupied squares. |
| Output | `mover_in_check_out` | For push operations, indicates that the resulting position attacks the king of the side that moved. |

## Operations

| Operation | Inputs Required | Description |
| --------- | --------------- | ----------- |
| Push Move | `move_in` | Makes a reversible search move and writes a move-history record. |
| Push Null | None | Makes a reversible synthetic search null move, toggling the turn, clearing en passant, and incrementing the halfmove clock without changing tiles, castling permissions, or evaluation. |
| Commit Move | `move_in` | Makes an irreversible active-game move without writing a search move-history record. |
| Set Tile | `move_in.to_pos`, `set_data` tile | Places a piece or `NULL_PIECE` on one square. |
| Set Turn | `set_data[0]` | Updates the side to move without changing tiles. |
| Set Castle Perms | `set_data[3:0]` | Updates castling permissions without changing tiles. |
| Set En Passant | `{ep_file[2:0], has_ep}` | Updates en passant state without changing tiles. |
| Set Halfmove Clock | `set_data[6:0]` | Updates the 50-move-rule halfmove clock without changing tiles. |
| Reverse Move | `thread_id`, `search_ply` | Reverses the previous pushed move for the thread. |
| Idle | None | Does nothing. |

## Pipeline

| Pipeline Stage | Description                                                               |
| -------------- | ------------------------------------------------------------------------- |
| 0              | Register inputs, select the mover's tracked post-move king square, fetch reverse history, decode move effects, and launch table reads. |
| 1              | Align synchronous table outputs with the registered request and decoded effects, and evaluate push-move king safety. |
| 2              | Apply tile, side-data, Zobrist, and PST updates, register outputs including push legality, and write pushed move history. |

## Board Setup

The engine sets up a board through Set Tile, Set Turn, Set Castle Perms, Set En Passant, and Set Halfmove Clock operations. The external Set Board command is decomposed into those operations by the engine layer. Reset is not used to create a position.

## Hashing

Tile, turn, castling, and en passant components of the 64-bit Zobrist key are updated incrementally for every board operation. The deterministic generator produces the ROM data and SystemVerilog reference package used by RTL; pawn entries on unreachable ranks are zero.

The pipeline always maintains the cached king squares, Zobrist key, incremental material/PST evaluation, and six-bit piece count. The shared tile-replacement path increments the count only for empty-to-piece changes and decrements it only for piece-to-empty changes, so ordinary captures, en passant, setup, and reversal need no board scan. Set Tile derives king squares during position setup; king moves and their reversals update the applicable square through the same tile-replacement path.

## PST Tables

Material and piece-square parameters are maintained in `hardware/data/pst_values/pst_values.json`. Generation produces the ROM data and material definitions consumed by RTL. PST entries are sign-extended to `EvalScore` before being applied, so table storage width does not narrow the accumulated score.

## Move History

Push Move records the move effects and previous side data needed to reverse it. Push Null uses a reserved history encoding and records the same restorable side data. Reverse Move reads the prior ply record for the selected thread and restores either operation.

Each thread may have one reversible move per ply. Search must reverse accepted pushed moves before reusing that ply record for a different line. A speculative push rejected for leaving the moving king in check is never accepted as thread state; its record may be overwritten by the next candidate at the same ply.
