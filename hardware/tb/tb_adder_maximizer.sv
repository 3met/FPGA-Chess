
`timescale 1ns / 1ps

import adder_maximizer_defs::*;

module tb_adder_maximizer();

	localparam INPUT_KEY_WIDTH = 8;
	localparam OUTPUT_KEY_WIDTH = 10;
	localparam DATA_WIDTH = 4;

	AddMaxOp op;
	logic [INPUT_KEY_WIDTH-1:0] key_in[64];
	logic [DATA_WIDTH-1:0] data_in[64];
	logic [OUTPUT_KEY_WIDTH-1:0] key_out;
	logic [DATA_WIDTH-1:0] data_out;
	logic [OUTPUT_KEY_WIDTH-1:0] expected_key_out;
	logic [DATA_WIDTH-1:0] expected_data_out;

	adder_maximizer dut	(
		.operation(op),
		.key_in(key_in),
		.data_in(data_in),
		.key_out(key_out),
		.data_out(data_out),
		.overflow()
	);

	defparam dut.INPUT_KEY_WIDTH = INPUT_KEY_WIDTH;
	defparam dut.OUTPUT_KEY_WIDTH = OUTPUT_KEY_WIDTH;
	defparam dut.DATA_WIDTH = DATA_WIDTH;

	// Scoring Variables
	int passCount = 0;
	int failCount = 0;

	initial begin
		
		#10;

		op = GET_SUM;

		for (int i=0; i<100; i+=1) begin
			for (int j=0; j<100; j+=1) begin
				expected_key_out = 0;
				// Randomize input
				for (int k=0; i<64; k+=1) begin
					key_in[k] = $random % (2**INPUT_KEY_WIDTH);
					data_in[k] = $random % (2**DATA_WIDTH);

					if (op == GET_SUM) begin
						expected_key_out += key_in[k];

					end else if (op == GET_MAX) begin
						expected_data_out = (key_in[k] > expected_key_out) ? data_in[k] : expected_data_out;
						expected_key_out = (key_in[k] > expected_key_out) ? key_in[k] : expected_key_out;
					end

					#10;

					assert (key_out == expected_key_out) begin
						passCount += 1;
					end else begin
						failCount += 1;
						$error("[FAIL] expected_key_out");
					end

					if (op == GET_MAX) begin
						assert (data_out == expected_data_out) begin
							passCount += 1;
						end else begin
							failCount += 1;
							$error("[FAIL] expected_data_out");
						end
					end
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
