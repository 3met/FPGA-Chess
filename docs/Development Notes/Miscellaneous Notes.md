# Miscellaneous Notes

### Things to Look Into
- Check if POSITIVE_DIAG/NEGATIVE_DIAG values are in the right order
- Change KnightBus.hasKing to hasKingOrQueen?
	- Both are good targets to attack with a knight (maybe rook too?)
- "Multi cycle paths" for propagation
- For `GET_MAX` operation in `adder_maximizer`, compare appending related data vs passing data on the side.
- Consider how to check if empty castle tile is safe during castling move generation.
- Add assertions to check that parameters are valid 


### Modules Hierarchy
- Main
	- rx_decode
	- tx_encode
	- Engine
		- Board MEM
		- Search Controller
			- Timer
			- Board
				- Board History
				- Tile\[64\]
				- Adder/Maximizer

- Main
	- rx_decode
	- tx_encode
	- Engine
		- Board MEM
		- 
		- Search Controller
			- Timer
		- Board
			- Board History
			- Tile\[64\]
			- Adder/Maximizer


### Short-Term TODO
- 


### Functionality to Test
- castling
- en passant
- check
- checkmate
- stalemate
- promotion


### Future Ideas
- Search Algorithm
	- Add PVS search
		- https://www.chessprogramming.org/Principal_Variation_Search
	- Add transposition table
	- Quiescence Search
	- Add 3-move repetition
	- Add 50-move draw
- Error Detection/Prevention
	- Add parity bit + stop bit checking
	- Log unknown op-codes
		- Clear on reset?
	- Log FIFO overflow
	- Enforce time limit on search
- Hardware Design
	- Add ability to write two pieces to PE array at once
		- Allows undo of capture in 1 cycle
	- Optimize hardware by specify `'dx` for output when tile is occupied by `"SPARE_PIECE"`
- Misc. Ideas
	- Add attacker priority 
	- Use 64ths of a pawn instead of centi-pawns in evaluation
		- https://ieeexplore.ieee.org/document/1302962
	- Play with number of bits in `tile_PE|attacker/defender_count`
	- Check if `set_good_cardinal_target` can be optimized
