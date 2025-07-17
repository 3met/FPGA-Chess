
// By Emet Behrendt

// The board_hist module stores a record of moves so they can be undone
// Cannot read and write at the same time
// Reads and writes in one clock cycle

// Internal memory block takes two cycles to read or write
// Able to continuously read one value per cycle due to 2 MoveRecord caches


package board_hist_defs;

	import general_chess_defs::*;

	typedef enum {
		NORM_MOVE,   // Move is a normal move
		PROMO_MOVE,  // Move is promotion
		EP_MOVE,     // Move is an en passant kill
		CASTLE_MOVE  // Move is a castle
	} MoveFlag;

	// ---- Data Type to store Move History ----
	typedef struct packed {
		Position start_pos;         // Move start position
		Position end_pos;           // Move end position
		PieceType killed_piece;
		CastlePerms castle_perms;   // Castle perms before move
		MoveFlag move_flag;         // Flag indicating special moves
		logic has_ep;               // Position contains an en passant kill tile
		BoardFile ep_file;          // En passant file
		logic [6:0] halfmove_clock; // Halfmove clock before 
	} MoveRecord;	// 32 bits total
endpackage : board_hist_defs

import board_hist_defs::*;


module board_hist #(parameter MEM_SIZE=512) (
		input wire clk,
		input wire rst_n,
		input wire wr_en,
		input MoveRecord move_record_in,
		input wire pop_move,
		output MoveRecord move_record_out,
		output logic is_full
	);

	// Internal Registers
	reg [$clog2(MEM_SIZE)-1: 0] size;
	MoveRecord mem_out;
	MoveRecord buffer_out, buffer_mid;
	reg is_buffer_mid_valid;
	reg is_last_cycle_wr;
	logic [$clog2(MEM_SIZE)-1: 0] rd_addr;

	// --- Compute size ---
	always_ff @(posedge clk) begin : proc_size
		if(~rst_n) begin
			size <= 0;
		// Don't care what happens what happens when
		// wr_en and pop_move are both asserted
		end else if (wr_en && pop_move) begin
			size <= 'dx;
		end else if (wr_en) begin
			size <= size + 'd1;
		end else if (pop_move) begin
			size <= size - 'd1;
		end
	end

	// --- Update buffer_out ---
	always_ff @(posedge clk) begin : proc_buffer_out
		if(~rst_n) begin
			buffer_out <= MoveRecord'('dx);
		end else if (wr_en && pop_move) begin
			buffer_out <= MoveRecord'('dx);
		end else if (wr_en) begin
			buffer_out <= move_record_in;
		end else if (pop_move && is_buffer_mid_valid) begin
			buffer_out <= buffer_mid;
		end else if (pop_move && ~is_buffer_mid_valid) begin
			buffer_out <= mem_out;
		end
	end

	// --- Update buffer_mid ---
	always_ff @(posedge clk) begin : proc_buffer_mid
		if(~rst_n) begin
			buffer_mid <= MoveRecord'('dx);
		end else if (wr_en && pop_move) begin
			buffer_mid <= MoveRecord'('dx);
		end else if (wr_en) begin
			buffer_mid <= buffer_out;
		end else if (pop_move && is_buffer_mid_valid) begin
			buffer_mid <= mem_out;
		end else if (pop_move && ~is_buffer_mid_valid) begin
			buffer_mid <= MoveRecord'('dx);
		end else if (~pop_move && ~is_buffer_mid_valid) begin
			buffer_mid <= mem_out;
		end
	end

	// --- Update is_buffer_mid_valid ---
	always_ff @(posedge clk) begin : proc_is_buffer_mid_valid
		if(~rst_n) begin
			is_buffer_mid_valid <= 1'b0;
		end else if (pop_move && wr_en) begin
			is_buffer_mid_valid <= 1'bx;
		end else if (wr_en) begin
			is_buffer_mid_valid <= 1'b1;
		end else if (is_last_cycle_wr && pop_move) begin
			is_buffer_mid_valid <= 1'b0;
		end else if (pop_move) begin
			is_buffer_mid_valid <= is_buffer_mid_valid;
		end else if (~pop_move) begin
			is_buffer_mid_valid <= 1'b1;
		end
	end

	// --- Update is_last_cycle_wr ---
	always_ff @(posedge clk) begin
		is_last_cycle_wr <= wr_en;
	end

	// --- Update Read Addr ---
	always_comb begin : proc_rd_addr
		if (wr_en && pop_move) begin
			rd_addr = 'dx;
		end else if (is_buffer_mid_valid && ~is_last_cycle_wr && pop_move) begin
			rd_addr = size - 'd4;
		end else if (is_buffer_mid_valid) begin
			rd_addr = size - 'd3;
		end else if (~is_last_cycle_wr) begin
			rd_addr = size - 'd3;
		end else begin
			rd_addr = size - 'd2;
		end
	end


	// --- Instantiate Internal Memory Block ---
	ram_1_port #(.WORD_SIZE($bits(MoveRecord)), .NUM_WORDS(MEM_SIZE)) move_mem (
		.address((wr_en==1'b1) ? size : rd_addr),
		.clock(clk),
		.data(move_record_in),
		.wren(wr_en),
		.q(mem_out)
	);

	// Indicate when memory is full
	assign is_full = (size + 'd1 == 0);

	// Output content of buffer
	assign move_record_out = buffer_out;

endmodule : board_hist
