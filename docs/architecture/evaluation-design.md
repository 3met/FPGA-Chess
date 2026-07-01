# Static Evaluation

### Material Valuation

- Updated incrementally outside the non-incremental static evaluator.

### Piece-Square Tables

- Updated incrementally by the board-update pipeline.
- Keep track of the score in all game stages and interpolate between them after calculation
	- Consider polynomial interpolation?

### Board-State Evaluation

The static evaluator operates from board-state inputs. Evaluation terms may be computed with a PE-style internal array or other parallel per-square hardware, but the module interface should be a board-state pipeline interface and should not own the canonical board state.

- Pawn Structure
	- Pawn chain
	- Isolated/doubled pawns (parallel computation instead?)
	- [Connected pawn bonus](https://www.chessprogramming.org/Connected_Pawns)
	- [Minor piece in holes?](https://www.chessprogramming.org/Holes)
	- [Weak pawns?](https://www.chessprogramming.org/Weak_Pawns)
- Attacker/Defender count
	- Bonus for controlling center squares?
- King Safety
	- Bonus for nearby friendly pawns
	- Penalty for enemy pieces
	- Penalty for surrounding enemy-controlled tiles
- Positional
	- Rook on empty file
	- Trapped bishop

### Miscellaneous

- Increase value of rook with decreasing pawn count
- Decrease value of knight with decreasing pawn count
