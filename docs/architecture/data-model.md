# Data Model

This document defines common datatypes and constants shared by the hardware modules. The corresponding SystemVerilog package is `general_chess_defs` in `hardware/rtl/defs.sv`.

Unless otherwise stated, multi-bit scalar values are unsigned. Numeric enum values are assigned in declaration order starting at zero.

## Primitive Chess Types

### `Color`

| Value | Name    | Meaning |
| ----- | ------- | ------- |
| `0`   | `WHITE` | White piece or white side to move. |
| `1`   | `BLACK` | Black piece or black side to move. |
| `x`   | `UNKNOWN_COLOR` | Unknown or don't-care color. Used for empty tiles. |

### `PieceType`

`PieceType` is 3 bits wide.

| Value | Name          | Meaning |
| ----- | ------------- | ------- |
| `0`   | `NULL_PIECE`  | Empty tile. |
| `1`   | `PAWN`        | Pawn. |
| `2`   | `KNIGHT`      | Knight. |
| `3`   | `BISHOP`      | Bishop. |
| `4`   | `ROOK`        | Rook. |
| `5`   | `QUEEN`       | Queen. |
| `6`   | `KING`        | King. |
| `7`   | `SPARE_PIECE` | Reserved. Do not emit in normal board state. |
| `x`   | `UNKNOWN_PIECE` | Unknown or don't-care piece type. |

### `PromoType`

`PromoType` is 2 bits wide.

| Value | Name           | Promotion Piece |
| ----- | -------------- | --------------- |
| `0`   | `PROMO_QUEEN`  | Queen. |
| `1`   | `PROMO_KNIGHT` | Knight. |
| `2`   | `PROMO_ROOK`   | Rook. |
| `3`   | `PROMO_BISHOP` | Bishop. |
| `x`   | `PROMO_UNKNOWN` | Unknown or don't-care promotion piece. |

## Board Positioning

### `Position`

`Position` is 6 bits wide and indexes a square from `0` to `63`.

The current indexing convention is:

| Square | Position |
| ------ | -------- |
| `a1` | `0` |
| `b1` | `1` |
| `h1` | `7` |
| `a2` | `8` |
| `h8` | `63` |

In general:

```text
position = 8 * rank + file
file: a=0, b=1, ..., h=7
rank: rank 1=0, rank 2=1, ..., rank 8=7
```

### `BoardRank` and `BoardFile`

Both are 3 bits wide.

| Type | Meaning |
| ---- | ------- |
| `BoardRank` | Rank index from `0` for rank 1 through `7` for rank 8. |
| `BoardFile` | File index from `0` for file a through `7` for file h. |

The helper functions `getRank`, `getFile`, and `getPosition` should follow the same convention.

### Display Order

`SHOW_ORDER` lists positions in human board-display order from `a8` through `h1`. This is useful for debug output and displays, not for core board storage.

## Packed Structs

### `Tile`

`Tile` is a 4-bit packed struct.

| Bits | Field | Meaning |
| ---- | ----- | ------- |
| `3` | `piece_color` | `0` for white, `1` for black. Ignored for `NULL_PIECE`. |
| `2:0` | `piece_type` | Piece type using the `PieceType` encoding. |

Common tile constants:

| Name | Encoding | Meaning |
| ---- | -------- | ------- |
| `EMPTY_TILE` | `{UNKNOWN_COLOR, NULL_PIECE}` | Empty square. |
| `WHITE_PAWN` through `WHITE_KING` | `{WHITE, piece}` | White pieces. |
| `BLACK_PAWN` through `BLACK_KING` | `{BLACK, piece}` | Black pieces. |

### `Move`

`Move` is a 14-bit packed struct.

| Bits | Field | Meaning |
| ---- | ----- | ------- |
| `13:8` | `start_pos` | Origin square. |
| `7:2` | `end_pos` | Destination square. |
| `1:0` | `promo_piece` | Promotion piece if the move promotes. Otherwise don't-care. |

`NULL_MOVE` is encoded as `{start_pos=0, end_pos=0, promo_piece=x}`.

### `CastlePerms`

`CastlePerms` is a 4-bit packed struct.

| Bit | Field | Meaning |
| --- | ----- | ------- |
| `3` | `whiteKingside` | White can castle king-side. |
| `2` | `whiteQueenside` | White can castle queen-side. |
| `1` | `blackKingside` | Black can castle king-side. |
| `0` | `blackQueenside` | Black can castle queen-side. |

When serialized outside SystemVerilog structs, use the order `{whiteKingside, whiteQueenside, blackKingside, blackQueenside}` unless a module-specific interface explicitly documents a different bit order.

### En Passant State

The canonical internal representation is two fields:

