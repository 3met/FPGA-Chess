
// Do not change timescale
`timescale 1ns / 1ps

module tb_uart_receiver();

	localparam CLOCK_FREQ = 100_000_000;
	localparam BAUD_RATE = 12_000_000;
	// localparam BAUD_RATE = CLOCK_FREQ/6;

	logic clk = 1'b0;
	logic rst_n = 1'b1;

	logic uart_rx;

	logic [7:0] rx_stream;
	logic rx_stream_valid;
	logic uart_violation;

	always begin
		#((1E9/CLOCK_FREQ)/2);
		clk = ~clk;
	end

	uart_receiver #(.BAUD_RATE(BAUD_RATE), .CLOCK_FREQ(CLOCK_FREQ)) dut (
		.clk(clk),
		.rst_n(rst_n),
		.uart_rx(uart_rx),
		.rx_stream(rx_stream),
		.rx_stream_valid(rx_stream_valid),
		.uart_violation(uart_violation)
	);

	// Stores recent validated UART output
	reg [7:0] uart_output;

	always @(posedge clk) begin
		if (rx_stream_valid) uart_output <= rx_stream;
	end


	// -- Testbench Variables --
	logic [7:0] sent_data;
	// Scoring Variables
	int passCount = 0;
	int failCount = 0;


	function void verify_uart_output(logic [7:0] expected);
		assert(uart_output === expected) begin
			passCount += 1;
			// $display("[PASS] uart_output=%8b", uart_output);
		end else begin
			failCount += 1;
			$error("[FAIL] uart_output=%8b, expected=%8b", uart_output, expected);
		end
	endfunction : verify_uart_output


	// Send message via UART
	task send_uart_msg(input logic [7:0] data);
		// Start bit
		uart_rx = 1'b0;
		#(1E9/BAUD_RATE);
		// Data bits
		for (int i=0; i<8; i+=1) begin
			uart_rx = data[i];
			#(1E9/BAUD_RATE);
		end
		// Stop Bit
		uart_rx = 1'b1;
		#(1E9/BAUD_RATE);
	endtask : send_uart_msg


	initial begin
		$display("BAUD_RATE: %d", dut.BAUD_RATE);
		$display("CLOCK_FREQ: %d", dut.CLOCK_FREQ);

		uart_rx = 1'b1;

		#100;

		// Reset
		rst_n = 1'b0;
		#100;
		rst_n = 1'b1;
		#100;

		// Check valid always asserted properly
		uart_output = 8'hFF;
		#500;
		verify_uart_output(8'hFF);

		uart_output = 8'h00;
		#500;
		verify_uart_output(8'h00);

		for (int i=0; i<1000; i+=1) begin
			// Random delay to change offset from clock cycle
			#($urandom_range(0, 1E9/CLOCK_FREQ));

			// Check message transmitted properly
			for (int j=0; j<100; j+=1) begin
				sent_data = $urandom_range(8'h00,8'hFF);
				send_uart_msg(sent_data);
				verify_uart_output(sent_data);
			end
		end


		send_uart_msg(8'b10101010);
		#100000;
		verify_uart_output(8'b10101010);

		// Display Results
		$display("Pass Count: %0d", passCount);
		$display("Fail Count: %0d", failCount);
		$display("Pass Rate : %0.2f%%", 100.0 * passCount / (passCount + failCount));
		$stop();
	end

endmodule : tb_uart_receiver

