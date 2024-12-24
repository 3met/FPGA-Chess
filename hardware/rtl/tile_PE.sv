
// By Emet Behrendt

import engine_defs::*;

// Package for definitions relating to the Tile PE
package tile_defs;
	
	import engine_defs::*;

	// -- Tile Connection Structs and Types --

	// Tile data format for inter-tile communication
	typedef struct packed {
		Tile tile;
		logic [2:0] distance;
	} AdjBusData;

	// -- Bus to Connect to 8 Knight-Connected Tiles --
	typedef struct packed {
		Color piece_color;
		logic has_knight;
		logic has_king_or_major;
	} KnightBusData;

	typedef struct packed {
		MovePriority move_priority;
	} MoveData;

	typedef logic [2:0] TileMoveScore;
	typedef logic signed [6:0] TileEvalScore; // Units of 64ths of a pawn

	localparam TileMoveScore NULL_MOVE_SCORE = TileMoveScore'('d0);

	// -- Define operation System for Individual Tiles --
	typedef enum {
		IDLE_TILE,
		PLACE_TILE,
		PLACE_MASK_AND_CLEAR_TILE,
		PLACE_AND_CLEAR_TILE,
		PLACE_RESET_MASK_AND_CLEAR_TILE,
		OUTPUT_SCORE_TILE,
		OUTPUT_BEST_MOVE_TILE
	} TileOp;

endpackage : tile_defs


import tile_defs::*;


