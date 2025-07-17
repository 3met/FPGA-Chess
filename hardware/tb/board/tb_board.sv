
// By Emet Behrendt

`timescale 1ns / 1ps

import general_chess_defs::*;
import board_defs::*;

// Run in modelsim with:
// vsim -L altera_mf -L lpm -L 220model work.tb_board
// restart -f; run -all

module tb_board();

	// DUT signals
	logic clk = 0;
	logic rst_n = 1'b1;
	BoardOp board_operation = BOARD_IDLE_OP;
	logic [3:0] data_in;
	Move move_in = NULL_MOVE;
	logic in_search = 0;
	logic ready;
	logic illegal_board;
	Move best_move;
	BoardEvalScore board_score;
	Tile data_out;

	// Setup DUT
	board dut (
		.clk(clk),
		.rst_n(rst_n),
		.board_operation(board_operation),
		.data_in(data_in),
		.move_in(move_in),
		.in_search(in_search),
		.ready(ready),
		.illegal_board(illegal_board),
		.best_move(best_move),
		.board_score(board_score),
		.data_out(data_out)
	);

	// Setup DUT tile indexing
	generate
		Tile tile_arr[64];

		for (genvar i=0; i<64; i+=1) begin
			assign tile_arr[i] = dut.board_gen_tiles[i].tile_PE.occupant;
		end
	endgenerate

	// Function to do given number of clock cycles
	task clock(int cycle_count=1);
		for (int i=0; i<cycle_count; i+=1) begin
			#5;
			clk = 1'b1;
			#5;
			clk = 1'b0;
		end
	endtask : clock

	// Prints the board to console
	function void print_board();
		byte letter;

		$display("-------------------");

		for (int i=0; i<64; i+=1) begin

			casex (tile_arr[SHOW_ORDER[i]])
				{1'bx, NULL_PIECE}:		letter = ".";
				{WHITE, PAWN}:			letter = "P";
				{WHITE, KNIGHT}:		letter = "N";
				{WHITE, BISHOP}:		letter = "B";
				{WHITE, ROOK}:			letter = "R";
				{WHITE, QUEEN}:			letter = "Q";
				{WHITE, KING}:			letter = "K";
				{BLACK, PAWN}:			letter = "p";
				{BLACK, KNIGHT}:		letter = "n";
				{BLACK, BISHOP}:		letter = "b";
				{BLACK, ROOK}:			letter = "r";
				{BLACK, QUEEN}:			letter = "q";
				{BLACK, KING}:			letter = "k";
				{WHITE, SPARE_PIECE}:	letter = "X";
				{BLACK, SPARE_PIECE}:	letter = "x";
				default:                letter = "E";
			endcase

			if (i % 8 == 0) $write("%0d |", 8-i[5:3]);
			$write(" %s", letter);
			if ((i+1) % 8 == 0) $write("\n");
		end

		$display("  +----------------");
		$display("    a b c d e f g h");
		$display("-------------------");
	endfunction


	// Function to clear board
	task clear_board();
		$display("Clearing Board");
		board_operation = BOARD_PLACE_PIECE_OP;
		data_in = Tile'({UNKNOWN_COLOR, NULL_PIECE});

		for (int pos=0; pos<64; pos+=1) begin
			move_in.end_pos = Position'(pos);
			clock();
		end
		board_operation = BOARD_IDLE_OP;
	endtask : clear_board


	// -- Task to place a piece on the board --
	task place_piece(Tile tile, Position pos);
		board_operation = BOARD_PLACE_PIECE_OP;
		data_in = tile;
		move_in.end_pos = pos;
		clock();
	endtask


	// -- Task to make a move on the board --
	task make_move(Move m);
		board_operation = BOARD_MAKE_MOVE_OP;
		move_in = m;
		clock();
		board_operation = BOARD_IDLE_OP;
	endtask


	// -- Ensure select_1 is never the same as select_2 --
	always_ff @(posedge clk or negedge rst_n) begin
	    if (~rst_n) begin
	        // Reset logic if needed
	    end else begin
	        // Check that select_1 is never equal to select_2
	        assert(dut.select_1 != dut.select_2) 
	        else $error("Error: select_1 is equal to select_2 at time %0t", $time());
	    end
	end


	// Testing Variables
	Tile starting_tiles[64];
	int move_counter;
	Move move_output;

	// Scoring Variables
	int passCount = 0;
	int failCount = 0;


	// -- Function to Assert Equality with Error MSG --
	function void assert_true(x, string msg);
		assert (x) begin
			passCount += 1;
		end else begin
			failCount += 1;
			$error(msg);
		end
	endfunction


	initial begin
		
		// Reset the board
		#10;
		rst_n = 1'b0;
		clock(10);
		rst_n = 1'b1;
		clock(10);

		print_board();
		clear_board();
		print_board();

		$display("=== Setting up Board Pieces ===");
		// $monitor("[%10t] dut.data_in=%4b, tile_arr[0]=%4b", $time, dut.data_in, tile_arr[0]);

		// --- Set Starting Board --
		place_piece({WHITE, ROOK}, 0);
		place_piece({WHITE, KNIGHT}, 1);
		place_piece({WHITE, BISHOP}, 2);
		place_piece({WHITE, QUEEN}, 3);
		place_piece({WHITE, KING}, 4);
		place_piece({WHITE, BISHOP}, 5);
		place_piece({WHITE, KNIGHT}, 6);
		place_piece({WHITE, ROOK}, 7);

		for (int pos=8; pos<16; pos+=1) begin
			place_piece({WHITE, PAWN}, pos);
		end

		place_piece({BLACK, ROOK}, 63);
		place_piece({BLACK, KNIGHT}, 62);
		place_piece({BLACK, BISHOP}, 61);
		place_piece({BLACK, KING}, 60);
		place_piece({BLACK, QUEEN}, 59);
		place_piece({BLACK, BISHOP}, 58);
		place_piece({BLACK, KNIGHT}, 57);
		place_piece({BLACK, ROOK}, 56);

		for (int pos=55; pos>=48; pos-=1) begin
			place_piece({BLACK, PAWN}, pos);
		end

		clock(1);

		for (int i=0; i<64; i+=1) begin
			starting_tiles[i] <= tile_arr[i];
		end

		// Setup remaining game state variables
		board_operation = BOARD_WRITE_TURN_OP;
		data_in = {3'bx, WHITE};
		clock();
		board_operation = BOARD_WRITE_CASTLE_OP;
		data_in = 4'b1111;
		clock();
		board_operation = BOARD_WRITE_EN_PASSANT_OP;
		data_in = 4'b0xxx;
		clock();
		board_operation = BOARD_WRITE_LSB_HM_CLOCK_OP;
		data_in = 4'b0000;
		clock();
		board_operation = BOARD_WRITE_MSB_HM_CLOCK_OP;
		data_in = 4'bx000;
		clock();
		board_operation = BOARD_IDLE_OP;
		clock(20);

		// Check correct turn
		assert_true(dut.turn === WHITE, "Turn not correctly set to WHITE");

		// Check castle permissions
		assert_true(dut.castle_perms === 4'b1111, "Castle permissions not correctly set");

		// Check correct en passant value
		assert_true(dut.has_ep === 1'b0, "Incorrectly starts with en passant");

		// Check reseting halfmove clock
		assert_true(dut.halfmove_clock === 7'd0, "Fails to reset halfmove clock");

		print_board();

		// -- Testing Moves --
		$display("=== Testing Moves ===");

		// Move 1, e2e4
		make_move(Move'({6'd12, 6'd28, PROMO_UNKNOWN}));
		clock();
		print_board();

		assert_true(dut.turn === BLACK, "Turn not correctly updated to BLACK");

		// Check pawn moved to new square
		assert_true(tile_arr[28] === Tile'({WHITE, PAWN}), "Pawn not moved successfully");
		assert_true(tile_arr[12].piece_type === NULL_PIECE, "Pawn not moved successfully");

		// Check castle permissions
		assert_true(dut.castle_perms === 4'b1111, "Castle permissions not correctly set");

		// Check updating en passant status
		assert_true(dut.has_ep === 1'b1, "Fails to recognize en passant");
		
		// Check correct en passant file
		assert_true(dut.ep_file === BoardFile'(3'd4), "Incorrect en passant file");

		// Check reseting halfmove clock
		assert_true(dut.halfmove_clock === 7'd0, "Fails to reset halfmove clock");

		// Move 2: f7f5
		make_move(Move'({6'd53, 6'd37, PROMO_UNKNOWN}));
		clock();
		print_board();

		// Check correct turn
		assert_true(dut.turn === WHITE, "Turn not correctly updated to WHITE");


		// Check pawn moved to new square
		assert_true(tile_arr[37] === Tile'({BLACK, PAWN}), "Pawn not moved successfully");
		assert_true(tile_arr[53].piece_type === NULL_PIECE, "Pawn not moved successfully");

		// Move 3: e4f5
		make_move(Move'({6'd28, 6'd37, PROMO_UNKNOWN}));
		clock();
		print_board();

		// Check pawn moved to new square
		assert_true(tile_arr[37] === Tile'({WHITE, PAWN}), "Pawn not moved successfully");
		assert_true(tile_arr[28].piece_type === NULL_PIECE, "Pawn not moved successfully");

		// Moves 4-5: e7e5, f5e6
		make_move(Move'({6'd52, 6'd36, PROMO_UNKNOWN}));
		make_move(Move'({6'd37, 6'd44, PROMO_UNKNOWN}));
		clock(2);
		print_board();

		// Check correct turn
		assert_true(dut.turn === BLACK, "Turn not correctly updated to BLACK");

		// Check en passant kill
		assert_true(tile_arr[44] === Tile'({WHITE, PAWN}), "En Passant kill was not successfully");

		assert (tile_arr[36].piece_type === NULL_PIECE) begin
			passCount += 1;
		end else begin
			failCount += 1;
			$error("En Passant kill was not successfully, expected=%3b, received=%3b", NULL_PIECE, tile_arr[36].piece_type);
		end
		assert (tile_arr[37].piece_type === NULL_PIECE) begin
			passCount += 1;
		end else begin
			failCount += 1;
			$error("En Passant kill was not successfully, expected=%3b, received=%3b", NULL_PIECE, tile_arr[37].piece_type);
		end

		// Check reseting halfmove clock
		assert_true(dut.halfmove_clock === 7'd0, "Fails to reset halfmove clock");

		// Move 6-8: g8f6, e6d7, f8c5
		make_move(Move'({6'd62, 6'd45, PROMO_UNKNOWN}));
		make_move(Move'({6'd44, 6'd51, PROMO_UNKNOWN}));
		make_move(Move'({6'd61, 6'd34, PROMO_UNKNOWN}));
		make_move(Move'({6'd51, 6'd58, PROMO_QUEEN}));
		clock();
		print_board();

		assert_true(tile_arr[58].piece_type === QUEEN, "Promotion not successful");

		// Move 9: e8g8 (Black king castle)
		make_move(Move'({6'd60, 6'd62, PROMO_UNKNOWN}));
		clock(2);

		print_board();

		assert_true(tile_arr[60].piece_type === NULL_PIECE, "Castling move not successful");
		assert_true(tile_arr[61] === Tile'({BLACK, ROOK}), "Castling move not successful");
		assert_true(tile_arr[62] === Tile'({BLACK, KING}), "Castling move not successful");
		assert_true(tile_arr[63].piece_type === NULL_PIECE, "Castling move not successful");

		assert_true(dut.castle_perms.whiteKingside, "Castling perm updates not successful");
		assert_true(dut.castle_perms.whiteQueenside, "Castling perm updates not successful");
		assert_true(~dut.castle_perms.blackKingside, "Castling perm updates not successful");
		assert_true(~dut.castle_perms.blackQueenside, "Castling perm updates not successful");

		// Make and undo normal move: b2b4
		$display("=== Test Revese Move ===");
		make_move(Move'({6'd9, 6'd25, PROMO_UNKNOWN}));
		board_operation = BOARD_REVERSE_MOVE_OP;
		move_in = Move'($urandom_range(0, $bits(Move)-1));
		clock();
		board_operation = BOARD_IDLE_OP;
		clock();
		print_board();

		assert_true(tile_arr[25].piece_type === NULL_PIECE, "Reverse move was not successful");
		assert_true(tile_arr[9] === Tile'({WHITE, PAWN}), "Reverse move was not successful");
		assert_true(dut.turn == WHITE, "Reverse move was not successful");

		// Make and undo kill move: b2b4, c5b4
		$display("=== Test Revese Kill Move ===");
		make_move(Move'({6'd9, 6'd25, PROMO_UNKNOWN}));
		make_move(Move'({6'd34, 6'd25, PROMO_UNKNOWN}));
		board_operation = BOARD_REVERSE_MOVE_OP;
		move_in = Move'($urandom_range(0, $bits(Move)-1));
		clock(2);
		board_operation = BOARD_REVERSE_MOVE_OP;
		move_in = Move'($urandom_range(0, $bits(Move)-1));
		clock();
		board_operation = BOARD_IDLE_OP;
		clock(2);
		print_board();

		assert_true(tile_arr[25].piece_type === NULL_PIECE, "Reverse kill move was not successful");
		assert_true(tile_arr[9] === Tile'({WHITE, PAWN}), "Reverse kill move was not successful");
		assert_true(tile_arr[34] === Tile'({BLACK, BISHOP}), "Reverse kill move was not successful");


		// Make and several moves: a2a3, a7a6, a3a4, a6a5
		$display("=== Test Undo Many Moves ===");
		clock(10);
		make_move(Move'({6'd8, 6'd16, PROMO_UNKNOWN}));
		make_move(Move'({6'd48, 6'd40, PROMO_UNKNOWN}));
		make_move(Move'({6'd16, 6'd24, PROMO_UNKNOWN}));
		make_move(Move'({6'd40, 6'd32, PROMO_UNKNOWN}));
		board_operation = BOARD_REVERSE_MOVE_OP;
		move_in = Move'($urandom_range(0, $bits(Move)-1));
		clock(2);
		if (1 == 1) begin // Random pause
			board_operation = BOARD_IDLE_OP;
			move_in = Move'($urandom_range(0, $bits(Move)-1));
			clock(0);
		end
		board_operation = BOARD_REVERSE_MOVE_OP;
		move_in = Move'($urandom_range(0, $bits(Move)-1));
		clock(2);
		board_operation = BOARD_IDLE_OP;
		move_in = Move'($urandom_range(0, $bits(Move)-1));
		clock(2);
		print_board();

		assert_true(tile_arr[8] === Tile'({WHITE, PAWN}), "Undo many moves was not successful");
		assert_true(tile_arr[9] === Tile'({WHITE, PAWN}), "Undo many moves was not successful");
		assert_true(tile_arr[48] === Tile'({BLACK, PAWN}), "Undo many moves was not successful");
		assert_true(tile_arr[49] === Tile'({BLACK, PAWN}), "Undo many moves was not successful");

		// --- Undo a castle move ---
		$display("=== Test Undo Castle Move ===");
		clock(10);
		board_operation = BOARD_REVERSE_MOVE_OP;
		move_in = Move'($urandom_range(0, $bits(Move)-1));
		clock();
		board_operation = BOARD_IDLE_OP;
		move_in = Move'($urandom_range(0, $bits(Move)-1));
		clock(2);
		print_board();

		assert_true(tile_arr[60] === Tile'({BLACK, KING}), "Undo Castle Move was not successful");
		assert_true(tile_arr[61].piece_type === NULL_PIECE, "Undo Castle Move was not successful");
		assert_true(tile_arr[62].piece_type === NULL_PIECE, "Undo Castle Move was not successful");
		assert_true(tile_arr[63] === Tile'({BLACK, ROOK}), "Undo Castle Move was not successful");


		// --- Undo a promotion ---
		$display("=== Test Undo Promotion Move ===");
		clock(10);
		board_operation = BOARD_REVERSE_MOVE_OP;
		move_in = Move'($urandom_range(0, $bits(Move)-1));
		clock();
		board_operation = BOARD_IDLE_OP;
		move_in = Move'($urandom_range(0, $bits(Move)-1));
		clock(2);
		print_board();

		assert_true(tile_arr[58] === Tile'({BLACK, BISHOP}), "Undo Promotion Move was not successful");
		assert_true(tile_arr[51] === Tile'({WHITE, PAWN}), "Undo Promotion Move was not successful");


		// --- Undo En Passant Move ---
		$display("=== Test Undo En Passant ===");
		clock(10);
		board_operation = BOARD_REVERSE_MOVE_OP;
		move_in = Move'($urandom_range(0, $bits(Move)-1));
		clock(6);
		board_operation = BOARD_IDLE_OP;
		move_in = Move'($urandom_range(0, $bits(Move)-1));
		clock(2);
		print_board();

		assert_true(tile_arr[36] === Tile'({BLACK, PAWN}), "Undo En Passant was not successful");
		assert_true(tile_arr[37] === Tile'({WHITE, PAWN}), "Undo En Passant was not successful");
		assert_true(tile_arr[44].piece_type === NULL_PIECE, "Undo En Passant was not successful");


		// --- Undo Remaining Moves ---
		$display("=== Test Remaining Moves ===");
		clock(10);
		board_operation = BOARD_REVERSE_MOVE_OP;
		move_in = Move'($urandom_range(0, $bits(Move)-1));
		clock(5);
		board_operation = BOARD_IDLE_OP;
		move_in = Move'($urandom_range(0, $bits(Move)-1));
		clock(2);
		print_board();

		// Check that pieces are reset
		for (int pos=0; pos<64; pos+=1) begin
			if (pos < 16 || pos > 40) begin
				assert_true(tile_arr[pos] === starting_tiles[pos], "Board failed to reset somewhere");
			end else begin
				assert_true(tile_arr[pos].piece_type === NULL_PIECE, "Board failed to reset somewhere");
			end
		end

		// -- Check board setting are reset --
		// Check correct turn
		assert_true(dut.turn === WHITE, "Turn not correctly set to WHITE");


		// Check castle permissions
		assert_true(dut.castle_perms === 4'b1111, "Castle permissions not correctly set");

		// Check correct en passant value
		assert_true(dut.has_ep === 1'b0, "Incorrectly starts with en passant");

		// Check reseting halfmove clock
		assert_true(dut.halfmove_clock === 7'd0, "Fails to reset halfmove clock");


		// --- Test basic move generation ---
		$display("=== Test Basic Move Generation ===");
		clock(10);

		make_move(Move'({6'd8, 6'd24, PROMO_UNKNOWN}));

		in_search = 1'b1;
		move_counter = 0;
		// move_output = Move'({6'd0, 6'd1, PROMO_UNKNOWN});	// Random, non-null move

		// There should be 20 possible moves
		for (int i=0; i<20; i+=1) begin
			board_operation = BOARD_GET_BEST_MOVE_OP;
			clock();
			move_output = best_move;
			$display("%0d->%0d (%1b)", move_output.start_pos, move_output.end_pos, move_output.promo_piece);
			make_move(best_move);
			board_operation = BOARD_REVERSE_MOVE_OP;
			clock();
		end

		// Check 20th move is a non-NULL move
		assert_true(~isNullMove(move_output), "Fails to generate 20 moves");

		board_operation = BOARD_GET_BEST_MOVE_OP;
		clock();
		move_output = best_move;
		$display("%0d->%0d (%1b)", move_output.start_pos, move_output.end_pos, move_output.promo_piece);

		// Check 21th move is a NULL move
		assert_true(isNullMove(move_output), "Fails to generate 20 moves");


		board_operation = BOARD_IDLE_OP;
		move_in = Move'($urandom_range(0, $bits(Move)-1));
		clock(2);
		print_board();


		// --- Test Reading from Board ---
		board_operation = BOARD_GET_TILE_OCCUPANCY_OP;
		move_in.end_pos = 6'd0;
		clock(1);
		assert_true(data_out === {WHITE, ROOK}, "Failed to read tile (rook)");

		move_in.end_pos = 6'd8;
		clock(1);
		assert_true(data_out.piece_type === NULL_PIECE, "Failed to read tile (empty)");

		move_in.end_pos = 6'd24;
		clock(1);
		assert_true(data_out === {WHITE, PAWN}, "Failed to read tile (pawn)");

		board_operation = BOARD_READ_TURN_OP;
		clock(1);
		assert_true(data_out[0] === BLACK, "Failed to read turn");

		board_operation = BOARD_READ_CASTLE_OP;
		clock(1);
		assert_true(data_out === 4'b1111, "Failed to read castle perms");

		board_operation = BOARD_READ_EN_PASSANT_OP;
		clock(1);
		assert_true(data_out === {1'b1, 3'd0}, "Failed to read en passent");

		board_operation = BOARD_READ_LSB_HM_CLOCK_OP;
		clock(1);
		assert_true(data_out === 4'd0, "Failed to read LSB on halfmove clock");

		board_operation = BOARD_READ_MSB_HM_CLOCK_OP;
		clock(1);
		assert_true(data_out[2:0] === 3'd0, "Failed to read MSB on halfmove clock");


		// Display Results
		$display("Pass Count: %0d", passCount);
		$display("Fail Count: %0d", failCount);
		$display("Pass Rate : %0.2f%%", 100.0 * passCount / (passCount + failCount));
		$stop();
	end

endmodule : tb_board
