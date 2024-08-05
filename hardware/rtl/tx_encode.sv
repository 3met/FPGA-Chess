
// By Emet Behrendt

import engine_defs::*;

// Takes data byte in and transmits out with UART
// Indicates readiness for new input with `ready` signal
// Reads `tx_stream` when ready and `tx_stream_valid` asserted
// Does not require inputs to be held
module uart_transmitter
	#(
		parameter BAUD_RATE,
		parameter CLOCK_FREQ
	)
	(
		input clk,
		input rst_n,
		input [7:0] tx_stream,
		input tx_stream_valid,
		output ready,
		output uart_tx
	);

	// Calculate CLKS_PER_BIT with rounding to nearest int
	localparam int CLKS_PER_BIT = (CLOCK_FREQ + (BAUD_RATE/2)) / BAUD_RATE;

	// FSM States
	typedef enum {
		UART_IDLE,
		UART_START,
		UART_DATA,
		UART_STOP
	} UartTxStageType;

	UartTxStageType uart_stage;

	reg [7:0] data_packet;
	reg [2:0] bit_index;

	reg [$clog2(CLKS_PER_BIT)-1:0] tx_timer;

	// --- data_packet copies data from tx_stream when ready and valid ---
	always_ff @(posedge clk) begin
		if (~rst_n) begin
			data_packet <= 8'dx;
		end else if (ready && tx_stream_valid) begin
			data_packet <= tx_stream;
		end
	end


	// --- uart_tx based on stage ---
	always_comb begin
		case (uart_stage)
			UART_IDLE:  uart_tx <= 1'b1;
			UART_START: uart_tx <= 1'b0;
			UART_DATA:  uart_tx <= data_packet[bit_index];
			UART_STOP:  uart_tx <= 1'b1;
			default:    uart_tx <= 1'b1;
		endcase
	end

	// --- Steps though FSM stages with timer ---
	always_ff @(posedge clk) begin
		// Reset variable
		if (~rst_n) begin
			uart_stage <= UART_IDLE;
			tx_timer <= 'dx;
			bit_index <= 3'dx;

		// Idles until tx_stream_valid is asserted, the UART_START begins
		end else if (uart_stage == UART_IDLE) begin

			bit_index <= 3'dx;

			if (tx_stream_valid) begin
				uart_stage <= UART_START;
				tx_timer <= 'd0;
			end else begin
				tx_timer <= 'dx;
			end

		// Asserts low for UART_START bit
		end else if (uart_stage == UART_START) begin
			if (tx_timer == CLKS_PER_BIT-1) begin
				uart_stage <= UART_DATA;
				tx_timer <= 'd0;
				bit_index <= 3'd0;
			end else begin
				tx_timer <= tx_timer + 'd1;
				bit_index <= 3'dx;
			end

		// Asserts each data bit for appropriate duration
		// Exits after last data bit
		end else if (uart_stage == UART_DATA) begin

			if (tx_timer == CLKS_PER_BIT-1) begin
				tx_timer <= 'd0;
				bit_index <= bit_index + 3'd1;

				if (bit_index == 3'd7) begin
					uart_stage <= UART_STOP;
				end

			end else begin
				tx_timer <= tx_timer + 'd1;
			end

		// Asserts high for UART_STOP bit
		end else if (uart_stage == UART_STOP) begin

			if (tx_timer == CLKS_PER_BIT-1) begin
				tx_timer <= 'd0;

				if (tx_stream_valid) begin
					uart_stage <= UART_START;
				end else begin
					uart_stage <= UART_IDLE;
				end

			end else begin
				tx_timer <= tx_timer + 'd1;
			end
		end
	end

	// --- Update ready signal based on State ---
	always_comb begin
		if (uart_stage == UART_IDLE) begin
			ready = 1'b1;
		end else if (uart_stage == UART_STOP && tx_timer == CLKS_PER_BIT-1) begin
			ready = 1'b1;
		end else begin
			ready = 1'b0;
		end
	end

endmodule : uart_transmitter


module tx_encoder
	#(
		parameter BAUD_RATE,
		parameter CLOCK_FREQ
	)
	(
		input clk,
		input rst_n,
		input [7:0] tx_stream,
		input tx_stream_valid,
		output uart_tx,
		output full
	);

	uart_transmitter #(.BAUD_RATE(BAUD_RATE), .CLOCK_FREQ(CLOCK_FREQ)) engine_uart_transmitter (
		.clk(clk),
		.rst_n(rst_n),
		.tx_stream(tx_stream),
		.tx_stream_valid(tx_stream_valid),
		.ready(),
		.uart_tx(uart_tx)
	);



endmodule : tx_encoder
