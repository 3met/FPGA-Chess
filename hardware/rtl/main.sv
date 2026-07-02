
// FPGA-Chess
// By Emet Behrendt

// This file maps the ports DE1-SoC to the engine module.
// The file also controls the LEDs and HEX displays on the DE1.
// Lastly, this file contains configuration information for the engine.

module main(input CLOCK_50,
            input [3:0] KEY, input [9:0] SW,
            input GPIO_0[36],
            output logic [6:0] HEX0, output logic [6:0] HEX1,
            output logic [6:0] HEX2, output logic [6:0] HEX3,
            output logic [6:0] HEX4, output logic [6:0] HEX5,
            output logic [9:0] LEDR
            );

	parameter CLOCK_FREQ = 100_000_000;	// Main clock at 100 MHz

	wire rst_n;
	assign rst_n = KEY[3];

	wire clk;
	wire pll_reset, pll_locked_status;
	pll_ip pll_1(.refclk(CLOCK_50), .rst(pll_reset), .outclk_0(clk), .locked(pll_locked_status));
	assign pll_reset = ~KEY[2];
	assign LEDR[9] = ~pll_locked_status;



	// --- UART Input Decoding ---
	wire [7:0] rx_stream;
	wire rx_stream_valid;
	reg [7:0] mem;
	assign LEDR[7:0] = mem;

	// parameter BAUD_RATE = 1_000_000;
	parameter BAUD_RATE = 12_000_000;

	rx_decode #(.BAUD_RATE(BAUD_RATE), .CLOCK_FREQ(CLOCK_FREQ)) rx_decode (
		.clk(clk),
		.rst_n(rst_n),
		.uart_rx(GPIO_0[9]),
		.mark_read(),
		.rx_stream(rx_stream),
		.rx_stream_valid(rx_stream_valid),
		.kill(),
		.remote_reset(),
		.error()
	);

	always_ff @(posedge clk) begin
		if (~rst_n) begin
			mem <= 0;
		end else if (rx_stream_valid) begin
			mem <= rx_stream;
		end
	end

	

	// --- UART Output Encoding ---
	uart_transmitter #(.BAUD_RATE(BAUD_RATE), .CLOCK_FREQ(CLOCK_FREQ)) engine_uart_transmitter (
		.clk(clk),
		.rst_n(rst_n),
		.tx_stream(rx_stream),
		.tx_stream_valid(rx_stream_valid),
		.ready(),
		.uart_tx(GPIO_0[7])
	);



endmodule : main

