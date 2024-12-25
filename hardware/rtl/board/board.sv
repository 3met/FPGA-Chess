
// By Emet Behrendt

// This file has the implementation of the board abstraction.
// The board uses 64 tile modules.

import engine_defs::*;
import tile_defs::*;
import adder_maximizer_defs::*;
import board_hist_defs::*;

// Package for definitions relating to the board
package board_defs;

	// -- Define Board Operations -- 
	typedef enum {
		BOARD_IDLE_OP,
		BOARD_PLACE_PIECE_OP,
		BOARD_MAKE_MOVE_OP,
		BOARD_REVERSE_MOVE_OP,
		BOARD_GET_BEST_MOVE_OP,
		BOARD_GET_BOARD_SCORE_OP,
		BOARD_GET_TILE_OCCUPANCY_OP,
		BOARD_WRITE_TURN_OP,
		BOARD_WRITE_CASTLE_OP,
		BOARD_WRITE_EN_PASSANT_OP,
		BOARD_WRITE_LSB_HM_CLOCK_OP,
		BOARD_WRITE_MSB_HM_CLOCK_OP,
		BOARD_READ_TURN_OP,
		BOARD_READ_CASTLE_OP,
		BOARD_READ_EN_PASSANT_OP,
		BOARD_READ_LSB_HM_CLOCK_OP,
		BOARD_READ_MSB_HM_CLOCK_OP
	} BoardOp;

	// Datatype 
	typedef logic signed [8:0] BoardEvalScore;

endpackage : board_defs


import board_defs::*;


