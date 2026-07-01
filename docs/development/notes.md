# Miscellaneous Notes

### Things to Look Into
- Check if POSITIVE_DIAG/NEGATIVE_DIAG values are in the right order
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
			- Board Controller
			- Move Generator
			- Static Evaluator


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
	- [Add PVS search](https://www.chessprogramming.org/Principal_Variation_Search)
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
	- Optimize hardware by specify `'dx` for output when tile is occupied by `"SPARE_PIECE"`
- Misc. Ideas
	- Add attacker priority 
	- [Use 64ths of a pawn instead of centi-pawns in evaluation](https://ieeexplore.ieee.org/document/1302962)
