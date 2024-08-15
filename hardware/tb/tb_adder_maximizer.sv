
`timescale 1ns / 1ps

import adder_maximizer_defs::*;

// Run in modelsim with:
// vsim -L altera_mf -L lpm -L 220model work.tb_adder_maximizer
// restart -f; run -all

module tb_adder_maximizer();

	localparam int INPUT_KEY_WIDTH = 8;
	localparam int OUTPUT_KEY_WIDTH = 10;
	localparam int DATA_WIDTH = 4;

	AddMaxOp op;
	logic signed [INPUT_KEY_WIDTH-1:0] key_in[64];
	logic [DATA_WIDTH-1:0] data_in[64];
	logic signed [OUTPUT_KEY_WIDTH-1:0] key_out;
	logic [DATA_WIDTH-1:0] data_out;
	logic signed [OUTPUT_KEY_WIDTH-1:0] expected_key_out;
	logic [DATA_WIDTH-1:0] expected_data_out;

	adder_maximizer #(
		.INPUT_KEY_WIDTH(INPUT_KEY_WIDTH),
		.OUTPUT_KEY_WIDTH(OUTPUT_KEY_WIDTH),
		.DATA_WIDTH(DATA_WIDTH)
	) dut (
		.operation(op),
		.key_in(key_in),
		.data_in(data_in),
		.key_out(key_out),
		.data_out(data_out),
		.overflow()
	);


	// Scoring Variables
	int passCount = 0;
	int failCount = 0;

	initial begin
		
		op = GET_AM_SUM;

		// Loop between operation modes
		for (int i=0; i<100; i+=1) begin

			// Loop continuous operations
			for (int j=0; j<100; j+=1) begin
				expected_key_out = 0;
				// Randomize input
				for (int k=0; k<64; k+=1) begin
					key_in[k] = $random % (2**INPUT_KEY_WIDTH);
					data_in[k] = $random % (2**DATA_WIDTH);

					if (op == GET_AM_SUM) begin
						expected_key_out += key_in[k];

					end else if (op == GET_AM_MAX && unsigned'(key_in[k]) > unsigned'(expected_key_out)) begin
						expected_data_out = data_in[k];
						expected_key_out = unsigned'(key_in[k]);
					end
				end

				#10;

				if (op == GET_AM_SUM) begin
					assert (key_out == expected_key_out) begin
						passCount += 1;
					end else begin
						failCount += 1;
						$error("[FAIL] op=%0b, expected_key_out=%0d, key_out=%0d", op, expected_key_out, key_out);
					end

				end else if (op == GET_AM_MAX) begin
					assert (key_out == expected_key_out) begin
						passCount += 1;
					end else begin
						failCount += 1;
						$error("[FAIL] op=%0b, expected_key_out=%0d, key_out=%0d", op, unsigned'(expected_key_out), unsigned'(key_out));
					end

					assert (data_out == expected_data_out) begin
						passCount += 1;
					end else begin
						failCount += 1;
						$error("[FAIL] op=%0b, expected_data_out=%0d, data_out=%0d", op, expected_data_out, data_out);
					end

				end else begin
					$error("Unrecognized operation.");
				end
			end

			op = AddMaxOp'(~op);
		end

		// Display Results
		$display("Pass Count: %0d", passCount);
		$display("Fail Count: %0d", failCount);
		$display("Pass Rate : %0.2f%%", 100.0 * passCount / (passCount + failCount));
		$stop();
	end

endmodule : tb_adder_maximizer