module board (
		input wire clk,
		input wire rst_n,
		input BoardOp board_operation,
		input wire [3:0] data_in,
		input Move move_in,
		input wire in_search,
		output logic ready,
		output logic illegal_board,
		output Move best_move,
		output BoardEvalScore board_score,
		output logic[3:0] data_out
	);


	// --- Helper Functions ---
	// Returns max of two values
	function int max(int a, int b);
		return (a > b) ? a : b;
	endfunction : max


	// --- Enum for Internal Board States ---
	typedef enum {
		IDLE_BOARD_STATE,
		PLACE_PIECE_STATE,
		MAKE_MOVE_STATE[3],
		REVERSE_MOVE_STATE[3],
		GET_BEST_MOVE_STATE,
		GET_BOARD_SCORE_STATE,
		GET_TILE_OCCUPANCY_STATE,
		WRITE_TURN_STATE,
		WRITE_CASTLE_STATE,
		WRITE_EN_PASSANT_STATE,
		WRITE_LSB_HM_CLOCK_STATE,
		WRITE_MSB_HM_CLOCK_STATE,
		READ_TURN_STATE,
		READ_CASTLE_STATE,
		READ_EN_PASSANT_STATE,
		READ_LSB_HM_CLOCK_STATE,
		READ_MSB_HM_CLOCK_STATE
	} BoardState;


	// ---- Internal Board Registers ----
	logic [3:0] data_in_buffer;
	Move		move_buffer;
	reg         in_search_buffer;
	BoardState	state;
	Color		turn;
	CastlePerms	castle_perms;
	reg			has_ep;	// Has En Passant
	BoardFile	ep_file;
	reg [6:0]	halfmove_clock;
	DepthType	search_depth;


	// ---- Internal Board Signals ----
	TileOp tile_op;
	logic illegal_tile[64];

	// Tile Selects
	Position select_1, select_2;
	
	// Move Signals
	TileMoveScore tile_move_score[64];
	Direction     tile_move_dir[64];
	logic [2:0]   tile_move_dist[64];
	PromoType     tile_promo_type[64];

	// Eval Signals
	TileEvalScore tile_eval_score[64];

	// Tile Data
	Tile tile_wr_data;
	Tile tile_rd_data[64];

	// Tile interconnecting
	AdjBusData adj_bus_out[64][8];
	AdjBusData adj_bus_in[64][8];
	KnightBusData knight_bus_out[64];
	KnightBusData knight_bus_in[64][8];

	// Move Information
	logic move_is_kill;
	logic move_is_en_passant;
	logic move_is_castle;
	logic move_is_promotion;


	// --- Generate Tile Array ---
	generate
		for (genvar pos=0; pos<64; pos+=1) begin : board_gen_tiles
			tile #(.RANK(pos[5:3]), .FILE(pos[2:0])) tile_PE (
				.clk(clk),
				.rst_n(rst_n),
				.operation(tile_op),
				.search_depth(search_depth),
				.tile_wr_data(tile_wr_data),
				.turn(turn),
				.castle_perms(castle_perms),
				.has_ep(has_ep),
				.ep_file(ep_file),
				.select_1(select_1 == pos),
				.select_2(select_2 == pos),
				.illegal_king_attack(illegal_tile[pos]),
				.move_score(tile_move_score[pos]),
				.move_dir(tile_move_dir[pos]),
				.move_dist(tile_move_dist[pos]),
				.promo_type(tile_promo_type[pos]),
				.eval_score(tile_eval_score[pos]),
				.tile_rd_data(tile_rd_data[pos]),
				.adj_bus_in(adj_bus_in[pos]),
				.adj_bus_out(adj_bus_out[pos]),
				.knight_bus_in(knight_bus_in[pos]),
				.knight_bus_out(knight_bus_out[pos])
			);
		end
	endgenerate


	// --- Instantiate adder_maximizer ---
	// Add-Max module Signals
	AddMaxOp add_max_op;
	logic signed [max($bits(TileMoveScore), $bits(TileEvalScore))-1:0] add_max_key_in[64];
	Position add_max_data_in[64];
	logic [max($bits(TileMoveScore), $bits(BoardEvalScore))-1:0] add_max_key_out;
	Position add_max_data_out;

	adder_maximizer
	#(
		.INPUT_KEY_WIDTH(max($bits(TileMoveScore), $bits(TileEvalScore))),
		.OUTPUT_KEY_WIDTH(max($bits(TileMoveScore), $bits(BoardEvalScore))),
		.DATA_WIDTH($bits(Position))
	) add_max (
		.operation(add_max_op),
		.key_in(add_max_key_in),
		.data_in(add_max_data_in),
		.key_out(add_max_key_out),
		.data_out(add_max_data_out)
	);


	// --- Instantiate board_hist ---
	// board_hist module signals
	MoveRecord curr_move_record;
	MoveRecord last_move_record;
	logic move_hist_wr_en;
	logic move_hist_rd_en;

	board_hist hist (
		.clk(clk),
		.rst_n(rst_n),
		.wr_en(move_hist_wr_en),
		.move_record_in(curr_move_record),
		.pop_move(move_hist_rd_en),
		.move_record_out(last_move_record),
		.is_full()
	);


	// --- Connect data_in_buffer, move_buffer, and in_search_buffer ---
	always_ff @(posedge clk) begin
		if (ready) begin
			data_in_buffer <= data_in;
			move_buffer <= move_in;
			in_search_buffer <= in_search;
		end
	end


	// --- Connect adj_bus_out and adj_bus_in ---
	// --- Connect knight_bus_out and knight_bus_in ---
	always_comb begin
		// Set default values inputs (for edges)
		for (int pos=0; pos<64; pos+=1) begin
			for (int dir=0; dir<8; dir+=1) begin
				adj_bus_in[pos][dir].tile = Tile'({UNKNOWN_COLOR, NULL_PIECE});
				adj_bus_in[pos][dir].distance = 3'd0;

				knight_bus_in[pos][dir].piece_color = UNKNOWN_COLOR;
				knight_bus_in[pos][dir].has_knight = 1'b0;
				knight_bus_in[pos][dir].has_king_or_major = 1'b0;
			end
		end

		// --- Connect adj_bus_* and knight_bus_* between tiles ---
		for (int rank=0, pos=0; rank<8; rank+=1) begin
			for (int file=0; file<8; file+=1) begin
				pos = 8*rank + file;	// Calc position on board

				if (rank != 7) begin
					adj_bus_in[pos][NORTH] = adj_bus_out[pos+8][SOUTH];
					adj_bus_in[pos+8][SOUTH] = adj_bus_out[pos][NORTH];
				end

				if (file != 7) begin
					adj_bus_in[pos][EAST] = adj_bus_out[pos+1][WEST];
					adj_bus_in[pos+1][WEST] = adj_bus_out[pos][EAST];
				end

				if (rank != 7 && file != 7) begin
					adj_bus_in[pos][NORTH_EAST] = adj_bus_out[pos+9][SOUTH_WEST];
					adj_bus_in[pos+9][SOUTH_WEST] = adj_bus_out[pos][NORTH_EAST];
				end

				if (rank != 0 && file != 7) begin
					adj_bus_in[pos][SOUTH_EAST] = adj_bus_out[pos-7][NORTH_WEST];
					adj_bus_in[pos-7][NORTH_WEST] = adj_bus_out[pos][SOUTH_EAST];
				end

				// --- Connect Knight Data and Assert Ports ---
				if (rank != 7 && rank != 6 && file != 7) begin
					knight_bus_in[pos][NNE] = knight_bus_out[pos+17];
					knight_bus_in[pos+17][SSW] = knight_bus_out[pos];
				end

				if (rank != 0 && rank != 1 && file != 7) begin
					knight_bus_in[pos][SSE] = knight_bus_out[pos-15];
					knight_bus_in[pos-15][NNW] = knight_bus_out[pos];
				end

				if (rank != 0 && file != 0 && file != 1) begin
					knight_bus_in[pos][SWW] = knight_bus_out[pos-10];
					knight_bus_in[pos-10][NEE] = knight_bus_out[pos];
				end

				if (rank != 0 && file != 6 && file != 7) begin
					knight_bus_in[pos][SEE] = knight_bus_out[pos-6];
					knight_bus_in[pos-6][NWW] = knight_bus_out[pos];
				end
			end
		end
	end


	// --- Compute state ---
	always_ff @(posedge clk) begin
		if (~rst_n) begin
			state <= IDLE_BOARD_STATE;

		end else if (ready) begin
			case (board_operation)
				BOARD_IDLE_OP:         state <= IDLE_BOARD_STATE;
				BOARD_PLACE_PIECE_OP:        state <= PLACE_PIECE_STATE;
				BOARD_MAKE_MOVE_OP:          state <= MAKE_MOVE_STATE0;
				BOARD_REVERSE_MOVE_OP:       state <= REVERSE_MOVE_STATE0;
				BOARD_GET_BEST_MOVE_OP:      state <= GET_BEST_MOVE_STATE;
				BOARD_GET_BOARD_SCORE_OP:    state <= GET_BOARD_SCORE_STATE;
				BOARD_GET_TILE_OCCUPANCY_OP: state <= GET_TILE_OCCUPANCY_STATE;
				BOARD_WRITE_TURN_OP:         state <= WRITE_TURN_STATE;
				BOARD_WRITE_CASTLE_OP:       state <= WRITE_CASTLE_STATE;
				BOARD_WRITE_EN_PASSANT_OP:   state <= WRITE_EN_PASSANT_STATE;
				BOARD_WRITE_LSB_HM_CLOCK_OP: state <= WRITE_LSB_HM_CLOCK_STATE;
				BOARD_WRITE_MSB_HM_CLOCK_OP: state <= WRITE_MSB_HM_CLOCK_STATE;
				BOARD_READ_TURN_OP:          state <= READ_TURN_STATE;
				BOARD_READ_CASTLE_OP:        state <= READ_CASTLE_STATE;
				BOARD_READ_EN_PASSANT_OP:    state <= READ_EN_PASSANT_STATE;
				BOARD_READ_LSB_HM_CLOCK_OP:  state <= READ_LSB_HM_CLOCK_STATE;
				BOARD_READ_MSB_HM_CLOCK_OP:  state <= READ_MSB_HM_CLOCK_STATE;
				default:               state <= BoardState'('dx);
			endcase

		end else if (state == MAKE_MOVE_STATE0 && move_is_en_passant) begin
			state <= MAKE_MOVE_STATE1;

		end else if (state == MAKE_MOVE_STATE0 && move_is_castle) begin
			state <= MAKE_MOVE_STATE2;

		// Extra cycle to replace killed piece (including in en passant)
		end else if (state == REVERSE_MOVE_STATE0 && (last_move_record.killed_piece!=NULL_PIECE || last_move_record.move_flag==EP_MOVE)) begin
			state <= REVERSE_MOVE_STATE1;

		// Extra cycle to undo moving rook in castle move
		end else if (state == REVERSE_MOVE_STATE0 && last_move_record.move_flag==CASTLE_MOVE) begin
			state <= REVERSE_MOVE_STATE2;

		// Should never occur
		end else begin
			state <= BoardState'('dx);
		end
	end


	// --- Compute ready ---
	always_comb begin
		ready = 1'b0;

		// Unconditionally ready states
		case (state)
			IDLE_BOARD_STATE,
			PLACE_PIECE_STATE,
			MAKE_MOVE_STATE1,
			MAKE_MOVE_STATE2,
			REVERSE_MOVE_STATE1,
			REVERSE_MOVE_STATE2,
			GET_BEST_MOVE_STATE,
			GET_BOARD_SCORE_STATE,
			GET_TILE_OCCUPANCY_STATE,
			WRITE_TURN_STATE,
			WRITE_CASTLE_STATE,
			WRITE_EN_PASSANT_STATE,
			WRITE_LSB_HM_CLOCK_STATE,
			WRITE_MSB_HM_CLOCK_STATE,
			READ_TURN_STATE,
			READ_CASTLE_STATE,
			READ_EN_PASSANT_STATE,
			READ_LSB_HM_CLOCK_STATE,
			READ_MSB_HM_CLOCK_STATE:

			ready = 1'b1;
		endcase

		// Conditional ready states 
		// Set ready to high on any state that terminates an operation
		if (   (state == MAKE_MOVE_STATE0 && ~move_is_castle && ~move_is_en_passant)
		    || (state == REVERSE_MOVE_STATE0 && last_move_record.move_flag!=CASTLE_MOVE
		        && last_move_record.killed_piece==NULL_PIECE && last_move_record.move_flag!=EP_MOVE)) begin

			ready = 1'b1;
		end
	end


	// --- Compute tile_op ---
	always_comb begin
		case (state)
			PLACE_PIECE_STATE: tile_op <= PLACE_TILE;

			// Move primary piece to new tile
			MAKE_MOVE_STATE0: tile_op <= PLACE_MASK_AND_CLEAR_TILE;

			// Place NULL_PIECE in the case of removing EP-killed pawn
			MAKE_MOVE_STATE1: tile_op <= PLACE_TILE;

			// Move rook but don't mask in the case of castle
			MAKE_MOVE_STATE2: tile_op <= PLACE_AND_CLEAR_TILE;

			// Move primary piece back and reset masks at current search depth
			REVERSE_MOVE_STATE0: tile_op <= PLACE_RESET_MASK_AND_CLEAR_TILE;

			// Place killed piece back in the case of kill or EP-kill
			REVERSE_MOVE_STATE1: tile_op <= PLACE_TILE;

			// Move the rook back in the case of en-passant
			REVERSE_MOVE_STATE2: tile_op <= PLACE_AND_CLEAR_TILE;

			// Get best move from each tile
			GET_BEST_MOVE_STATE: tile_op <= OUTPUT_BEST_MOVE_TILE;

			// Get board score from each tile
			GET_BOARD_SCORE_STATE: tile_op <= OUTPUT_SCORE_TILE;

			default: tile_op <= IDLE_TILE;
		endcase
	end


	// --- Compute move_is_kill, move_is_en_passant, move_is_castle, and move_is_promotion ---
	always_comb begin
		move_is_kill = 1'b0;
		move_is_en_passant = 1'b0;
		move_is_castle = 1'b0;
		move_is_promotion = 1'b0;

		// - Check for kill move -
		if (tile_rd_data[move_buffer.end_pos] != NULL_PIECE) begin
			move_is_kill = 1'b1;
		end

		// - Check for en passant moves -
		if (   has_ep
			&& turn == WHITE
		    && getRank(move_buffer.end_pos) == 5
		    && getFile(move_buffer.end_pos) == ep_file
		    && (tile_rd_data[move_buffer.start_pos].piece_type == PAWN
		        || tile_rd_data[move_buffer.end_pos].piece_type == PAWN)) begin

			move_is_en_passant = 1'b1;
		end
		if (   has_ep
			&& turn == BLACK
		    && getRank(move_buffer.end_pos) == 2
		    && getFile(move_buffer.end_pos) == ep_file
		    && (tile_rd_data[move_buffer.start_pos].piece_type == PAWN
		        || tile_rd_data[move_buffer.end_pos].piece_type == PAWN)) begin
			
			move_is_en_passant = 1'b1;
		end

		// - Check for castling move -
		// White castles
		if (state==MAKE_MOVE_STATE0 || state==MAKE_MOVE_STATE1 || state==MAKE_MOVE_STATE2) begin
			if (move_buffer.start_pos == Position'(4)) begin
				if (move_buffer.end_pos == Position'(2) && castle_perms.whiteQueenside) begin
					move_is_castle = 1'b1;
				end
				if (move_buffer.end_pos == Position'(6) && castle_perms.whiteKingside) begin
					move_is_castle = 1'b1;
				end
			end
			// Black castles
			if (move_buffer.start_pos == Position'(60)) begin
				if (move_buffer.end_pos == Position'(58) && castle_perms.blackQueenside) begin
					move_is_castle = 1'b1;
				end
				if (move_buffer.end_pos == Position'(62) && castle_perms.blackKingside) begin
					move_is_castle = 1'b1;
				end
			end
		end else begin
			move_is_castle = 1'bx;
		end

		// - Check for Pawn Promotion -
		if (   (getRank(move_buffer.end_pos) == 0 || getRank(move_buffer.end_pos) == 7)
			&& tile_rd_data[move_buffer.start_pos].piece_type == PAWN) begin
			
			move_is_promotion = 1'b1;
		end
	end


	// --- Update turn, castle_perms, has_ep, ep_file, halfmove_clock, and search_depth ---
	always_ff @(posedge clk) begin
		// - Update turn -
		if (state == WRITE_TURN_STATE) begin
			turn <= Color'(data_in_buffer[0]);
		// Invert turn at end of move or reverse-move operation
		end else if (ready) begin
			case (state)
				MAKE_MOVE_STATE0,
				MAKE_MOVE_STATE1,
				MAKE_MOVE_STATE2,
				REVERSE_MOVE_STATE0,
				REVERSE_MOVE_STATE1,
				REVERSE_MOVE_STATE2:
					turn <= Color'(~turn);

				default:
					turn <= turn;
			endcase
		end


		// - Update Castling Perms -
		if (state == WRITE_CASTLE_STATE) begin
			castle_perms <= CastlePerms'(data_in_buffer);		

		// Update perms on a king or rook move
		end else if (ready && (state == MAKE_MOVE_STATE0 || state == MAKE_MOVE_STATE1 || state == MAKE_MOVE_STATE2)) begin
			case (move_buffer.start_pos)
				Position'('d4): begin
					castle_perms.whiteKingside <= 1'b0;
					castle_perms.whiteQueenside <= 1'b0;
				end
				Position'('d7): begin
					castle_perms.whiteKingside <= 1'b0;
				end
				Position'('d0): begin
					castle_perms.whiteQueenside <= 1'b0;
				end

				Position'('d60): begin
					castle_perms.blackKingside <= 1'b0;
					castle_perms.blackQueenside <= 1'b0;
				end
				Position'('d63): begin
					castle_perms.blackKingside <= 1'b0;
				end
				Position'('d56): begin
					castle_perms.blackQueenside <= 1'b0;
				end
			endcase
		end else if (ready && (state == REVERSE_MOVE_STATE0 || state == REVERSE_MOVE_STATE1 || state == REVERSE_MOVE_STATE2)) begin
			castle_perms <= last_move_record.castle_perms;
		end


		// - Update En Passant State - 
		if (state == WRITE_EN_PASSANT_STATE) begin
			has_ep <= data_in_buffer[3];
			ep_file <= BoardFile'(data_in_buffer[2:0]);

		// Check for long pawn moves on last cycle of move operation
		end else if (   (ready && state == MAKE_MOVE_STATE0)
		             || state == MAKE_MOVE_STATE1
		             || state == MAKE_MOVE_STATE2) begin

			if (tile_rd_data[move_buffer.start_pos].piece_type == PAWN) begin
				if (getRank(move_buffer.start_pos) == 1 && getRank(move_buffer.end_pos) == 3) begin
					has_ep <= 1'b1;
					ep_file <= getFile(move_buffer.end_pos);

				end else if (getRank(move_buffer.start_pos) == 6 && getRank(move_buffer.end_pos) == 4) begin
					has_ep <= 1'b1;
					ep_file <= getFile(move_buffer.end_pos);

				end else begin
					has_ep <= 1'b0;
					ep_file <= BoardFile'('dx);
				end
			end else begin
				has_ep <= 1'b0;
				ep_file <= BoardFile'('dx);
			end

		end else if (ready) begin
			// Update from stored prev halfmove clock
			case (state)
				REVERSE_MOVE_STATE0, REVERSE_MOVE_STATE1, REVERSE_MOVE_STATE2: begin
					has_ep <= last_move_record.has_ep;
					ep_file <= last_move_record.ep_file;
				end
			endcase
		end


		// - Update Halfmove Clock -
		if (state == WRITE_LSB_HM_CLOCK_STATE) begin
			halfmove_clock[3:0] <= data_in_buffer;

		end else if (state == WRITE_MSB_HM_CLOCK_STATE) begin
			halfmove_clock[6:4] <= data_in_buffer[2:0];

		end else if (state == MAKE_MOVE_STATE0) begin
			if (move_is_kill || tile_rd_data[move_buffer.start_pos].piece_type == PAWN) begin
				halfmove_clock = 7'd0;
			end else begin
				halfmove_clock += 7'd1;
			end

		end else if (ready) begin
			// Update from stored prev halfmove clock
			case (state)
				REVERSE_MOVE_STATE0, REVERSE_MOVE_STATE1, REVERSE_MOVE_STATE2:

				halfmove_clock <= last_move_record.halfmove_clock;
			endcase
		end


		// - Increment/Decrement search depth -
		if (~rst_n) begin
			search_depth <= DepthType'('d0);
		end else if (in_search_buffer && ready) begin
			if (state==MAKE_MOVE_STATE0 || state==MAKE_MOVE_STATE1 || state==MAKE_MOVE_STATE2) begin
				search_depth <= search_depth + DepthType'('d1);
			end else if (state==REVERSE_MOVE_STATE0 || state==REVERSE_MOVE_STATE1 || state==REVERSE_MOVE_STATE2) begin
				search_depth <= search_depth - DepthType'('d1);
			end
		end
	end


	// --- Update tile_wr_data ---
	always_comb begin
		case (state)
			PLACE_PIECE_STATE: tile_wr_data = data_in_buffer;

			// Normal move
			MAKE_MOVE_STATE0: begin
				if (move_is_promotion) begin
					case (move_buffer.promo_piece)
						PROMO_QUEEN: tile_wr_data = Tile'({tile_rd_data[move_buffer.start_pos].piece_color, QUEEN});
						PROMO_ROOK: tile_wr_data = Tile'({tile_rd_data[move_buffer.start_pos].piece_color, ROOK});
						PROMO_BISHOP: tile_wr_data = Tile'({tile_rd_data[move_buffer.start_pos].piece_color, BISHOP});
						PROMO_KNIGHT: tile_wr_data = Tile'({tile_rd_data[move_buffer.start_pos].piece_color, KNIGHT});
						default : tile_wr_data = Tile'('dx);
					endcase
				end else begin
					tile_wr_data = tile_rd_data[move_buffer.start_pos];
				end
			end

			// Write NULL to killed piece on EP kill
			MAKE_MOVE_STATE1: tile_wr_data = Tile'({UNKNOWN_COLOR, NULL_PIECE});

			// Write extra rook on castle move
			MAKE_MOVE_STATE2: tile_wr_data = Tile'({tile_rd_data[move_buffer.end_pos].piece_color, ROOK});

			// Write moving piece back to start loction
			REVERSE_MOVE_STATE0: begin
				if (last_move_record.move_flag == PROMO_MOVE) begin
					tile_wr_data = Tile'({~turn, PAWN});
				end else begin
					tile_wr_data = Tile'({~turn, tile_rd_data[last_move_record.end_pos]});
				end
			end
			
			// Write killed piece back to board
			REVERSE_MOVE_STATE1: begin
				if (last_move_record.move_flag == EP_MOVE) begin
					tile_wr_data = Tile'({turn, PAWN});
				end else begin
					tile_wr_data = Tile'({turn, last_move_record.killed_piece});
				end
			end

			REVERSE_MOVE_STATE2: tile_wr_data = Tile'({~turn, ROOK});

			default: tile_wr_data = Tile'('dx);
		endcase
	end


	// --- Compute illegal_board ---
	always_comb begin
		illegal_board = 1'b0;
		for (int pos=0; pos<64; pos+=1) begin
			illegal_board |= illegal_tile[pos];
		end
	end


	// --- Compute best_move and board_score ---
	always_comb begin
		// - Send board score in eval mode -
		board_score = add_max_key_out[$bits(board_score)-1:0];

		// - Send best move in best move mode -
		if (add_max_key_out[$bits(board_score)-1:0] == NULL_PIECE) begin
			best_move = NULL_MOVE;
		end else begin
			// add-max data out is destination tile
			best_move.end_pos = add_max_data_out;

			// Calculate start position from end position and shift
			// Distance of 0 represents a knight move
			if (tile_move_dist[best_move.end_pos] == 3'd0) begin
				best_move.start_pos = best_move.end_pos + KNIGHT_SHIFT[tile_move_dir[best_move.end_pos]];
			end else begin
				best_move.start_pos = best_move.end_pos + DIST_SHIFT[tile_move_dir[best_move.end_pos]][tile_move_dist[best_move.end_pos]];
			end

			// Only care about promotion outputs from first and last rank
			if (   getRank(best_move.end_pos) == BoardRank'(0)
			    || getRank(best_move.end_pos) == BoardRank'(7)) begin

				best_move.promo_piece = tile_promo_type[best_move.end_pos];
			end else begin
				best_move.promo_piece = PromoType'('dx);
			end
		end
	end


	// --- Compute select_1 and select_2 ---
	always_comb begin
		if (state == PLACE_PIECE_STATE) begin
			select_1 = move_buffer.end_pos;
			select_2 = ~select_1;	// Ensure sel 1 does not match sel 2

		// Normal move
		end else if (state == MAKE_MOVE_STATE0) begin
			select_1 = move_buffer.end_pos;
			select_2 = move_buffer.start_pos;

		// Extra NULL_PIECE write for EP move
		end else if (state == MAKE_MOVE_STATE1) begin
			select_1 = getPosition({move_buffer.end_pos[5:4], ~move_buffer.end_pos[3]}, ep_file);
			select_2 = ~select_1;

		// Move rook in castle move
		end else if (state == MAKE_MOVE_STATE2) begin
			case (move_buffer.end_pos)
				Position'('d6): begin // White king's side
					select_1 = Position'('d5);
					select_2 = Position'('d7);
				end

				Position'('d2): begin // White queen's side
					select_1 = Position'('d3);
					select_2 = Position'('d0);
				end

				Position'('d62): begin // Black king's side
					select_1 = Position'('d61);
					select_2 = Position'('d63);
				end

				Position'('d58): begin // Black queen's side
					select_1 = Position'('d59);
					select_2 = Position'('d56);
				end

				// Should never occur
				default: begin
					select_1 = Position'('dx);
					select_2 = Position'('dx);
				end
			endcase

		// Reverse normal move
		end else if (state == REVERSE_MOVE_STATE0) begin
			select_1 = last_move_record.start_pos;
			select_2 = last_move_record.end_pos;

		// Reverse kill or EP kill
		end else if (state == REVERSE_MOVE_STATE1) begin
			if (last_move_record.move_flag == EP_MOVE) begin
				select_1 = getPosition(getRank(last_move_record.start_pos), last_move_record.ep_file);
			end else begin
				select_1 = last_move_record.end_pos;
			end
			select_2 = ~select_1;

		// Move rook back in castling move
		end else if (state == REVERSE_MOVE_STATE2) begin
			case (last_move_record.end_pos)
				Position'('d6): begin // White king's side
					select_2 = Position'('d5);
					select_1 = Position'('d7);
				end

				Position'('d2): begin // White queen's side
					select_2 = Position'('d3);
					select_1 = Position'('d0);
				end

				Position'('d62): begin // Black king's side
					select_2 = Position'('d61);
					select_1 = Position'('d63);
				end

				Position'('d58): begin // Black queen's side
					select_2 = Position'('d59);
					select_1 = Position'('d56);
				end

				// Should never occur
				default: begin
					select_1 = Position'('dx);
					select_2 = Position'('dx);
				end
			endcase

		end else begin
			select_1 = move_buffer.end_pos;
			select_2 = ~select_1;	// Ensure sel 1 does not match sel 2
		end
	end


	// --- Compute data_out ---
	always_comb begin
		case (state)
			GET_TILE_OCCUPANCY_STATE: data_out <= tile_rd_data[move_buffer.end_pos];
			READ_TURN_STATE: data_out <= {3'bx, turn};
			READ_CASTLE_STATE: data_out <= castle_perms;
			READ_EN_PASSANT_STATE: data_out <= {has_ep, ep_file};
			READ_LSB_HM_CLOCK_STATE: data_out <= halfmove_clock[3:0];
			READ_MSB_HM_CLOCK_STATE: data_out <= {1'bx, halfmove_clock[6:4]};

			default: data_out <= Tile'('dx);
		endcase
	end


	// --- Compute add_max_op, add_max_key_in, add_max_data_in ---
	always_comb begin
		// Choose operation based on state
		case (state)
			GET_BEST_MOVE_STATE:   add_max_op <= GET_AM_MAX;
			GET_BOARD_SCORE_STATE: add_max_op <= GET_AM_SUM;
			default:               add_max_op <= AddMaxOp'('dx);
		endcase

		// Assign Inputs to add_max
		for (int pos=0; pos<64; pos+=1) begin
			if (state == GET_BEST_MOVE_STATE) begin
				add_max_key_in[pos] <= tile_move_score[pos];
			end else if (state == GET_BOARD_SCORE_STATE) begin
				add_max_key_in[pos] <= tile_eval_score[pos];
			end else begin
				add_max_key_in[pos] <= 'dx;
			end

			add_max_data_in[pos] <= Position'(pos);
		end
	end


	// --- Compute move_hist_wr_en, move_hist_rd_en ---
	// --- Compute curr_move_record ---
	always_comb begin
		move_hist_wr_en = 1'b0;
		move_hist_rd_en = 1'b0;

		if (ready) begin
			case (state)
				MAKE_MOVE_STATE0, MAKE_MOVE_STATE1, MAKE_MOVE_STATE2:
				move_hist_wr_en = 1'b1;
			endcase

			case (state)
				REVERSE_MOVE_STATE0, REVERSE_MOVE_STATE1, REVERSE_MOVE_STATE2:
				move_hist_rd_en = 1'b1;
			endcase
		end

		curr_move_record.start_pos = move_buffer.start_pos;
		curr_move_record.end_pos = move_buffer.end_pos;
		if (move_is_castle) begin
			curr_move_record.killed_piece = NULL_PIECE;
		end else begin
			curr_move_record.killed_piece = tile_rd_data[move_buffer.end_pos].piece_type;
		end
		curr_move_record.castle_perms = castle_perms;

		case ({move_is_promotion, move_is_en_passant, move_is_castle})
			3'b000: curr_move_record.move_flag = NORM_MOVE;
			3'b100: curr_move_record.move_flag = PROMO_MOVE;
			3'b010: curr_move_record.move_flag = EP_MOVE;
			3'b001: curr_move_record.move_flag = CASTLE_MOVE;
			default: curr_move_record.move_flag = MoveFlag'('dx);
		endcase

		curr_move_record.has_ep = has_ep;
		curr_move_record.ep_file = ep_file;
		curr_move_record.halfmove_clock = halfmove_clock;
	end

endmodule : board

