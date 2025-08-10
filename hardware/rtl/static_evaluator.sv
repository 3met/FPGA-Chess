
package static_evaluator_defs;

	import general_chess_defs::*;

	// -- Bus to Connect to 8 Knight-Connected Tiles --
	typedef struct packed {
		Color piece_color;
		logic has_knight;
		logic has_king_or_major;
	} KnightBusData;

	localparam TileMoveScore NULL_MOVE_SCORE = TileMoveScore'('d0);

	localparam delay; // Cycles until the evaluation is complete (pipeline stages)

	// -- Define operation System for Individual Tiles --
	// typedef enum {
	// 	IDLE_TILE,
	// 	PLACE_TILE,
	// 	PLACE_MASK_AND_CLEAR_TILE,
	// 	PLACE_AND_CLEAR_TILE,
	// 	PLACE_RESET_MASK_AND_CLEAR_TILE,
	// 	OUTPUT_SCORE_TILE,
	// 	OUTPUT_BEST_MOVE_TILE
	// } StaticEvalOp;
endpackage : static_evaluator_defs


import static_evaluator_defs::*;


module static_evaluator (
	input clk,
	input Tile board_tiles[64],
	output EvalScore static_eval, // evaluation relative to WHITE player
);
	// The score after a given layer and the change in score for a given layer
	EvalScore eval_pipeline[7];        // Indexed like [layer]
	EvalScore eval_pipeline_change[7]; // Indexed like [layer]

	Tile board_pipeline[7][64];        // Indexed like [layer][position]
	Tile cardinal_piece[7][64][8];     // Indexed like [layer][position][direction]
	reg [2:0] cardinal_dist[76][64][8]; // Indexed like [layer][position][direction]

	always_ff @(posedge clk) begin

		// ========== Pass Systolic Array Data ==========

		for (int pos=0; pos < 64; pos++) begin
			localparam RANK = getRank(pos);
			localparam FILE = getFile(pos);

			for (int layer=0; layer < 7; layer++) begin
				// Copy the board down pipeline
				board_pipeline[layer] <= (layer==0 ? board_tiles : board_pipeline[layer-1];

				for (int dir=0; dir < 8; dir++) begin
					// Xs by default for first layer, copy previous value for later layers
					cardinal_piece[layer][pos][dir] = (layer==0 ? UNKNOWN_PIECE : cardinal_piece[layer-1][pos][dir]);
					cardinal_dist[layer][pos][dir] = (layer==0 ? 3'dx : cardinal_dist[layer-1][pos][dir]);

					// TODO: Optimize such that pawns cannot be cardinal pieces from the first and last rank

					// Check directly next to edge of board
					if (!isShiftOnBoard(pos, dir, 1)) begin
						cardinal_piece[layer][pos][dir] = NULL_PIECE; // TODO: ensure this does not actually synthesize a register
						cardinal_dist[layer][pos][dir] = 3'd0;

					// Check for special first comparison
					end else if (layer == 0 && !isShiftOnBoard(pos, dir, 2)) begin
						cardinal_piece[layer][pos][dir] = board_pipeline[layer][shiftPos(pos, dir, 1)]; // TODO: Optimize this? It just duplicates a register
						cardinal_dist[layer][pos][dir] = (board_pipeline[layer][shiftPos(pos, dir, 1)].piece_type == NULL_PIECE ? 3'd1 : 3'd0);

					// Otherwise compare only as late as possible to avoid duplicate comparisons
					end else if (layer > 0 && isShiftOnBoard(pos, dir, 2+layer-1) && !isShiftOnBoard(pos, dir, 2+layer)) begin
						// If no piece exists, relay previous signal
						if (board_pipeline[layer][shiftPos(pos, dir, 1)].piece_type == NULL_PIECE) begin
							cardinal_piece[layer][pos][dir] = cardinal_piece[layer][shiftPos(pos, dir, 1)][dir];
							cardinal_dist[layer][pos][dir] = cardinal_dist[layer][shiftPos(pos, dir, 1)][dir] + 3'd1;
						// else piece exists, so relay that piece
						end else begin
							cardinal_piece[layer][pos][dir] = board_pipeline[layer][shiftPos(pos, dir, 1)];
							cardinal_dist[layer][pos][dir] = 3'd0;
						end
					end
				end
			end
		end

		// Move evaluation down the pipeline
		eval_pipeline[0] <= DRAW_EVAL_SCORE;
		for (int layer=1; layer < 7; layer++) begin
			eval_pipeline[layer] <= eval_pipeline[layer-1] + eval_pipeline_change[layer];
		end

		// Set output
		static_eval <= eval_pipeline[6]
	end



	// ========== Compute Output Score ==========

	always_comb begin
		// Move evaluation down the pipeline
		eval_pipeline_change[0] = UNKNOWN_EVAL_SCORE; // Unused
		for (int layer=1; layer < 7; layer++) begin
			eval_pipeline_change = 0;
		end

		// Get score contrib from each tile
		for (int pos=0; pos < 64; pos++) begin
			localparam RANK = getRank(pos);
			localparam FILE = getFile(pos);

			for (int layer=0; layer < 7; layer++) begin
				localparam Tile occupant = board_pipeline[layer][pos];
				localparam Tile curr_piece_result = cardinal_piece[layer][pos];
				localparam logic [2:0] curr_dist_result = cardinal_dist[layer][pos];

				// Assert a Pawn is never on the first or last rank
				if (RANK == 0 || RANK == 7) begin
					assert(occupant.piece_type !== PAWN) else $fatal("Pawn on first/last rank!");

					if (occupant.piece_type == PAWN) begin
						eval_pipeline_change[layer] = UNKNOWN_EVAL_SCORE;
					end
				end

				// Assert that Kings never touch
				if (occupant.piece_type == KING) begin
					for (int dir=0; dir < 8; dir++) begin
						if (curr_piece_result[dir]==KING && curr_dist_result[dir]==3'd0) begin
							$fatal("King Attacking King!");
							eval_pipeline_change[layer] = UNKNOWN_EVAL_SCORE;
						end
					end
				end

				// Assert that SPARE_PIECE type is not used
				if (occupant.piece_type == SPARE_PIECE) begin
					$fatal("Unknown \"SPARE_PIECE\" found...");
					eval_pipeline_change[layer] = UNKNOWN_EVAL_SCORE;
				end

				// TODO: Evaluate certain tiles at earlier layers to save resources

				if (layer == 6) begin
					// Bonus for pawns near king
					if (occupant.piece_type == KING) begin
						for (int dir=0; dir < 8; dir++) begin
							if (curr_piece_result[dir] == Tile'({PAWN, occupant.piece_color}) && curr_dist_result[dir] < 2) begin
								eval_pipeline_change[layer] += (occupant.piece_color==WHITE ? EvalScore'('d4): EvalScore'(-'d4));
							end
						end
					end

					// Penalty for trapped bishop		
					if (occupant.piece_type == BISHOP) begin
						if (   curr_dist_result[NORTH_EAST] == 3'd0
						    && curr_dist_result[SOUTH_EAST] == 3'd0
						    && curr_dist_result[SOUTH_WEST] == 3'd0
						    && curr_dist_result[NORTH_WEST] == 3'd0) begin

							eval_pipeline_change[layer] += (occupant.piece_color==WHITE ? EvalScore'(-'d4) : EvalScore'('d4));
						end
					end

					// Bonus for rook on fully-open file
					if (   occupant.piece_type == ROOK
					    && curr_piece_result[NORTH].piece_type == NULL_PIECE
					    && curr_piece_result[SOUTH].piece_type == NULL_PIECE) begin

						eval_pipeline_change[layer] += (occupant.piece_color==WHITE ? EvalScore'('d6) : EvalScore'(-'d6));
					end

					// Penalty for doubled pawns
					if (RANK != 6 && occupant.piece_type == PAWN
					    && curr_piece_result[NORTH] == Tile'({occupant.piece_color, PAWN})) begin

						eval_pipeline_change[layer] += (occupant.piece_color==WHITE ? EvalScore'(-'d6) : EvalScore'('d6));
					end

					// Mobility bonus
					if (occupant.piece_type == ROOK || occupant.piece_type == QUEEN) begin
						for (int dir=0; dir < 4; dir++) begin
							eval_pipeline_change[layer] += (occupant.piece_color==WHITE ? curr_dist_result[CARDINAL_DIR[dir]] : -curr_dist_result[CARDINAL_DIR[dir]]);
						end
					end
					if (occupant.piece_type == BISHOP || occupant.piece_type == QUEEN) begin
						for (int dir=0; dir < 4; dir++) begin
							eval_pipeline_change[layer] += (occupant.piece_color==WHITE ? curr_dist_result[DIAG_DIR[dir]] : -curr_dist_result[DIAG_DIR[dir]]);
						end
					end

					// Material Bonus
					// TODO: seperate evaluation would be much better
					eval_pipeline_change[layer] += (occupant.piece_color==WHITE ? PIECE_VALS_64[occupant.piece_type] : -PIECE_VALS_64[occupant.piece_type]);
				end
			end
		end
	end // always_comb


endmodule : static_evaluator

