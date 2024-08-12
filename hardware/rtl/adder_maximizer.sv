
// By Emet Behrendt


// --- Define operation codes ---
package adder_maximizer_defs;
	typedef enum logic {
		GET_SUM=1'd0,
		GET_MAX=1'd1
	} AddMaxOp;
endpackage : adder_maximizer_defs

import adder_maximizer_defs::*;

// GET_MAX Mode
// - Calculates the maximum of UNSIGNED inputs
// - Passes along paired data, outputs data paired with max key
// - In the case of a tie, returns the lowest index
//
// GET_SUM Mode
// - Calculates the sum of SIGNED inputs
module adder_maximizer #(INPUT_KEY_WIDTH=8, OUTPUT_KEY_WIDTH=8, DATA_WIDTH=8) 
	(
		input  AddMaxOp operation,
		input  logic [INPUT_KEY_WIDTH-1:0] key_in[64],
		input  logic [DATA_WIDTH-1:0] data_in[64],
		output logic [OUTPUT_KEY_WIDTH-1:0] key_out,
		output logic [DATA_WIDTH-1:0] data_out,
		output logic overflow
	);

	// Returns max of two values
	function max(int a, int b);
		return (a > b) ? a : b;
	endfunction : max

	// --- Internal Wires ---
	localparam KEY0_WIDTH = max(INPUT_KEY_WIDTH+1, OUTPUT_KEY_WIDTH);
	wire [KEY0_WIDTH-1:0] key0_out[32];
	wire [DATA_WIDTH-1:0] data0[32];
	wire overflow0[32];

	localparam KEY1_WIDTH = max(INPUT_KEY_WIDTH+2, OUTPUT_KEY_WIDTH);
	wire [KEY1_WIDTH-1:0] key1_in[32];
	wire [KEY1_WIDTH-1:0] key1_out[16];
	wire [DATA_WIDTH-1:0] data1[16];
	wire overflow1[16];

	localparam KEY2_WIDTH = max(INPUT_KEY_WIDTH+3, OUTPUT_KEY_WIDTH);
	wire [KEY2_WIDTH-1:0] key2_in[16];
	wire [KEY2_WIDTH-1:0] key2_out[8];
	wire [DATA_WIDTH-1:0] data2[8];
	wire overflow2[8];

	localparam KEY3_WIDTH = max(INPUT_KEY_WIDTH+4, OUTPUT_KEY_WIDTH);
	wire [KEY3_WIDTH-1:0] key3_in[8];
	wire [KEY3_WIDTH-1:0] key3_out[4];
	wire [DATA_WIDTH-1:0] data3[4];
	wire overflow3[4];

	localparam KEY4_WIDTH = max(INPUT_KEY_WIDTH+5, OUTPUT_KEY_WIDTH);
	wire [KEY4_WIDTH-1:0] key4_in[4];
	wire [KEY4_WIDTH-1:0] key4_out[2];
	wire [DATA_WIDTH-1:0] data4[2];
	wire overflow4[2];

	wire [KEY4_WIDTH-1:0] key5_in[2];
	wire [KEY4_WIDTH-1:0] key5_out;
	wire overflow5;

	// \.data([ab])\(key(.+)\[i(.*)\]\)
	// .data$1(signed'(key$2[i$3])),

	// --- Compute Keys ---
	generate
		for (genvar i=0; i<64; i+=2) begin : sum_max_layer_0
			add_sub #(.DATA_WIDTH(KEY0_WIDTH)) add_sub_layer_0 (
				.add_sub(operation),
				.dataa(signed'(key_in[i])),
				.datab(signed'(key_in[i+1])),
				.overflow(overflow0[i/2]),
				.result(key0_out[i/2])
			);

			assign data0[i/2] = (key0_out[i/2][KEY0_WIDTH-1] == 1'b0) ? data_in[i] : data_in[i+1];
			assign key1_in[i/2] = (operation==GET_SUM) ? (key0_out[i/2]) : (key0_out[i/2][KEY0_WIDTH-1] == 1'b0) ? key_in[i] : key_in[i+1];
		end

		for (genvar i=0; i<32; i+=2) begin : sum_max_layer_1
			add_sub #(.DATA_WIDTH(KEY1_WIDTH)) add_sub_layer_1 (
				.add_sub(operation),
				.dataa(signed'(key1_in[i])),
				.datab(signed'(key1_in[i+1])),
				.overflow(overflow1[i/2]),
				.result(key1_out[i/2])
			);

			assign data1[i/2] = (key1_out[i/2][KEY1_WIDTH-1] == 1'b0) ? data0[i] : data0[i+1];
			assign key2_in[i/2] = (operation==GET_SUM) ? (key1_out[i/2]) : (key1_out[i/2][KEY1_WIDTH-1] == 1'b0) ? key1_in[i] : key1_in[i+1];
		end

		for (genvar i=0; i<16; i+=2) begin : sum_max_layer_2
			add_sub #(.DATA_WIDTH(KEY2_WIDTH)) add_sub_layer_2 (
				.add_sub(operation),
				.dataa(signed'(key2_in[i])),
				.datab(signed'(key2_in[i+1])),
				.overflow(overflow2[i/2]),
				.result(key2_out[i/2])
			);

			assign data2[i/2] = (key2_out[i/2][KEY2_WIDTH-1] == 1'b0) ? data1[i] : data1[i+1];
			assign key3_in[i/2] = (operation==GET_SUM) ? (key2_out[i/2]) : (key2_out[i/2][KEY2_WIDTH-1] == 1'b0) ? key2_in[i] : key2_in[i+1];
		end

		for (genvar i=0; i<8; i+=2) begin : sum_max_layer_3
			add_sub #(.DATA_WIDTH(KEY3_WIDTH)) add_sub_layer_3 (
				.add_sub(operation),
				.dataa(signed'(key3_in[i])),
				.datab(signed'(key3_in[i+1])),
				.overflow(overflow3[i/2]),
				.result(key3_out[i/2])
			);

			assign data3[i/2] = (key3_out[i/2][KEY3_WIDTH-1] == 1'b0) ? data2[i] : data2[i+1];
			assign key4_in[i/2] = (operation==GET_SUM) ? (key3_out[i/2]) : (key3_out[i/2][KEY3_WIDTH-1] == 1'b0) ? key3_in[i] : key3_in[i+1];
		end

		for (genvar i=0; i<4; i+=2) begin : sum_max_layer_4
			add_sub #(.DATA_WIDTH(KEY4_WIDTH)) add_sub_layer_4 (
				.add_sub(operation),
				.dataa(signed'(key4_in[i])),
				.datab(signed'(key4_in[i+1])),
				.overflow(overflow4[i/2]),
				.result(key4_out[i/2])
			);

			assign data4[i/2] = (key4_out[i/2][KEY4_WIDTH-1] == 1'b0) ? data3[i] : data3[i+1];
			assign key5_in[i/2] = (operation==GET_SUM) ? (key4_out[i/2]) : (key4_out[i/2][KEY4_WIDTH-1] == 1'b0) ? key4_in[i] : key4_in[i+1];
		end

		add_sub #(.DATA_WIDTH(OUTPUT_KEY_WIDTH)) add_sub_layer_5 (
			.add_sub(operation),
			.dataa(signed'(key5_in[i])),
			.datab(signed'(key5_in[i+1])),
			.overflow(overflow5),
			.result(key5_out)
		);

		assign data_out = (key5_out[OUTPUT_KEY_WIDTH-1] == 1'b0) ? data4[i] : data4[i+1];
		assign key_out = (operation==GET_SUM) ? (key5_out) : (key5_out[OUTPUT_KEY_WIDTH-1] == 1'b0) ? key5_in[i] : key5_in[i+1];

	endgenerate


	// --- Compute Overflow ---
	always_comb begin
		overflow = 1'b0;

		for (int i=0; i<32; i+=1) begin
			overflow |= overflow0[i];
		end

		for (int i=0; i<16; i+=1) begin
			overflow |= overflow1[i];
		end

		for (int i=0; i<8; i+=1) begin
			overflow |= overflow2[i];
		end

		for (int i=0; i<4; i+=1) begin
			overflow |= overflow3[i];
		end

		for (int i=0; i<2; i+=1) begin
			overflow |= overflow4[i];
		end

		overflow |= overflow5;
	end


endmodule : adder_maximizer
