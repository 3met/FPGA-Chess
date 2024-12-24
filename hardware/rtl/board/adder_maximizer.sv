
// By Emet Behrendt

// This file contains the adder_maximizer module.
// This module has two operations: add, and get_max.
// For add, the module returns the sum of all 64 inputs.
// For max, the modules returns the maximum of the 64 inputs
// and the data associated with it. More details found below.


// --- Define operation codes ---
package adder_maximizer_defs;
	typedef enum logic {
		GET_AM_MAX=1'd0,
		GET_AM_SUM=1'd1
	} AddMaxOp;
endpackage : adder_maximizer_defs

import adder_maximizer_defs::*;

// GET_AM_MAX Mode
// - Calculates the maximum of UNSIGNED inputs
// - Passes along paired data, outputs data paired with max key
// - In the case of a tie, returns the lowest index
//
// GET_AM_SUM Mode
// - Calculates the sum of SIGNED inputs
module adder_maximizer #(INPUT_KEY_WIDTH=8, OUTPUT_KEY_WIDTH=8, DATA_WIDTH=8) 
	(
		input  AddMaxOp operation,
		input  logic signed [INPUT_KEY_WIDTH-1:0] key_in[64],
		input  logic [DATA_WIDTH-1:0] data_in[64],
		output logic signed [OUTPUT_KEY_WIDTH-1:0] key_out,
		output logic [DATA_WIDTH-1:0] data_out
	);

	// Returns min of two values
	function automatic int min(int a, int b);
		return (a < b) ? a : b;
	endfunction : min


	// --- Internal Wires ---
	localparam KEY0_WIDTH = min(INPUT_KEY_WIDTH+1, OUTPUT_KEY_WIDTH);
	wire signed [KEY0_WIDTH-1:0] key0_out[32];
	wire [DATA_WIDTH-1:0] data0[32];
	wire overflow0[32];

	localparam KEY1_WIDTH = min(INPUT_KEY_WIDTH+2, OUTPUT_KEY_WIDTH);
	wire signed [KEY1_WIDTH-1:0] key1_in[32];
	wire signed [KEY1_WIDTH-1:0] key1_out[16];
	wire [DATA_WIDTH-1:0] data1[16];
	wire overflow1[16];

	localparam KEY2_WIDTH = min(INPUT_KEY_WIDTH+3, OUTPUT_KEY_WIDTH);
	wire signed [KEY2_WIDTH-1:0] key2_in[16];
	wire signed [KEY2_WIDTH-1:0] key2_out[8];
	wire [DATA_WIDTH-1:0] data2[8];
	wire overflow2[8];

	localparam KEY3_WIDTH = min(INPUT_KEY_WIDTH+4, OUTPUT_KEY_WIDTH);
	wire signed [KEY3_WIDTH-1:0] key3_in[8];
	wire signed [KEY3_WIDTH-1:0] key3_out[4];
	wire [DATA_WIDTH-1:0] data3[4];
	wire overflow3[4];

	localparam KEY4_WIDTH = min(INPUT_KEY_WIDTH+5, OUTPUT_KEY_WIDTH);
	wire signed [KEY4_WIDTH-1:0] key4_in[4];
	wire signed [KEY4_WIDTH-1:0] key4_out[2];
	wire [DATA_WIDTH-1:0] data4[2];
	wire overflow4[2];

	wire signed [OUTPUT_KEY_WIDTH-1:0] key5_in[2];
	wire signed [OUTPUT_KEY_WIDTH-1:0] key5_out;
	wire overflow5;

	// \.data([ab])\(key(.+)\[i(.*)\]\)
	// .data$1(signed'(key$2[i$3])),

	// --- Compute Keys ---
	generate
		for (genvar i=0; i<64; i+=2) begin : sum_max_layer_0
			add_sub #(.DATA_WIDTH(KEY0_WIDTH)) add_sub_layer_0 (
				.add_sub(operation),
				.dataa(KEY0_WIDTH'(key_in[i])),
				.datab(KEY0_WIDTH'(key_in[i+1])),
				.overflow(overflow0[i/2]),
				.result(key0_out[i/2])
			);

			assign data0[i/2] = (overflow0[i/2]) ? data_in[i+1] : data_in[i];
			assign key1_in[i/2] = (operation==GET_AM_SUM) ? (key0_out[i/2]) : (overflow0[i/2]) ? key_in[i+1] : key_in[i];
		end

		for (genvar i=0; i<32; i+=2) begin : sum_max_layer_1
			add_sub #(.DATA_WIDTH(KEY1_WIDTH)) add_sub_layer_1 (
				.add_sub(operation),
				.dataa(KEY1_WIDTH'(key1_in[i])),
				.datab(KEY1_WIDTH'(key1_in[i+1])),
				.overflow(overflow1[i/2]),
				.result(key1_out[i/2])
			);

			assign data1[i/2] = (overflow1[i/2]) ? data0[i+1] : data0[i];
			assign key2_in[i/2] = (operation==GET_AM_SUM) ? (key1_out[i/2]) : (overflow1[i/2]) ? key1_in[i+1] : key1_in[i];
		end

		for (genvar i=0; i<16; i+=2) begin : sum_max_layer_2
			add_sub #(.DATA_WIDTH(KEY2_WIDTH)) add_sub_layer_2 (
				.add_sub(operation),
				.dataa(KEY2_WIDTH'(key2_in[i])),
				.datab(KEY2_WIDTH'(key2_in[i+1])),
				.overflow(overflow2[i/2]),
				.result(key2_out[i/2])
			);

			assign data2[i/2] = (overflow2[i/2]) ? data1[i+1] : data1[i];
			assign key3_in[i/2] = (operation==GET_AM_SUM) ? (key2_out[i/2]) : (overflow2[i/2]) ? key2_in[i+1] : key2_in[i];
		end

		for (genvar i=0; i<8; i+=2) begin : sum_max_layer_3
			add_sub #(.DATA_WIDTH(KEY3_WIDTH)) add_sub_layer_3 (
				.add_sub(operation),
				.dataa(KEY3_WIDTH'(key3_in[i])),
				.datab(KEY3_WIDTH'(key3_in[i+1])),
				.overflow(overflow3[i/2]),
				.result(key3_out[i/2])
			);

			assign data3[i/2] = (overflow3[i/2]) ? data2[i+1] : data2[i];
			assign key4_in[i/2] = (operation==GET_AM_SUM) ? (key3_out[i/2]) : (overflow3[i/2]) ? key3_in[i+1] : key3_in[i];
		end

		for (genvar i=0; i<4; i+=2) begin : sum_max_layer_4
			add_sub #(.DATA_WIDTH(KEY4_WIDTH)) add_sub_layer_4 (
				.add_sub(operation),
				.dataa(KEY4_WIDTH'(key4_in[i])),
				.datab(KEY4_WIDTH'(key4_in[i+1])),
				.overflow(overflow4[i/2]),
				.result(key4_out[i/2])
			);

			assign data4[i/2] = (overflow4[i/2]) ? data3[i+1] : data3[i];
			assign key5_in[i/2] = (operation==GET_AM_SUM) ? (key4_out[i/2]) : (overflow4[i/2]) ? key4_in[i+1] : key4_in[i];
		end

		add_sub #(.DATA_WIDTH(OUTPUT_KEY_WIDTH)) add_sub_layer_5 (
			.add_sub(operation),
			.dataa(OUTPUT_KEY_WIDTH'(key5_in[0])),
			.datab(OUTPUT_KEY_WIDTH'(key5_in[1])),
			.overflow(overflow5),
			.result(key5_out)
		);

		assign data_out = (overflow5) ? data4[1] : data4[0];
		assign key_out = (operation==GET_AM_SUM) ? key5_out : (overflow5) ? key5_in[1][INPUT_KEY_WIDTH-1:0] : key5_in[0][INPUT_KEY_WIDTH-1:0];

	endgenerate

endmodule : adder_maximizer