| Field | Width | Meaning |
| ----- | ----- | ------- |
| `has_ep` | 1 bit | Current position has an en passant target file. |
| `ep_file` | 3 bits | Target file if `has_ep` is asserted. |

When serialized into a 4-bit field, use `{ep_file[2:0], has_ep}` so bit `0` is the valid bit and bits `3:1` are the file. This matches the newer `board_controller` set-data interface.

### `FullBoard`

`FullBoard` is the complete board state needed by stateless board-processing pipelines.

| Field | Width | Meaning |
| ----- | ----- | ------- |
| `tiles` | `64 * 4` | Board tiles indexed by `Position`. |
| `turn` | 1 | Side to move. |
| `castle_perms` | 4 | Castling permissions. |
| `has_ep` | 1 | Whether en passant is available. |
| `ep_file` | 3 | En passant file if available. |
| `halfmove_clk` | 7 | Halfmove clock for the 50-move rule. |

The total packed width is 272 bits.

`FullBoard` does not include the fullmove number, board hash, PST score, search history, or repetition history. Those values are tracked separately when needed.

## Search, Evaluation, and Metric Types

### Search Depth

| Name | Value | Description |
| ---- | ----- | ----------- |
| `MAX_PLY_COUNT` | `32` | Maximum number of plies tracked by search-depth-indexed structures. |
| `DepthType` | `log2(MAX_PLY_COUNT)` bits | Search ply/depth index. Currently 5 bits. |

### Evaluation Scores

`EvalScore` is a signed 16-bit value. Positive scores are good for the side specified by the module using the score. Module docs must state whether a score is from White's perspective or the side-to-move perspective.

| Name | Value | Description |
| ---- | ----- | ----------- |
| `MAX_EVAL_SCORE` | `32767` | Maximum finite evaluation. |
| `MIN_EVAL_SCORE` | `-32767` | Minimum finite evaluation. |
| `DRAW_EVAL_SCORE` | `0` | Drawn/equal evaluation. |
| `UNKNOWN_EVAL_SCORE` | `x` | Unknown evaluation. |

Material values are available in two forms:

| Array | Unit | Values by piece type |
| ----- | ---- | -------------------- |
| `PIECE_VALS_1` | Pawns | null `0`, pawn `1`, knight `3`, bishop `3`, rook `5`, queen `9`, king `0`, spare `x`. |
| `PIECE_VALS_128` | 1/128 pawn | null `0`, pawn `128`, knight `416`, bishop `416`, rook `640`, queen `1152`, king `0`, spare `x`. |

### Time and Node Counts

| Name | Value | Description |
| ---- | ----- | ----------- |
| `TIME_BITS` | `24` | Number of bits used to store milliseconds. Maximum representable duration is `16,777,215 ms`, about 4.66 hours. |
| `TimeType` | `24` bits | Time value in milliseconds. |
| `NODE_COUNT_BITS` | `40` | Number of bits used to count searched nodes. |
| `NodeCountType` | `40` bits | Node count value. |

### Hashes and Threads

| Name | Value | Description |
| ---- | ----- | ----------- |
| `BoardHash` | `32` bits | Zobrist-style board hash value. |
| `THREAD_COUNT` | Parameter | Number of hardware search threads. The target design range is roughly 15-30 threads. |
| `THREAD_ID_BITS` | `max(1, clog2(THREAD_COUNT))` | Width of `ThreadID`. Kept at least 1 bit even when `THREAD_COUNT` is 1. |
| `ThreadID` | `THREAD_ID_BITS` bits | Hardware search thread identifier. |

## Directions

### `Direction`

`Direction` is 3 bits wide.

| Value | Name | Position Delta |
| ----- | ---- | -------------- |
| `0` | `NORTH` | `+8` |
| `1` | `NORTH_EAST` | `+9` |
| `2` | `EAST` | `+1` |
| `3` | `SOUTH_EAST` | `-7` |
| `4` | `SOUTH` | `-8` |
| `5` | `SOUTH_WEST` | `-9` |
| `6` | `WEST` | `-1` |
| `7` | `NORTH_WEST` | `+7` |

`POS_SHIFT[direction]` gives the one-square position delta. `DIST_SHIFT` extends that to distances from `0` through `7`, where distance `0` is always zero.

### `KnightDirection`

`KnightDirection` is 3 bits wide.

| Value | Name | Position Delta |
| ----- | ---- | -------------- |
| `0` | `NNE` | `+17` |
| `1` | `NEE` | `+10` |
| `2` | `SEE` | `-6` |
| `3` | `SSE` | `-15` |
| `4` | `SSW` | `-17` |
| `5` | `SWW` | `-10` |
| `6` | `NWW` | `+6` |
| `7` | `NNW` | `+15` |
