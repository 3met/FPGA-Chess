# Move Generator (`move_generator`)

| Direction | Port Name         | Description                                                                                                             |
| --------- | ----------------- | ----------------------------------------------------------------------------------------------------------------------- |
| Input     | `clk`             |                                                                                                                         |
| Input     | `move_gen_op`     | The operation for the move generator to complete.                                                                       |
| Input     | `thread_id`       | ID to indicate thread for which moves are being generated. Required for tracking previously searched moves.             |
| Input     | `ply`             | Current ply of the search.                                                                                              |
| Input     | `board_tiles`     | 64 x 4 bit tiles.                                                                                                       |
| Input     | `turn`            | Indicates color of moving player.                                                                                       |
| Input     | `castle_perms`    | 4 bits of castling permissions.                                                                                         |
| Input     | `has_ep`          | Indicated whether the current board has an en passant tile.                                                             |
| Input     | `ep_file`         | File for which en passant exists if `has_ep` is true.                                                                   |
| Input     | `target_move`     | A move that will be assigned to `best_move` if legal.                                                                   |
| Output    | `best_move`       | The best pseudo-legal move for the given position. If no remaining (and unsearched) move exists, returns a `NULL_MOVE`. |
| Output    | `move_is_illegal` | Asserted if the generated move is illegal. In this case, pass the board through the pipeline again to get a new move.   |

### Operations

| Operation           | Inputs Required | Description                                                                                 |
| ------------------- | --------------- | ------------------------------------------------------------------------------------------- |
| Idle                |                 | Does nothing and doesn't update the internal state.                                         |
| Normal Generation   |                 | Generates the next move.                                                                    |
| Targeted Generation | Target Move     | Checks if the passed move is legal. If so return that move. Otherwise return the next move. |
| QSearch Generation  |                 | Generates the next move for a quiescence search scenario.                                   |


### Implementation

| Pipeline Stage | Description                                                                                             |
| -------------- | ------------------------------------------------------------------------------------------------------- |
| 0              | Register inputs + Begin load valid chunk list                                                           |
| 1              | Propagate + Update previous ply                                                                         |
| 2              | Propagate                                                                                               |
| 3              | Propagate pieces + Begin loading valid move chunks                                                      |
| 4-5            | Propagate                                                                                               |
| 6              | Finish propagation + Register valid move mask + Compute origin direction/distance of target move        |
| 7              | Compute best move on per-tile basis + Identify pinned piece axes                                        |
| 8              | Update score of target move to max if legal and unsearched                                              |
| 9              | Compute best move on board-wide basis                                                                   |
| 10             | Check if move legal and output best move + update best move to NULL if invalid + update/save board mask |
### Ordered Move Generation
**Move Generation Algorithm:**
- To generate a move, each tile on the board calculates the best move ending on said tile and gives it a score. The best move proposed by each tile is then sorted by score until the best move for the whole board can be found.
- Each tile module has information about the closest piece in each of the cardinal and diagonal directions as well as in the "knight directions".
- To calculate the score, we take into account:
	- Potential material trades based on tile occupant, number of attackers/defenders, and weakest attacker/defender.
	- Whether it would be a good target for cardinal-moving pieces, diagonal-moving pieces, or knights based on what can be attacked from the tile.
- Once a move is selected and searched, it can be blacklisted from future searches at that node

**Tile Flags**
- `good_knight_target`
	- True when king, queen, or rook is a knight move away
	- +2 for knights moving
- `good_cardinal_target`
	- True when king or queen is a rook move away
	- +2 for rooks
	- +1 for queens
- `good_diag_target`
	- True when king or queen or rook is a bishop move away
	- +2 for bishops
	- +1 for queens

```
// ----- Example Algorithm with White to Play -----

score = DEFAULT_SCORE

// Score Modification based on potential material trades
if (b_curr > w_weakest) {
	++ // Change in score
	
} else if (b_curr == w_weakest) {
	if (n_white > n_black) {
		+
	} else {
		~
	}
	
} else {
	if (n_white > n_black) {
		if (n_black == 0) {
			+
		} else if (b_curr+b_weakest > w_weakest) {
			~
		} else if (b_weakest+b_curr == w_weakest) {
			x // NOT POSSIBLE
		} else {
			-
		}
	} else {
		--
	}
}

calculate_flags()

selected_attacker = NULL_PIECE

// Choose attacking piece
if (n_black == 0) {
	if (goodKnightTarget and hasKnightAttacker)
		selected_attacker = first knight
		score += 2
	else if (goodDiagTarget and hasBishopAttacker)
		selected_attacker = first bishop
		score += 2
	else if (goodCardinalTarget and hasRookAttacker)
		selected_attacker = first rook
		score += 2
	else if (goodCardinalTarget and hasQueenAttacker)
		selected_attacker = first queen
		score += 1
	else if (goodDiagTarget and hasQueenAttacker)
		selected_attacker = first queen
		score += 1
	else
		selected_attacker = first piece

} else {
	selected_attacker = w_weakest

	if (w_weakest == queen and (goodDiagTarget or goodCardinalTarget))
		score += 1
	else if (w_weakest == knight and goodKnightTarget)
		score += 2
	else if (w_weakest == rook and goodCardinalTarget)
		score += 2
	else if (w_weakest == bishop and goodDiagTarget)
		score += 2
}
```

**Special Move Considerations:**
- Castling
	- Broadcast castling permissions (most tiles will ignore and optimize out)
	- Treat castling as a move by the king from the king's starting direction
- En-Passant
	- Send individual en passant status to each file
	- Mask like a normal pawn kill
- Pawn Promotion
	- Extra masks to keep track of pawn promotion types so far
	- Artificially lower move priority for non-queen promotions?

### Mask Memory Access
**Move History Storage:** Instead of storing each tile-direction pair, the engine stores one bit for each adjacent tile-tile connection for both directions. Instead of storing info about the whole board, only the chunks of the mask which are non-uniform get stored.

For a single thread, split moves into 8 different categories:
- North-South moves
- East-West moves
- Positive Diagonal moves
- Negative Diagonal moves
- Plus one category for each knight direction pair: NNE/SSW, NEE/SWW, SEE/NWW, SSE/NNW

The largest of these categories has $7\cdot8=56$ different moves and thus requires $56$ bits. Thus create $8$ mask memory blocks each $56$ bits wide with some depth of $D$.

Another memory block will exist to store pointers to each chunk/category of the mask memory. This memory block will have 8 pointers (one for each category) plus 8 more bits to indicate if the pointer NULL for each category.

The benefit here is that the memory block for each category can be shallower than the search depth as some depths are simply not indexed for a given category.

Another idea is to swap which block each category is stored in for a given ply to balance the amount in each block and prevent overfilling. 

The last thing that must be stored is the previous ply used for the move generator. If the current ply is less than or equal to the previous one, the current ply can be used to index the chunk memory. If the current ply is 1 higher than the previous ply, then we can read the previous ply and add 1 to the pointer where needed.


### Filtering Illegal Moves
**Moving a Pinned Piece**
Moving a pinned piece outside of the pin line is illegal as it puts the king in check. Therefore if a white occupied tile has an attacker in one direction and the white king in the other, it can only move towards the attacker or the king.

**King moves to an attacked square**
We can eliminate these moves early by nullifying the move priority if attacker count is greater than zero.

**King is already in Check (or Double Check)**
King tile outputs 

If the king is in double check (attacker count = 2), the only valid move is a king move. Therefore any move where the start position doesn't match the king tile counts as check.


### Startup/Reset Process

**Scenario: A typical normal generation operation**


