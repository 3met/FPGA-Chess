
// FPGA-Chess
// By Emet Behrendt

// This file maps the DE1-SoC ports to the engine module.
// The file also controls the LEDs and HEX displays on the DE1.
// Lastly, this file contains configuration information for the engine.

module de1_soc(input CLOCK_50,
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
	assign uart_clk = CLOCK_50;

	// --- UART Input Decoding ---
	wire [7:0] rx_stream;
	wire rx_stream_valid;
	reg [7:0] mem;

	wire rx_error;
	wire remote_reset;
	wire engine_rst_n;
	wire tx_full;
	wire engine_ready;
	wire engine_error;
	wire [7:0] engine_data_out;
	wire engine_data_out_valid;
	assign engine_rst_n = rst_n && !remote_reset;

	rx_decode #(
		.BAUD_RATE(BAUD_RATE),
		.UART_CLOCK_FREQ(UART_CLOCK_FREQ)
	) rx_decode (
		.clk(clk),
		.uart_clk(uart_clk),
		.rst_n(rst_n),
		.uart_rx(GPIO_0[9]),
		.mark_read(rx_stream_valid && engine_ready),
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

	// --- Engine Core ---
	engine #(
		.CLOCK_FREQ(ENGINE_CLOCK_FREQ),
		.SEARCH_THREAD_COUNT(1),
		.SEARCH_STACK_DEPTH(8),
		.ENABLE_PERFT(1'b1),
		.ENABLE_ZOBRIST(1'b1),
		.ENABLE_TT(1'b1),
		.ENABLE_PST(1'b1)
	) engine (
		.clk(clk),
		.rst_n(engine_rst_n),
		.data_in(rx_stream),
		.data_in_valid(rx_stream_valid),
		.kill(1'b0),
		.ready_for_result(!tx_full),
		.error_flag(engine_error),
		.ready(engine_ready),
		.data_out(engine_data_out),
		.data_out_valid(engine_data_out_valid)
	);



	// --- UART Output Encoding ---
	tx_encode #(
		.BAUD_RATE(BAUD_RATE),
		.UART_CLOCK_FREQ(UART_CLOCK_FREQ)
	) tx_encode (
		.clk(clk),
		.uart_clk(uart_clk),
		.rst_n(engine_rst_n),
		.tx_stream(engine_data_out),
		.tx_stream_valid(engine_data_out_valid),
		.uart_tx(GPIO_0[7]),
		.full(tx_full)
	);

	function automatic logic [6:0] hex_digit(input logic [3:0] value);
		case (value)
			4'h0: hex_digit = 7'b1000000;
			4'h1: hex_digit = 7'b1111001;
			4'h2: hex_digit = 7'b0100100;
			4'h3: hex_digit = 7'b0110000;
			4'h4: hex_digit = 7'b0011001;
			4'h5: hex_digit = 7'b0010010;
			4'h6: hex_digit = 7'b0000010;
			4'h7: hex_digit = 7'b1111000;
			4'h8: hex_digit = 7'b0000000;
			4'h9: hex_digit = 7'b0010000;
			4'hA: hex_digit = 7'b0001000;
			4'hB: hex_digit = 7'b0000011;
			4'hC: hex_digit = 7'b1000110;
			4'hD: hex_digit = 7'b0100001;
			4'hE: hex_digit = 7'b0000110;
			default: hex_digit = 7'b0001110;
		endcase
	endfunction

	always_comb begin
		LEDR = 10'b0;
		HEX0 = 7'h7f;
		HEX1 = 7'h7f;
		HEX2 = 7'h7f;
		HEX3 = 7'h7f;
		HEX4 = 7'h7f;
		HEX5 = 7'h7f;
		if (!SW[9]) begin
			LEDR[7:0] = mem;
			LEDR[8] = rx_error | remote_reset | tx_full | engine_error;
			LEDR[9] = ~pll_locked_status;
			HEX0 = hex_digit(mem[3:0]);
			HEX1 = hex_digit(mem[7:4]);
			HEX2 = hex_digit({1'b0, engine_error, tx_full, rx_error});
			HEX3 = hex_digit({1'b0, remote_reset, engine_ready, pll_locked_status});
		end
	end

endmodule : de1_soc
