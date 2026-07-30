
// FPGA-Chess
// By Emet Behrendt

// This file maps the DE1-SoC ports to the engine module.
// The file also controls the LEDs and HEX displays on the DE1.
// Lastly, this file contains configuration information for the engine.

import tt_defs::*;

module de1_soc(input CLOCK_50,
            input [3:0] KEY, input [9:0] SW,
            inout wire [35:0] GPIO_0,
            output logic [6:0] HEX0, output logic [6:0] HEX1,
            output logic [6:0] HEX2, output logic [6:0] HEX3,
            output logic [6:0] HEX4, output logic [6:0] HEX5,
            output logic [9:0] LEDR,
            output logic [12:0] DRAM_ADDR, output logic [1:0] DRAM_BA,
            output logic DRAM_CAS_N, output logic DRAM_CKE, output logic DRAM_CLK,
            output logic DRAM_CS_N, inout wire [15:0] DRAM_DQ,
            output logic DRAM_LDQM, output logic DRAM_RAS_N, output logic DRAM_UDQM,
            output logic DRAM_WE_N
            );

	parameter UART_CLOCK_FREQ = 100_000_000;
	parameter BAUD_RATE = 2_000_000;
	parameter ENABLE_SEARCH_STATS = 1'b0;
	parameter int unsigned LMR_A_Q8 = 192;
	parameter int unsigned LMR_B_Q8 = 614;

	// The build target generates this value from its engine_clock_mhz setting.
	`include "engine_clock_config.svh"

	wire rst_n;
	assign rst_n = KEY[3];

	wire clk;
	wire memory_clk;
	wire memory_output_clk;
	wire memory_read_clk;
	wire uart_clk;
	// Hold the PLL in reset immediately when configuration enters user mode,
	// before the startup controller receives its first reference-clock edge.
	logic pll_reset = 1'b1;
	wire pll_locked_status;
	pll_ip pll_1(.refclk(CLOCK_50), .rst(pll_reset), .outclk_0(clk),
		.outclk_1(memory_clk), .outclk_2(memory_output_clk), .outclk_3(memory_read_clk),
		.locked(pll_locked_status));
	assign DRAM_CLK = memory_output_clk;
	// Only GPIO_0[7] and GPIO_0[9] are the UART TX/RX pins. Keep the other
	// header pins explicitly high impedance rather than leaving bidirectional
	// ports structurally undriven.
	assign GPIO_0[35:10] = 'z;
	assign GPIO_0[8:8] = 1'bz;
	assign GPIO_0[6:0] = 'z;
	// Reuse the PLL's zero-phase 100 MHz memory clock for finer UART sampling.
	assign uart_clk = memory_clk;

	localparam int PLL_RESET_HOLD_CYCLES = 1024;
	localparam int PLL_LOCK_STABLE_CYCLES = 256;
	localparam int PLL_LOCK_TIMEOUT_CYCLES = 1_000_000;

	typedef enum logic [1:0] {
		PLL_HOLD_RESET,
		PLL_WAIT_LOCK,
		PLL_RUNNING
	} PllStartupState;

	PllStartupState pll_startup_state = PLL_HOLD_RESET;
	logic [19:0] pll_timeout_count = '0;
	logic [9:0] pll_reset_count = '0;
	logic [7:0] pll_lock_count = '0;
	logic pll_locked_meta = 1'b0;
	logic pll_locked_sync = 1'b0;

	// Automatically reset and retry the PLL so JTAG configuration never
	// depends on either board reset button having been pressed.
	always_ff @(posedge CLOCK_50) begin
		if (!rst_n) begin
			pll_locked_meta <= 1'b0;
			pll_locked_sync <= 1'b0;
		end else begin
			pll_locked_meta <= pll_locked_status;
			pll_locked_sync <= pll_locked_meta;
		end
	end

	always_ff @(posedge CLOCK_50) begin
		if (!rst_n || !KEY[2]) begin
			pll_startup_state <= PLL_HOLD_RESET;
			pll_timeout_count <= '0;
			pll_reset_count <= '0;
			pll_lock_count <= '0;
			pll_reset <= 1'b1;
		end else begin
			case (pll_startup_state)
				PLL_HOLD_RESET: begin
					pll_reset <= 1'b1;
					pll_timeout_count <= '0;
					pll_lock_count <= '0;
					if (pll_reset_count == 10'(PLL_RESET_HOLD_CYCLES - 1)) begin
						pll_reset_count <= '0;
						pll_reset <= 1'b0;
						pll_startup_state <= PLL_WAIT_LOCK;
					end else begin
						pll_reset_count <= pll_reset_count + 10'd1;
					end
				end

				PLL_WAIT_LOCK: begin
					pll_reset <= 1'b0;
					pll_timeout_count <= pll_timeout_count + 20'd1;
					if (pll_locked_sync) begin
						if (pll_lock_count == 8'(PLL_LOCK_STABLE_CYCLES - 1)) begin
							pll_lock_count <= '0;
							pll_startup_state <= PLL_RUNNING;
						end else begin
							pll_lock_count <= pll_lock_count + 8'd1;
						end
					end else begin
						pll_lock_count <= '0;
					end
					if (pll_timeout_count == 20'(PLL_LOCK_TIMEOUT_CYCLES - 1)) begin
						pll_startup_state <= PLL_HOLD_RESET;
						pll_timeout_count <= '0;
						pll_reset_count <= '0;
						pll_lock_count <= '0;
						pll_reset <= 1'b1;
					end
				end

				PLL_RUNNING: begin
					pll_reset <= 1'b0;
					pll_timeout_count <= '0;
					if (pll_locked_sync) begin
						pll_lock_count <= '0;
					end else if (pll_lock_count == 8'(PLL_LOCK_STABLE_CYCLES - 1)) begin
						pll_startup_state <= PLL_HOLD_RESET;
						pll_reset_count <= '0;
						pll_lock_count <= '0;
						pll_reset <= 1'b1;
					end else begin
						pll_lock_count <= pll_lock_count + 8'd1;
					end
				end

				default: begin
					pll_startup_state <= PLL_HOLD_RESET;
					pll_reset_count <= '0;
					pll_reset <= 1'b1;
				end
			endcase
		end
	end

	// --- UART Input Decoding ---
	wire [7:0] rx_stream;
	wire rx_stream_valid;
	reg [7:0] mem;

	wire rx_error;
	wire remote_reset;
	wire engine_domain_rst_n;
	wire uart_domain_rst_n;
	wire engine_rst_n;
	wire memory_rst_n;
	wire uart_tx_rst_n;
	wire engine_core_rst_n;
	wire tx_full;
	wire engine_ready;
	wire engine_error;
	wire [7:0] engine_data_out;
	wire engine_data_out_valid;
	logic [7:0] tx_response_byte_count;
	logic tt_memory_ready, tt_memory_error;
	logic tt_mem_req_valid, tt_mem_req_ready, tt_mem_req_write;
	TTWordAddress tt_mem_req_address;
	logic [3:0] tt_mem_req_length;
	logic tt_mem_write_valid, tt_mem_write_ready, tt_mem_write_last;
	logic [15:0] tt_mem_write_data;
	logic tt_mem_read_valid, tt_mem_read_ready, tt_mem_read_last;
	logic [15:0] tt_mem_read_data;
	logic tt_mem_done_valid, tt_mem_done_ready, tt_mem_done_error;
	logic backend_req_valid, backend_req_ready, backend_req_write;
	TTWordAddress backend_req_address;
	logic [3:0] backend_req_length;
	logic backend_write_valid, backend_write_ready, backend_write_last;
	logic [15:0] backend_write_data;
	logic backend_read_valid, backend_read_ready, backend_read_last;
	logic [15:0] backend_read_data;
	logic backend_done_valid, backend_done_ready, backend_done_error;
	logic tt_memory_ready_backend, tt_memory_error_backend;
	assign engine_core_rst_n = engine_rst_n && tt_memory_ready && !tt_memory_error;

	// Each domain releases reset on its own clock only after PLL lock has
	// remained stable. UART BREAK then applies the same stretched reset to
	// the engine, memory bridge/controller, and transmit path.
	reset_release engine_startup_reset (
		.clk(clk),
		.async_reset_n(rst_n && pll_startup_state == PLL_RUNNING),
		.reset_n(engine_domain_rst_n)
	);
	reset_release uart_startup_reset (
		.clk(uart_clk),
		.async_reset_n(rst_n && pll_startup_state == PLL_RUNNING),
		.reset_n(uart_domain_rst_n)
	);
	reset_release engine_operational_reset (
		.clk(clk),
		.async_reset_n(engine_domain_rst_n && !remote_reset),
		.reset_n(engine_rst_n)
	);
	reset_release memory_operational_reset (
		.clk(memory_clk),
		.async_reset_n(rst_n && pll_startup_state == PLL_RUNNING && !remote_reset),
		.reset_n(memory_rst_n)
	);
	reset_release uart_tx_operational_reset (
		.clk(uart_clk),
		.async_reset_n(uart_domain_rst_n && !remote_reset),
		.reset_n(uart_tx_rst_n)
	);

	// Count engine response bytes accepted by the UART transmit path for board bring-up.
	always_ff @(posedge clk) begin
		if (!engine_rst_n) begin
			tx_response_byte_count <= 8'h00;
		end else if (engine_data_out_valid && !tx_full) begin
			tx_response_byte_count <= tx_response_byte_count + 8'h01;
		end
	end

	rx_decode #(
		.BAUD_RATE(BAUD_RATE),
		.UART_CLOCK_FREQ(UART_CLOCK_FREQ)
	) rx_decode (
		.clk(clk),
		.uart_clk(uart_clk),
		.engine_rst_n(engine_domain_rst_n),
		.uart_rst_n(uart_domain_rst_n),
		.uart_rx(GPIO_0[9]),
		.mark_read(rx_stream_valid && engine_ready),
		.rx_stream(rx_stream),
		.rx_stream_valid(rx_stream_valid),
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
		.SEARCH_STACK_DEPTH(32),
		.LMR_A_Q8(LMR_A_Q8),
		.LMR_B_Q8(LMR_B_Q8),
		.EXTERNAL_TT(1'b1),
		.ENABLE_SEARCH_STATS(ENABLE_SEARCH_STATS)
	) engine (
		.clk(clk),
		.rst_n(engine_core_rst_n),
		.data_in(rx_stream),
		.data_in_valid(rx_stream_valid),
		.ready_for_result(!tx_full),
		.error_flag(engine_error),
		.ready(engine_ready),
		.data_out(engine_data_out),
		.data_out_valid(engine_data_out_valid),
		.tt_memory_ready(tt_memory_ready), .tt_memory_error(tt_memory_error),
		.tt_mem_req_valid(tt_mem_req_valid), .tt_mem_req_ready(tt_mem_req_ready),
		.tt_mem_req_write(tt_mem_req_write), .tt_mem_req_address(tt_mem_req_address), .tt_mem_req_length(tt_mem_req_length),
		.tt_mem_write_valid(tt_mem_write_valid), .tt_mem_write_ready(tt_mem_write_ready),
		.tt_mem_write_data(tt_mem_write_data), .tt_mem_write_last(tt_mem_write_last),
		.tt_mem_read_valid(tt_mem_read_valid), .tt_mem_read_ready(tt_mem_read_ready),
		.tt_mem_read_data(tt_mem_read_data), .tt_mem_read_last(tt_mem_read_last),
		.tt_mem_done_valid(tt_mem_done_valid), .tt_mem_done_ready(tt_mem_done_ready), .tt_mem_done_error(tt_mem_done_error)
	);

	tt_memory_cdc_bridge tt_memory_bridge (
		.req_clk(clk), .req_rst_n(engine_rst_n), .mem_clk(memory_clk), .mem_rst_n(memory_rst_n),
		.backend_ready(tt_memory_ready_backend), .backend_error(tt_memory_error_backend),
		.req_memory_ready(tt_memory_ready), .req_memory_error(tt_memory_error),
		.req_valid(tt_mem_req_valid), .req_ready(tt_mem_req_ready), .req_write(tt_mem_req_write),
		.req_address(tt_mem_req_address), .req_length(tt_mem_req_length),
		.write_valid(tt_mem_write_valid), .write_ready(tt_mem_write_ready), .write_data(tt_mem_write_data), .write_last(tt_mem_write_last),
		.read_valid(tt_mem_read_valid), .read_ready(tt_mem_read_ready), .read_data(tt_mem_read_data), .read_last(tt_mem_read_last),
		.done_valid(tt_mem_done_valid), .done_ready(tt_mem_done_ready), .done_error(tt_mem_done_error),
		.backend_req_valid(backend_req_valid), .backend_req_ready(backend_req_ready), .backend_req_write(backend_req_write),
		.backend_req_address(backend_req_address), .backend_req_length(backend_req_length),
		.backend_write_valid(backend_write_valid), .backend_write_ready(backend_write_ready),
		.backend_write_data(backend_write_data), .backend_write_last(backend_write_last),
		.backend_read_valid(backend_read_valid), .backend_read_ready(backend_read_ready),
		.backend_read_data(backend_read_data), .backend_read_last(backend_read_last),
		.backend_done_valid(backend_done_valid), .backend_done_ready(backend_done_ready), .backend_done_error(backend_done_error));

	sdr_sdram_controller #(.CLOCK_FREQ(100_000_000)) tt_sdram (
		.clk(memory_clk), .read_capture_clk(memory_read_clk), .rst_n(memory_rst_n),
		.ready(tt_memory_ready_backend), .error(tt_memory_error_backend),
		.req_valid(backend_req_valid), .req_ready(backend_req_ready), .req_write(backend_req_write),
		.req_address(backend_req_address), .req_length(backend_req_length),
		.write_valid(backend_write_valid), .write_ready(backend_write_ready),
		.write_data(backend_write_data), .write_last(backend_write_last),
		.read_valid(backend_read_valid), .read_ready(backend_read_ready),
		.read_data(backend_read_data), .read_last(backend_read_last),
		.done_valid(backend_done_valid), .done_ready(backend_done_ready), .done_error(backend_done_error),
		.dram_addr(DRAM_ADDR), .dram_ba(DRAM_BA), .dram_cas_n(DRAM_CAS_N), .dram_cke(DRAM_CKE),
		.dram_cs_n(DRAM_CS_N), .dram_dq(DRAM_DQ), .dram_ldqm(DRAM_LDQM),
		.dram_ras_n(DRAM_RAS_N), .dram_udqm(DRAM_UDQM), .dram_we_n(DRAM_WE_N));



	// --- UART Output Encoding ---
	tx_encode #(
		.BAUD_RATE(BAUD_RATE),
		.UART_CLOCK_FREQ(UART_CLOCK_FREQ)
	) tx_encode (
		.clk(clk),
		.uart_clk(uart_clk),
		.engine_rst_n(engine_rst_n),
		.uart_rst_n(uart_tx_rst_n),
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
			LEDR[8] = rx_error | remote_reset | tx_full | engine_error | tt_memory_error;
			LEDR[9] = ~pll_locked_status;
			HEX0 = hex_digit(mem[3:0]);
			HEX1 = hex_digit(mem[7:4]);
			HEX2 = hex_digit({1'b0, engine_error, tx_full, rx_error});
			HEX3 = hex_digit({1'b0, remote_reset, engine_ready, pll_locked_status});
			HEX4 = hex_digit(tx_response_byte_count[3:0]);
			HEX5 = hex_digit(tx_response_byte_count[7:4]);
		end
	end

endmodule : de1_soc
