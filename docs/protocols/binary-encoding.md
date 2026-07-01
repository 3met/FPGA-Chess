# Binary Encoding

This file contains information about how various data types are encoded.

### Tile Data Encoding

| Bit Index | Information Stored                                                                                                                                                       |
| --------- | ------------------------------------------------------------------------------------------------------------------------------------------------------------------------ |
| 0 - 2     | Piece type on the tile. A zero means the tile is empty. A one means pawn, two means knight, up to six meaning king. A value of seven is reserved and should not be used. |
| 3         | Store color of piece. Zero for white, one for black. Color does not matter for empty tiles.                                                                              |
### Board Position Encoding

