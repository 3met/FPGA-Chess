
// By Emet Behrendt

`timescale 1ns / 1ps

import engine_defs::*;
import board_defs::*;

// Run in modelsim with:
// vsim -L altera_mf -L lpm -L 220model work.tb_board
// restart -f; run -all

module tb_board();

	// DUT signals
	logic clk = 0;
	logic rst_n = 1'b1;
	BoardOp board_operation = IDLE_BOARD_OP;
	logic [3:0] data_in;
	Move move_in = NULL_MOVE;
	logic in_search = 0;
	logic ready;
	logic illegal_board;
	Move best_move;
	BoardEvalScore board_score;
	Tile tile_data_out;

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
		.tile_data_out(tile_data_out)
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
		board_operation = PLACE_PIECE_OP;
		data_in = Tile'({UNKNOWN_COLOR, NULL_PIECE});

		for (int pos=0; pos<64; pos+=1) begin
			move_in.end_pos = Position'(pos);
			clock();
		end
		board_operation = IDLE_BOARD_OP;
	endtask : clear_board


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
		board_operation = PLACE_PIECE_OP;
		data_in = Tile'({WHITE, ROOK});
		move_in.end_pos = Position'(0);
		clock();
		data_in = Tile'({WHITE, KNIGHT});
		move_in.end_pos = Position'(1);
		clock();
		data_in = Tile'({WHITE, BISHOP});
		move_in.end_pos = Position'(2);
		clock();
		data_in = Tile'({WHITE, QUEEN});
		move_in.end_pos = Position'(3);
		clock();
		data_in = Tile'({WHITE, KING});
		move_in.end_pos = Position'(4);
		clock();
		data_in = Tile'({WHITE, BISHOP});
		move_in.end_pos = Position'(5);
		clock();
		data_in = Tile'({WHITE, KNIGHT});
		move_in.end_pos = Position'(6);
		clock();
		data_in = Tile'({WHITE, ROOK});
		move_in.end_pos = Position'(7);
		clock();
		data_in = Tile'({WHITE, PAWN});
		move_in.end_pos = Position'(8);
		clock();
		data_in = Tile'({WHITE, PAWN});
		move_in.end_pos = Position'(9);
		clock();
		data_in = Tile'({WHITE, PAWN});
		move_in.end_pos = Position'(10);
		clock();
		data_in = Tile'({WHITE, PAWN});
		move_in.end_pos = Position'(11);
		clock();
		data_in = Tile'({WHITE, PAWN});
		move_in.end_pos = Position'(12);
		clock();
		data_in = Tile'({WHITE, PAWN});
		move_in.end_pos = Position'(13);
		clock();
		data_in = Tile'({WHITE, PAWN});
		move_in.end_pos = Position'(14);
		clock();
		data_in = Tile'({WHITE, PAWN});
		move_in.end_pos = Position'(15);
		clock();
		data_in = Tile'({BLACK, ROOK});
		move_in.end_pos = Position'(63);
		clock();
		data_in = Tile'({BLACK, KNIGHT});
		move_in.end_pos = Position'(62);
		clock();
		data_in = Tile'({BLACK, BISHOP});
		move_in.end_pos = Position'(61);
		clock();
		data_in = Tile'({BLACK, KING});
		move_in.end_pos = Position'(60);
		clock();
		data_in = Tile'({BLACK, QUEEN});
		move_in.end_pos = Position'(59);
		clock();
		data_in = Tile'({BLACK, BISHOP});
		move_in.end_pos = Position'(58);
		clock();
		data_in = Tile'({BLACK, KNIGHT});
		move_in.end_pos = Position'(57);
		clock();
		data_in = Tile'({BLACK, ROOK});
		move_in.end_pos = Position'(56);
		clock();
		data_in = Tile'({BLACK, PAWN});
		move_in.end_pos = Position'(55);
		clock();
		data_in = Tile'({BLACK, PAWN});
		move_in.end_pos = Position'(54);
		clock();
		data_in = Tile'({BLACK, PAWN});
		move_in.end_pos = Position'(53);
		clock();
		data_in = Tile'({BLACK, PAWN});
		move_in.end_pos = Position'(52);
		clock();
		data_in = Tile'({BLACK, PAWN});
		move_in.end_pos = Position'(51);
		clock();
		data_in = Tile'({BLACK, PAWN});
		move_in.end_pos = Position'(50);
		clock();
		data_in = Tile'({BLACK, PAWN});
		move_in.end_pos = Position'(49);
		clock();
		data_in = Tile'({BLACK, PAWN});
		move_in.end_pos = Position'(48);
		clock(2);

		for (int i=0; i<64; i+=1) begin
			starting_tiles[i] <= tile_arr[i];
		end

		// Setup remaining game state variables
		board_operation = WRITE_TURN_OP;
		data_in = {3'bx, WHITE};
		clock();
		board_operation = WRITE_CASTLE_OP;
		data_in = 4'b1111;
		clock();
		board_operation = WRITE_EN_PASSANT_OP;
		data_in = 4'b0xxx;
		clock();
		board_operation = WRITE_LSB_HM_CLOCK_OP;
		data_in = 4'b0000;
		clock();
		board_operation = WRITE_MSB_HM_CLOCK_OP;
		data_in = 4'bx000;
		clock();
		board_operation = IDLE_BOARD_OP;
		clock(20);

		// Check correct turn
		assert (dut.turn === WHITE) begin
			passCount += 1;
		end else begin
			failCount += 1;
			$error("Turn not correctly set to WHITE");
		end

		// Check castle permissions
		assert (dut.castle_perms === 4'b1111) begin
			passCount += 1;
		end else begin
			failCount += 1;
			$error("Castle permissions not correctly set");
		end

		// Check correct en passant value
		assert (dut.has_ep === 1'b0) begin
			passCount += 1;
		end else begin
			failCount += 1;
			$error("Incorrectly starts with en passant");
		end

		// Check reseting halfmove clock
		assert (dut.halfmove_clock === 7'd0) begin
			passCount += 1;
		end else begin
			failCount += 1;
			$error("Fails to reset halfmove clock");
		end

		print_board();

		// -- Testing Moves --
		$display("=== Testing Moves ===");

		// Move 1, e2e4
		board_operation = MAKE_MOVE_OP;
		move_in = Move'({6'd12, 6'd28, PROMO_UNKNOWN});
		clock();
		board_operation = IDLE_BOARD_OP;
		clock();
		print_board();

		// Check correct turn
		assert (dut.turn === BLACK) begin
			passCount += 1;
		end else begin
			failCount += 1;
			$error("Turn not correctly updated to BLACK");
		end

		// Check pawn moved to new square
		assert (tile_arr[28] === Tile'({WHITE, PAWN})) begin
			passCount += 1;
		end else begin
			failCount += 1;
			$error("Pawn not moved successfully");
		end
		assert (tile_arr[12].piece_type === NULL_PIECE) begin
			passCount += 1;
		end else begin
			failCount += 1;
			$error("Pawn not moved successfully");
		end

		// Check castle permissions
		assert (dut.castle_perms === 4'b1111) begin
			passCount += 1;
		end else begin
			failCount += 1;
			$error("Castle permissions not correctly set");
		end

		// Check updating en passant status
		assert (dut.has_ep === 1'b1) begin
			passCount += 1;
		end else begin
			failCount += 1;
			$error("Fails to recognize en passant");
		end

		// Check correct en passant file
		assert (dut.ep_file === BoardFile'(3'd4)) begin
			passCount += 1;
		end else begin
			failCount += 1;
			$error("Incorrect en passant file");
		end

		// Check reseting halfmove clock
		assert (dut.halfmove_clock === 7'd0) begin
			passCount += 1;
		end else begin
			failCount += 1;
			$error("Fails to reset halfmove clock");
		end

		// Move 2: f7f5
		board_operation = MAKE_MOVE_OP;
		move_in = Move'({6'd53, 6'd37, PROMO_UNKNOWN});
		clock();
		board_operation = IDLE_BOARD_OP;
		clock();
		print_board();

		// Check correct turn
		assert (dut.turn === WHITE) begin
			passCount += 1;
		end else begin
			failCount += 1;
			$error("Turn not correctly updated to BLACK");
		end

		// Check pawn moved to new square
		assert (tile_arr[37] === Tile'({BLACK, PAWN})) begin
			passCount += 1;
		end else begin
			failCount += 1;
			$error("Pawn not moved successfully");
		end
		assert (tile_arr[53].piece_type === NULL_PIECE) begin
			passCount += 1;
		end else begin
			failCount += 1;
			$error("Pawn not moved successfully");
		end

		// Move 3: e4f5
		board_operation = MAKE_MOVE_OP;
		move_in = Move'({6'd28, 6'd37, PROMO_UNKNOWN});
		clock();
		board_operation = IDLE_BOARD_OP;
		clock();
		print_board();

		// Check pawn moved to new square
		assert (tile_arr[37] === Tile'({WHITE, PAWN})) begin
			passCount += 1;
		end else begin
			failCount += 1;
			$error("Pawn not moved successfully");
		end
		assert (tile_arr[28].piece_type === NULL_PIECE) begin
			passCount += 1;
		end else begin
			failCount += 1;
			$error("Pawn not moved successfully");
		end

		// Moves 4-5: e7e5, f5e6
		board_operation = MAKE_MOVE_OP;
		move_in = Move'({6'd52, 6'd36, PROMO_UNKNOWN});
		clock();
		board_operation = MAKE_MOVE_OP;
		move_in = Move'({6'd37, 6'd44, PROMO_UNKNOWN});
		clock();
		board_operation = IDLE_BOARD_OP;
		clock(2);
		print_board();

		// Check correct turn
		assert (dut.turn === BLACK) begin
			passCount += 1;
		end else begin
			failCount += 1;
			$error("Turn not correctly updated to BLACK");
		end
		// Check en passant kill
		assert (tile_arr[44] === Tile'({WHITE, PAWN})) begin
			passCount += 1;
		end else begin
			failCount += 1;
			$error("En Passant kill was not successfully");
		end
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
		assert (dut.halfmove_clock === 7'd0) begin
			passCount += 1;
		end else begin
			failCount += 1;
			$error("Fails to reset halfmove clock");
		end

		// Move 6-8: g8f6, e6d7, f8c5
		board_operation = MAKE_MOVE_OP;
		move_in = Move'({6'd62, 6'd45, PROMO_UNKNOWN});
		clock();
		board_operation = MAKE_MOVE_OP;
		move_in = Move'({6'd44, 6'd51, PROMO_UNKNOWN});
		clock();
		board_operation = MAKE_MOVE_OP;
		move_in = Move'({6'd61, 6'd34, PROMO_UNKNOWN});
		clock();
		board_operation = MAKE_MOVE_OP;
		move_in = Move'({6'd51, 6'd58, PROMO_QUEEN});
		clock();
		board_operation = IDLE_BOARD_OP;
		clock();
		print_board();

		assert (tile_arr[58].piece_type === QUEEN) begin
			passCount += 1;
		end else begin
			failCount += 1;
			$error("Promotion not successful");
		end

		// Move 9: e8g8 (Black king castle)
		board_operation = MAKE_MOVE_OP;
		move_in = Move'({6'd60, 6'd62, PROMO_UNKNOWN});
		clock();
		board_operation = IDLE_BOARD_OP;
		clock(2);

		print_board();

		assert (   tile_arr[60].piece_type === NULL_PIECE
			    && tile_arr[61] === Tile'({BLACK, ROOK})
			    && tile_arr[62] === Tile'({BLACK, KING})
		        && tile_arr[63].piece_type === NULL_PIECE) begin
			passCount += 1;
		end else begin
			failCount += 1;
			$error("Castling move not successful");
		end
		assert (   dut.castle_perms.whiteKingside
			    && dut.castle_perms.whiteQueenside
			    && ~dut.castle_perms.blackKingside
			    && ~dut.castle_perms.blackQueenside) begin
			passCount += 1;
		end else begin
			failCount += 1;
			$error("Castling perm updates not successful");
		end

		// Make and undo normal move: b2b4
		$display("=== Test Revese Move ===");
		board_operation = MAKE_MOVE_OP;
		move_in = Move'({6'd9, 6'd25, PROMO_UNKNOWN});
		clock();
		board_operation = REVERSE_MOVE_OP;
		move_in = Move'($urandom_range(0, $bits(Move)-1));
		clock();
		board_operation = IDLE_BOARD_OP;
		clock();
		print_board();

		assert (   tile_arr[25].piece_type === NULL_PIECE
			    && tile_arr[9] === Tile'({WHITE, PAWN})) begin
			passCount += 1;
		end else begin
			failCount += 1;
			$error("Reverse move was not successful");
		end
		assert (dut.turn == WHITE) begin
			passCount += 1;
		end else begin
			failCount += 1;
			$error("Reverse move was not successful");
		end

		// Make and undo kill move: b2b4, c5b4
		$display("=== Test Revese Kill Move ===");
		board_operation = MAKE_MOVE_OP;
		move_in = Move'({6'd9, 6'd25, PROMO_UNKNOWN});
		clock();
		board_operation = MAKE_MOVE_OP;
		move_in = Move'({6'd34, 6'd25, PROMO_UNKNOWN});
		clock();
		board_operation = REVERSE_MOVE_OP;
		move_in = Move'($urandom_range(0, $bits(Move)-1));
		clock(2);
		board_operation = REVERSE_MOVE_OP;
		move_in = Move'($urandom_range(0, $bits(Move)-1));
		clock();
		board_operation = IDLE_BOARD_OP;
		clock(2);
		print_board();

		assert (   tile_arr[25].piece_type === NULL_PIECE
			    && tile_arr[9] === Tile'({WHITE, PAWN})
			    && tile_arr[34] === Tile'({BLACK, BISHOP})) begin
			passCount += 1;
		end else begin
			failCount += 1;
			$error("Reverse kill move was not successful");
		end


		// Make and several moves: a2a3, a7a6, a3a4, a6a5
		$display("=== Test Undo Many Moves ===");
		clock(10);
		board_operation = MAKE_MOVE_OP;
		move_in = Move'({6'd8, 6'd16, PROMO_UNKNOWN});
		clock();
		move_in = Move'({6'd48, 6'd40, PROMO_UNKNOWN});
		clock();
		move_in = Move'({6'd16, 6'd24, PROMO_UNKNOWN});
		clock();
		move_in = Move'({6'd40, 6'd32, PROMO_UNKNOWN});
		clock();
		board_operation = REVERSE_MOVE_OP;
		move_in = Move'($urandom_range(0, $bits(Move)-1));
		clock(2);
		if (1 == 1) begin // Random pause
			board_operation = IDLE_BOARD_OP;
			move_in = Move'($urandom_range(0, $bits(Move)-1));
			clock(0);
		end
		board_operation = REVERSE_MOVE_OP;
		move_in = Move'($urandom_range(0, $bits(Move)-1));
		clock(2);
		board_operation = IDLE_BOARD_OP;
		move_in = Move'($urandom_range(0, $bits(Move)-1));
		clock(2);
		print_board();

		assert (   tile_arr[8] === Tile'({WHITE, PAWN})
			    && tile_arr[9] === Tile'({WHITE, PAWN})
			    && tile_arr[48] === Tile'({BLACK, PAWN})
			    && tile_arr[49] === Tile'({BLACK, PAWN})) begin
			passCount += 1;
		end else begin
			failCount += 1;
			$error("Undo many moves was not successful");
		end


		// --- Undo a castle move ---
		$display("=== Test Undo Castle Move ===");
		clock(10);
		board_operation = REVERSE_MOVE_OP;
		move_in = Move'($urandom_range(0, $bits(Move)-1));
		clock();
		board_operation = IDLE_BOARD_OP;
		move_in = Move'($urandom_range(0, $bits(Move)-1));
		clock(2);
		print_board();

		assert (   tile_arr[60] === Tile'({BLACK, KING})
			    && tile_arr[61].piece_type === NULL_PIECE
			    && tile_arr[62].piece_type === NULL_PIECE
			    && tile_arr[63] === Tile'({BLACK, ROOK})) begin
			passCount += 1;
		end else begin
			failCount += 1;
			$error("Undo Castle Move was not successful");
		end


		// --- Undo a promotion ---
		$display("=== Test Undo Promotion Move ===");
		clock(10);
		board_operation = REVERSE_MOVE_OP;
		move_in = Move'($urandom_range(0, $bits(Move)-1));
		clock();
		board_operation = IDLE_BOARD_OP;
		move_in = Move'($urandom_range(0, $bits(Move)-1));
		clock(2);
		print_board();

		assert (   tile_arr[58] === Tile'({BLACK, BISHOP})
			    && tile_arr[51] === Tile'({WHITE, PAWN})) begin
			passCount += 1;
		end else begin
			failCount += 1;
			$error("Undo Promotion Move was not successful");
		end


		// --- Undo En Passant Move ---
		$display("=== Test Undo En Passant ===");
		clock(10);
		board_operation = REVERSE_MOVE_OP;
		move_in = Move'($urandom_range(0, $bits(Move)-1));
		clock(6);
		board_operation = IDLE_BOARD_OP;
		move_in = Move'($urandom_range(0, $bits(Move)-1));
		clock(2);
		print_board();

		assert (   tile_arr[36] === Tile'({BLACK, PAWN})
			    && tile_arr[37] === Tile'({WHITE, PAWN})
			    && tile_arr[44].piece_type === NULL_PIECE) begin
			passCount += 1;
		end else begin
			failCount += 1;
			$error("Undo En Passant was not successful");
		end


		// --- Undo Remaining Moves ---
		$display("=== Test Remaining Moves ===");
		clock(10);
		board_operation = REVERSE_MOVE_OP;
		move_in = Move'($urandom_range(0, $bits(Move)-1));
		clock(5);
		board_operation = IDLE_BOARD_OP;
		move_in = Move'($urandom_range(0, $bits(Move)-1));
		clock(2);
		print_board();

		// Check that pieces are reset
		for (int pos=0; pos<64; pos+=1) begin
			if (pos < 16 || pos > 40) begin
				assert (tile_arr[pos] === starting_tiles[pos]) begin
					passCount += 1;
				end else begin
					failCount += 1;
					$error("Board failed to reset somewhere");
				end
			end else begin
				assert (tile_arr[pos].piece_type === NULL_PIECE) begin
					passCount += 1;
				end else begin
					failCount += 1;
					$error("Board failed to reset somewhere");
				end
			end
		end

		// -- Check board setting are reset --
		// Check correct turn
		assert (dut.turn === WHITE) begin
			passCount += 1;
		end else begin
			failCount += 1;
			$error("Turn not correctly set to WHITE");
		end

		// Check castle permissions
		assert (dut.castle_perms === 4'b1111) begin
			passCount += 1;
		end else begin
			failCount += 1;
			$error("Castle permissions not correctly set");
		end

		// Check correct en passant value
		assert (dut.has_ep === 1'b0) begin
			passCount += 1;
		end else begin
			failCount += 1;
			$error("Incorrectly starts with en passant");
		end

		// Check reseting halfmove clock
		assert (dut.halfmove_clock === 7'd0) begin
			passCount += 1;
		end else begin
			failCount += 1;
			$error("Fails to reset halfmove clock");
		end


		// --- Test basic move generation ---
		$display("=== Test Basic Move Generation ===");
		clock(10);
		board_operation = MAKE_MOVE_OP;
		move_in = Move'({6'd8, 6'd24, PROMO_UNKNOWN});
		clock();

		in_search = 1'b1;
		move_counter = 0;
		// move_output = Move'({6'd0, 6'd1, PROMO_UNKNOWN});	// Random, non-null move

		// There should be 20 possible moves
		for (int i=0; i<20; i+=1) begin
			board_operation = GET_BEST_MOVE_OP;
			clock();
			move_output = best_move;
			$display("%0d->%0d (%1b)", move_output.start_pos, move_output.end_pos, move_output.promo_piece);
			board_operation = MAKE_MOVE_OP;
			move_in = best_move;
			clock();
			board_operation = REVERSE_MOVE_OP;
			clock();
		end

		// Check 20th move is a non-NULL move
		assert (~isNullMove(move_output)) begin
			passCount += 1;
		end else begin
			failCount += 1;
			$error("Fails to generate 20 moves");
		end

		board_operation = GET_BEST_MOVE_OP;
		clock();
		move_output = best_move;
		$display("%0d->%0d (%1b)", move_output.start_pos, move_output.end_pos, move_output.promo_piece);

		// Check 21th move is a NULL move
		assert (isNullMove(move_output)) begin
			passCount += 1;
		end else begin
			failCount += 1;
			$error("Fails to generate 20 moves");
		end
		

		board_operation = IDLE_BOARD_OP;
		move_in = Move'($urandom_range(0, $bits(Move)-1));
		clock(2);
		print_board();



		// Display Results
		$display("Pass Count: %0d", passCount);
		$display("Fail Count: %0d", failCount);
		$display("Pass Rate : %0.2f%%", 100.0 * passCount / (passCount + failCount));
		$stop();
	end

endmodule : tb_board
