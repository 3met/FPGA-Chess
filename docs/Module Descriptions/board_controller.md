# Board Controller
#### (`board_controller`)

| Direction | Port Name          | Description                                                                              |
| --------- | ------------------ | ---------------------------------------------------------------------------------------- |
| Input     | `clk`              | Clock.                                                                                   |
| Input     | `board_operation`  | Operation code for what the board should do. Port only read when `ready` is asserted.    |
| Input     | `board_tiles_in`   | 64 x 4 bit tiles.                                                                        |
| Input     | `turn_in`          | Indicates color of moving player.                                                        |
| Input     | `castle_perms_in`  | 4 bits of castling permissions.                                                          |
| Input     | `has_ep_in`        | Indicated whether the current board has an en passant tile.                              |
| Input     | `ep_file_in`       | File for which en passant exists if `has_ep` is true.                                    |
| Input     | `halfmove_clk_in`  | Number of half-moves for tracking 50-move draw.                                          |
| Input     | `board_hash_in`    | Initial hash of the board.                                                               |
| Input     | `pst_eval_in`      | The current piece-square table evaluation.                                               |
| Input     | `move`             | The move to be made.                                                                     |
| Input     | `data_in`          | Either a tile, turn, castle perms, or en passant info depending on the set operation.    |
| Input     | `thread_id`        | ID to indicate which board should be updated.                                            |
| Input     | `search_depth`     | The current search depth (before current operation).                                     |
| Output    | `board_tiles_out`  | 64 x 4 bit tiles.                                                                        |
| Output    | `turn_out`         | Indicates color of moving player.                                                        |
| Output    | `castle_perms_out` | 4 bits of castling permissions.                                                          |
| Output    | `has_ep_out`       | Indicated whether the current board has an en passant tile.                              |
| Output    | `ep_file_out`      | File for which en passant exists if `has_ep` is true.                                    |
| Output    | `halfmove_clk_out` | Number of half-moves for tracking 50-move draw.                                          |
| Output    | `board_hash_out`   | Updated hash of the board.                                                               |
| Output    | `pst_eval_out`     | A updated piece-square table evaluation. Evaluation is from perspective of active color. |


| Operation        | Inputs Required   | Description                                                  |
| ---------------- | ----------------- | ------------------------------------------------------------ |
| Push Move        | Move Data         | Makes a move as part of a search that can be later reversed. |
| Commit Move      | Move Data         | Makes a move to update the board outside a search.           |
| Set Tile         | Piece Data        | Places a piece (or `NULL_PIECE`) on the board.               |
| Set Turn         | Turn Data         | Updates the turn without changing the board,                 |
| Set Castle Perms | Castle Perm Data  | Updates the castling permissions without changing the board. |
| Set En Passant   | En Passant Data   | Update the en passant status without changing the board.     |
| Reverse Move     |                   | Reverses the previous move on the board.                     |
| Idle             |                   | Does nothing.                                                |


| Pipeline Stage | Description                                                                                                 |
| -------------- | ----------------------------------------------------------------------------------------------------------- |
| 0              | Register Inputs + Fetch previous move data                                                                  |
| 1              | Invert the PST score for operations that change the turn POV                                                |
| 2              | Idle?                                                                                                       |
| 3              | Compute updated board (update the primary moving tiles) + fetch Zobrist hash and piece-square table values. |
| 4              | Update first extra tile in the case of en-passant or castling + Write move record                           |
| 5              | Update second extra tile in the case of castling + Update PST score with killed piece                       |
| 6              | Output board data + Board Hash + PST Eval with new locations                                                |

**Note:** Zobrist hash is stored in a ROM (BRAM) with 32 bit keys and 24 bit overlap.

**Scenario: After power up, board to be set to starting position**
Toggle reset, which should set all tiles for all boards to `NULL_PIECE`. This should also reset the turn, castle perms, en passant info, board hash, and piece-square table evaluation. The pieces are then placed one by one on the board with the Set Tile operation. Next, the other board setup operations are executed. Finally the half move data can be written directly to the register file. At this point the piece-square table and board hash should be up-to-date.

**Scenario: Search is over and the board is to be overwritten with a new position**
The Set Tile is used to write all pieces (or `NULL_PIECE`) to the board one tile at a time. Everything else works like in normal startup.

**Scenario: Engine *is* in a search and needs to make a move***
Execute Push Move operation and store the move data within the pipeline. This move data must be reversed by the end of the search and before any set/place/commit command is executed.

**Scenario: Engine *is* in search and need to reverse a move***
For the Reverse Move operation, the engine reads the past move data from within the pipeline.

**Scenario: Engine is *not* in a search and needs to make a move***
Since we are not in search, the move is considered un-reversable. Use the Commit Move operation and the move data will not be saved in the pipeline.

---

### To Do:
- Add the Zobrist hashing
- Optimize the pipeline to only store the tiles for the starting and ending ranks
