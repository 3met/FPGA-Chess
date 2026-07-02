# Binary Encoding

This file defines byte and bit encodings used by the host-FPGA protocol. Multi-byte integers are little-endian unless a table explicitly says otherwise.

## Tile Data Encoding

`Tile` is encoded in 4 bits.

| Bits | Field | Meaning |
| ---- | ----- | ------- |
| `2:0` | `piece_type` | `0` empty, `1` pawn, `2` knight, `3` bishop, `4` rook, `5` queen, `6` king, `7` reserved. |
| `3` | `piece_color` | `0` White, `1` Black. Ignored for empty tiles. |

When two tiles are packed into one byte, the lower nibble stores the lower-numbered board position and the upper nibble stores the next position.

## Board Position Encoding

Board positions use the shared internal convention from [data-model.md](../architecture/data-model.md): `a1 = 0`, `b1 = 1`, `h1 = 7`, `a2 = 8`, and `h8 = 63`.

## Move Encoding

`Move` is encoded as 2 bytes. Bits `15:14` are reserved and must be transmitted as zero.

Canonical byte-level layout:

| Byte | Bits | Meaning |
| ---- | ---- | ------- |
| `0` | `1:0` | Promotion piece: `0` queen, `1` knight, `2` rook, `3` bishop. |
| `0` | `7:2` | Destination position. |
| `1` | `5:0` | Origin position. |
| `1` | `7:6` | Reserved, transmit as zero. |

`NULL_MOVE` is origin `0`, destination `0`, and promotion bits ignored.

## Castling Encoding

Castling permissions are encoded in a 4-bit field.

| Bit | Meaning |
| --- | ------- |
| `3` | White king-side castling is available. |
| `2` | White queen-side castling is available. |
| `1` | Black king-side castling is available. |
| `0` | Black queen-side castling is available. |

## En Passant Encoding

En passant is encoded in a 4-bit field as `{ep_file[2:0], has_ep}`.

| Bits | Meaning |
| ---- | ------- |
| `0` | En passant target file is valid. |
| `3:1` | Target file, with `a = 0` and `h = 7`. |

## FullBoard Encoding

`FullBoard` command payloads use 36 bytes. The byte-aligned format is intentionally simple for the engine command layer to parse.

| Bytes | Meaning |
| ----- | ------- |
| `0..31` | Packed tiles. Byte `i` low nibble is position `2*i`; byte `i` high nibble is position `2*i+1`. |
| `32` | Castling permissions in bits `3:0`; bits `7:4` reserved zero. |
| `33` | En passant field in bits `3:0`; bits `7:4` reserved zero. |
| `34` | Turn in bit `0`, where `0` is White and `1` is Black; bits `7:1` reserved zero. |
| `35` | Halfmove clock in bits `6:0`; bit `7` reserved zero. |

The fullmove number is not stored in `FullBoard` and is not sent to the FPGA.

## Time and Node Count Encoding

`TimeType` is a 24-bit unsigned millisecond value and is encoded as 3 little-endian bytes.

`NodeCountType` is a 40-bit unsigned value and is encoded as 5 little-endian bytes.