// Module for a single tile PE
module tile
	#(parameter RANK=0, parameter FILE=0)
	(
		// Inputs from parent board shared by all tiles
		input  logic		clk,
		input  logic		rst_n,
		input  TileOp		operation,
		input  DepthType	search_depth,
		input  Tile			tile_wr_data,
		input  Color		turn,
		input  CastlePerms	castle_perms,  // Only used by some tiles
		input  logic		has_ep,        // Only used by some tiles
		input  BoardFile	ep_file,       // Only used by some tiles

		// Inputs from parent unique to each tile
		input  logic select_1,
		input  logic select_2,

		// Outputs to parent
		output logic         illegal_king_attack,
		output TileMoveScore move_score,
		output Direction     move_dir,
		output logic [2:0]   move_dist,
		output PromoType     promo_type,	// Only used by some tiles
		output TileEvalScore eval_score,	// represents the POV advantage for active player
		output Tile          tile_rd_data,

		// Inter-tile connections
		input  AdjBusData    adj_bus_in[8],
		output AdjBusData    adj_bus_out[8],
		input  KnightBusData knight_bus_in[8],
		output KnightBusData knight_bus_out
	);

	// ---- Fixed Tile Constants ----
	// Position of Tile
	localparam Position pos = Position'(6'd8*RANK + FILE);

	// Indicate a special tile
	localparam logic is_castle_tile     = (pos == 6'd4 || pos == 6'd60);
	localparam logic is_promo_tile      = (RANK == 0 || RANK == 7);
	localparam logic is_en_passant_tile = (RANK == 2 || RANK == 5);


	// ---- Intra-Tile Registers ----
	generate
		Tile occupant;

		reg adj_mask[MAX_DEPTH][8];
		reg knight_mask[MAX_DEPTH][8];
	endgenerate


	// ---- Intra-Tile Signals ----
	generate
		logic good_knight_target;
		logic good_cardinal_target;
		logic good_diag_target;
		PieceType weakest_attacker;
		PieceType weakest_defender;

		// Fewer bits for edge tiles
		localparam ATK_DEF_COUNT_WIDTH = (RANK==0 || RANK==7 || FILE==0 || FILE==7) ? 2 : 3;
		logic [ATK_DEF_COUNT_WIDTH-1:0] attacker_count;
		logic [ATK_DEF_COUNT_WIDTH-1:0] defender_count;

		logic has_attacker[7];     // Refers to unmasked attackers; index 0 is unused
		Direction attacker_dir[7]; // Refers to unmasked attackers; index 0 is unused
	endgenerate


	// --- Update occupant based on operation and tile_select_1/tile_select_2 ---
	always_ff @(posedge clk) begin
		if(~rst_n) begin
			occupant <= Tile'('dx);

		end else begin
			// Update tile when tile_select_1 is used
			if (select_1 && ~select_2) begin
				case (operation)
					PLACE_TILE                      : occupant <= tile_wr_data;
					PLACE_MASK_AND_CLEAR_TILE       : occupant <= tile_wr_data;
					PLACE_AND_CLEAR_TILE            : occupant <= tile_wr_data;
					PLACE_RESET_MASK_AND_CLEAR_TILE : occupant <= tile_wr_data;
					default                         : occupant <= occupant;
				endcase

			// Update tile when tile_select_2 is used
			end else if (~select_1 && select_2) begin
				case (operation)
					PLACE_TILE                      : occupant <= occupant;
					PLACE_MASK_AND_CLEAR_TILE       : occupant <= Tile'({1'dx, NULL_PIECE});
					PLACE_AND_CLEAR_TILE            : occupant <= Tile'({1'dx, NULL_PIECE});
					PLACE_RESET_MASK_AND_CLEAR_TILE : occupant <= Tile'({1'dx, NULL_PIECE});
					default                         : occupant <= occupant;
				endcase

			// Nothing changes if neither select is asserted
			end else if (~select_1 && ~select_2) begin
				occupant <= occupant;

			// Doesn't matter what happens when both selects are asserted
			// As this should never happen
			end else begin
				occupant <= Tile'(4'bx);
			end
		end
	end


	// --- Compute adj_bus_out and knight_bus_out ---
	always_comb begin
		for (int dir=0; dir<8; dir+=1) begin : set_adj_bus
			// - Empty tiles propagate inputs -
			if (occupant.piece_type==NULL_PIECE) begin
				adj_bus_out[dir].tile <= adj_bus_in[OPPOSITE_DIR[dir]].tile;
				adj_bus_out[dir].distance <= adj_bus_in[OPPOSITE_DIR[dir]].distance + 3'd1;

			// - Occupied tiles -
			end else begin
				adj_bus_out[dir].tile <= occupant;
				adj_bus_out[dir].distance <= 3'd1;
			end
		end

		knight_bus_out.piece_color       <= occupant.piece_color;
		knight_bus_out.has_knight        <= (occupant.piece_type==KNIGHT);
		knight_bus_out.has_king_or_major <= (   occupant.piece_type==KING
		                                     || occupant.piece_type==QUEEN
		                                     || occupant.piece_type==ROOK);
	end


	// --- Compute Tile Flags (good_knight_target, good_cardinal_target, good_diag_target) ---
	always_comb begin
		good_knight_target = 1'b0;
		for (int dir=0; dir<8; dir+=1) begin : set_good_knight_target
			good_knight_target |= (   knight_bus_in[dir].has_king_or_major
			                       && knight_bus_in[dir].piece_color == ~turn);
		end
		
		good_cardinal_target = 1'b0;
		good_diag_target = 1'b0;
		for (int i=0; i<4; i+=1) begin : set_good_cardinal_diag_target
			good_cardinal_target |= (adj_bus_in[CARDINAL_DIR[i]].tile == Tile'({~turn, KING}));
			good_cardinal_target |= (adj_bus_in[CARDINAL_DIR[i]].tile == Tile'({~turn, QUEEN}));

			good_diag_target |= (adj_bus_in[DIAG_DIR[i]].tile == Tile'({~turn, KING}));
			good_diag_target |= (adj_bus_in[DIAG_DIR[i]].tile == Tile'({~turn, QUEEN}));
			good_diag_target |= (adj_bus_in[DIAG_DIR[i]].tile == Tile'({~turn, ROOK}));
		end
	end

	// --- Compute weakest_attacker and weakest_defender --- 
	// --- Compute attacker_count and defender_count --- 
	// --- Compute has_attacker and attacker_dir --- 
	localparam Direction b_pawn_dir[2] = '{NORTH_WEST, NORTH_EAST};
	localparam Direction w_pawn_dir[2] = '{SOUTH_WEST, SOUTH_EAST};
	always_comb begin
		// Set default values
		weakest_attacker = KING;
		weakest_defender = KING;
		attacker_count = 'd0;
		defender_count = 'd0;
		for (int i=PAWN; i<=KING; i+=1) begin
			has_attacker[i] = 1'd0;
			attacker_dir[i] = Direction'('dx);
		end

		// - Update king, queen, rook, and bishop influences -
		for (int dir=0; dir<8; dir+=1) begin
			if (   (adj_bus_in[dir].tile.piece_type==QUEEN)
			    || (adj_bus_in[dir].tile.piece_type==ROOK && isDirCardinal(Direction'(dir)))
			    || (adj_bus_in[dir].tile.piece_type==BISHOP && isDirDiag(Direction'(dir)))
			    || (adj_bus_in[dir].tile.piece_type==KING && adj_bus_in[dir].distance==3'd1)) begin
				
				// Attackers
				if (adj_bus_in[dir].tile.piece_color==turn) begin
					attacker_count += 'd1;

					if (weakest_attacker > adj_bus_in[dir].tile.piece_type) begin
						weakest_attacker = adj_bus_in[dir].tile.piece_type;
					end

					if (adj_mask[search_depth][dir]) begin
						has_attacker[adj_bus_in[dir].tile.piece_type] = 1'b1;
						attacker_dir[adj_bus_in[dir].tile.piece_type] = Direction'(dir);
					end

				// Defenders
				end else begin
					defender_count += 'd1;

					if (weakest_defender > adj_bus_in[dir].tile.piece_type) begin
						weakest_defender = adj_bus_in[dir].tile.piece_type;
					end
				end
			end
		end


		// - Pawn Influences -
		// White pawn normal moves
		if (turn == WHITE && adj_bus_in[SOUTH].tile == Tile'({WHITE, PAWN}) && adj_mask[search_depth][SOUTH]) begin
			if (adj_bus_in[SOUTH].distance == 3'd1 || adj_bus_in[SOUTH].distance == 3'd2) begin
				has_attacker[PAWN] = 1'd1;
				attacker_dir[PAWN] = SOUTH;
			end
		end
		// Black pawn normal moves
		if (turn == BLACK && adj_bus_in[NORTH].tile == Tile'({BLACK, PAWN}) && adj_mask[search_depth][NORTH]) begin
			if (adj_bus_in[NORTH].distance == 3'd1 || adj_bus_in[NORTH].distance == 3'd2) begin
				has_attacker[PAWN] = 1'd1;
				attacker_dir[PAWN] = NORTH;
			end
		end
		for (int i=0; i<=1; i+=1) begin
			// White pawn diag attacks
			if (RANK>1 && adj_bus_in[w_pawn_dir[i]].tile == Tile'({WHITE, PAWN})
			    && adj_bus_in[w_pawn_dir[i]].distance == 3'd1) begin

				if (turn==WHITE) begin
					attacker_count += 'd1;
					weakest_attacker = PAWN;

					if (adj_mask[search_depth][w_pawn_dir[i]] && tile.occupant!=NULL_PIECE) begin
						has_attacker[PAWN] = 1'b1;
						attacker_dir[PAWN] = Direction'(w_pawn_dir[i]);
					end
				end else begin
					defender_count += 'd1;
					weakest_defender = PAWN;
				end
			end

			// Black pawn diag attacks
			if (RANK<6 && adj_bus_in[b_pawn_dir[i]].tile == Tile'({BLACK, PAWN})
			    && adj_bus_in[b_pawn_dir[i]].distance == 3'd1) begin

				if (turn==BLACK) begin
					attacker_count += 'd1;
					weakest_attacker = PAWN;

					if (adj_mask[search_depth][b_pawn_dir[i]] && tile.occupant!=NULL_PIECE) begin
						has_attacker[PAWN] = 1'b1;
						attacker_dir[PAWN] = Direction'(b_pawn_dir[i]);
					end
				end else begin
					defender_count += 'd1;
					weakest_defender = PAWN;
				end
			end
		end


		// - Knight Directions -
		for (int dir=0; dir<8; dir+=1) begin
			if (knight_bus_in[dir].has_knight) begin
				if (knight_bus_in[dir].piece_color == turn) begin
					weakest_attacker = (weakest_attacker > KNIGHT) ? KNIGHT : weakest_attacker;
					attacker_count += 'd1;

					if (knight_mask[search_depth][dir]) begin
						has_attacker[KNIGHT] = 1'b1;
						attacker_dir[KNIGHT] = Direction'(dir);
					end

				end else begin
					weakest_defender = (weakest_defender > KNIGHT) ? KNIGHT : weakest_defender;
					defender_count += 'd1;
				end
			end
		end
	end


	// --- Compute move_score, move_dir, move_dist --- 
	always_comb begin
		// NULL score if occupied by a friendly piece
		if (occupant.piece_color==turn && occupant.piece_type!=NULL_PIECE) begin
			move_score = NULL_MOVE_SCORE;
			move_dir = Direction'('dx);
			move_dist = 3'dx;

		// NULL score for no attackers and pawn moves
		end else if (   ~has_attacker[PAWN] && ~has_attacker[KNIGHT] && ~has_attacker[BISHOP]
		             && ~has_attacker[ROOK] && ~has_attacker[QUEEN] && ~has_attacker[KING]) begin
			move_score = NULL_MOVE_SCORE;
			move_dir = Direction'('dx);
			move_dist = 3'dx;

		// Normal move
		end else begin
			// Initial score set such that final scores is >0 (non-null)
			// and will never overflow given its size
			move_score = 3'd3;

			// - Score based on possible material trades -
			// Bonus for killing a more valuable piece
			if (PIECE_VALS_1[occupant.piece_type] > PIECE_VALS_1[weakest_attacker]) begin
				move_score += 3'd2;

			// Bonus for killing a piece of equal value when you have
			// attacker count advantage
			end else if (PIECE_VALS_1[occupant.piece_type] == PIECE_VALS_1[weakest_attacker]) begin
				if (attacker_count > defender_count) begin
					move_score += 3'd1;
				end

			// No kill or kill less valuable than attacker
			end else begin
				// Attacker advantage
				if (attacker_count > defender_count) begin
					if (defender_count == 3'd0) begin
						move_score += 3'd1;

					end else if (PIECE_VALS_1[weakest_defender] + PIECE_VALS_1[occupant.piece_type] < PIECE_VALS_1[weakest_attacker]) begin
						move_score -= 3'd1;
					end

				// And defender has advantage
				end else begin
					move_score -= 3'd2;
				end
			end

			// - Apply flags and choose attacker -
			// Go by flags if there are no defenders
			if (defender_count == 0) begin
				if (good_knight_target && has_attacker[KNIGHT]) begin
					move_dir = attacker_dir[KNIGHT];
					move_dist = 3'd0; // Distance is zero for knights
					move_score += 2;

				end else if (good_diag_target && has_attacker[BISHOP]) begin
					move_dir = attacker_dir[BISHOP];
					move_dist = adj_bus_in[move_dir].distance;
					move_score += 2;

				end else if (good_cardinal_target && has_attacker[ROOK]) begin
					move_dir = attacker_dir[ROOK];
					move_dist = adj_bus_in[move_dir].distance;
					move_score += 2;

				end else if (good_cardinal_target && has_attacker[QUEEN]) begin
					move_dir = attacker_dir[QUEEN];
					move_dist = adj_bus_in[move_dir].distance;
					move_score += 1;

				end else if (good_diag_target && has_attacker[QUEEN]) begin
					move_dir = attacker_dir[QUEEN];
					move_dist = adj_bus_in[move_dir].distance;
					move_score += 1;

				end else if (has_attacker[PAWN]) begin
					move_dir = attacker_dir[PAWN];
					move_dist = adj_bus_in[move_dir].distance;

				end else if (has_attacker[KNIGHT]) begin
					move_dir = attacker_dir[KNIGHT];
					move_dist = 3'd0; // Distance is zero for knights

				end else if (has_attacker[BISHOP]) begin
					move_dir = attacker_dir[BISHOP];
					move_dist = adj_bus_in[move_dir].distance;

				end else if (has_attacker[ROOK]) begin
					move_dir = attacker_dir[ROOK];
					move_dist = adj_bus_in[move_dir].distance;

				end else if (has_attacker[QUEEN]) begin
					move_dir = attacker_dir[QUEEN];
					move_dist = adj_bus_in[move_dir].distance;

				end else if (has_attacker[KING]) begin
					move_dir = attacker_dir[KING];
					move_dist = adj_bus_in[move_dir].distance;

				// Should never reach here
				end else begin
					move_dir = Direction'('dx);
					move_dist = 3'dx;
					move_score = TileMoveScore'('dx);
				end

			// If there are defenders, use weakest attacker
			end else begin
				// Special case to deal with pawn forward moves
				if (has_attacker[PAWN]) begin
					move_dir = attacker_dir[PAWN];
				end else begin
					move_dir = attacker_dir[weakest_attacker];
				end

				if (weakest_attacker == KNIGHT) begin
					move_dist = 3'd0; // Distance is zero for knights
				end else begin
					move_dist = adj_bus_in[move_dir].distance;
				end

				if (weakest_attacker == QUEEN && (good_diag_target || good_cardinal_target)) begin
					move_score += 1;
				end else if (weakest_attacker == KNIGHT && good_knight_target) begin
					move_score += 2;
				end else if (weakest_attacker == ROOK && good_cardinal_target) begin
					move_score += 2;
				end else if (weakest_attacker == BISHOP && good_diag_target) begin
					move_score += 2;
				end

				// Should never happen
				if (weakest_attacker == SPARE_PIECE || weakest_attacker == NULL_PIECE) begin
					move_dir = Direction'('dx);
					move_dist = 3'dx;
					move_score = TileMoveScore'('dx);
				end
			end
		end
	end


	// --- Compute adj_mask and knight_mask ---
	always_ff @(posedge clk) begin
		// Set masks to high on reset
		if (~rst_n) begin
			for (int d=0; d<MAX_DEPTH; d+=1) begin
				for (int dir=0; dir<8; dir+=1) begin
					adj_mask[d][dir] <= 1'b1;
					knight_mask[d][dir] <= 1'b1;
				end
			end

		// Disable current best move
		end else if (operation == PLACE_MASK_AND_CLEAR_TILE && select_1 == 1'b1) begin
			if (move_dist==0) knight_mask[search_depth][move_dir] <= 1'b0;
			else              adj_mask[search_depth][move_dir] <= 1'b0;

		// Re-enable all moves for current depth
		end else if (operation == PLACE_RESET_MASK_AND_CLEAR_TILE) begin
			for (int dir=0; dir<8; dir+=1) begin
				adj_mask[search_depth][dir] <= 1'b1;
				knight_mask[search_depth][dir] <= 1'b1;
			end
		end
	end


	// --- Compute eval_score ---
	// eval_score is measured in 64ths of a pawn
	// eval_score is signed and represents the POV advantage for active player 
	always_comb begin
		eval_score = 0;

		// -- Scoring that is inverted based on occupant color --
		// Score is initially calculated assuming a friendly occupant for side to play
		// Initial score is inverted if occupant not friendly

		// Bonus for rook on empty file
		if (   occupant.piece_type == ROOK
		    && adj_bus_in[NORTH].tile.piece_type == NULL_PIECE
		    && adj_bus_in[SOUTH].tile.piece_type == NULL_PIECE) begin

			eval_score += TileEvalScore'('d6);
		end

		// Invert if occupant not friendly
		if (occupant.piece_color == ~turn) begin
			eval_score = (~eval_score + TileEvalScore'('d1));
		end


		// Penalty for having more attackers than defenders
		// Remove since evaluations should be on quiet positions?
		if (   occupant.piece_type != NULL_PIECE
		    && occupant.piece_color != turn
		    && attacker_count > defender_count) begin
			
			eval_score += 'd13;
		end


		// For hardware optimization
		if (occupant.piece_type == SPARE_PIECE) begin
			eval_score = TileEvalScore'('dx);
		end
	end


	// --- Compute illegal_king_attack ---
	always_comb begin
		illegal_king_attack = 1'b0;

		if (occupant == Tile'({~turn, KING}) && attacker_count!=0) begin
			illegal_king_attack = 1'b1;
		end

		// Occupant should never be spare piece
		if (occupant.piece_type == SPARE_PIECE) begin
			illegal_king_attack = 1'bx;
		end
	end 


	assign tile_rd_data = occupant;

endmodule : tile
