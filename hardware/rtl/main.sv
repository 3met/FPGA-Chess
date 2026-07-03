
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

	parameter ENGINE_CLOCK_FREQ = 100_000_000;	// Main clock at 100 MHz
	parameter UART_CLOCK_FREQ = 50_000_000;
	parameter BAUD_RATE = 2_000_000;

	wire rst_n;
	assign rst_n = KEY[3];

	wire clk;
	wire uart_clk;
	wire pll_reset, pll_locked_status;
	pll_ip pll_1(.refclk(CLOCK_50), .rst(pll_reset), .outclk_0(clk), .locked(pll_locked_status));
	assign pll_reset = ~KEY[2];
	assign LEDR[9] = ~pll_locked_status;
	assign uart_clk = CLOCK_50;



	// --- UART Input Decoding ---
	wire [7:0] rx_stream;
	wire rx_stream_valid;
	reg [7:0] mem;
	assign LEDR[7:0] = mem;

	wire rx_error;
	wire remote_reset;
	wire tx_full;

	rx_decode #(
		.BAUD_RATE(BAUD_RATE),
		.UART_CLOCK_FREQ(UART_CLOCK_FREQ)
	) rx_decode (
		.clk(clk),
		.uart_clk(uart_clk),
		.rst_n(rst_n),
		.uart_rx(GPIO_0[9]),
		.mark_read(rx_stream_valid && !tx_full),
		.rx_stream(rx_stream),
		.rx_stream_valid(rx_stream_valid),
		.kill(),
		.remote_reset(remote_reset),
		.error(rx_error)
	);

	always_ff @(posedge clk) begin
		if (~rst_n) begin
			mem <= 0;
		end else if (rx_stream_valid) begin
			mem <= rx_stream;
		end
	end

	assign LEDR[8] = rx_error | remote_reset | tx_full;

	

	// --- UART Output Encoding ---
	tx_encode #(
		.BAUD_RATE(BAUD_RATE),
		.UART_CLOCK_FREQ(UART_CLOCK_FREQ)
	) tx_encode (
		.clk(clk),
		.uart_clk(uart_clk),
		.rst_n(rst_n),
		.tx_stream(rx_stream),
		.tx_stream_valid(rx_stream_valid && !tx_full),
		.uart_tx(GPIO_0[7]),
		.full(tx_full)
	);



endmodule : main

