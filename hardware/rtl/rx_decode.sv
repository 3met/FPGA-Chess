
// By Emet Behrendt

import general_chess_defs::*;

// Receives UART RX one bit at a time
// Outputs data bytes one byte at a time
module uart_receiver
	#(
		parameter BAUD_RATE,
		parameter CLOCK_FREQ
	)
	(
		input clk,
		input rst_n,
		input uart_rx,
		output reg [7:0] rx_stream,
		output reg rx_stream_valid,
		output logic uart_violation
	);

	// Calculate CLKS_PER_BIT with rounding
	localparam int CLKS_PER_BIT = (CLOCK_FREQ + (BAUD_RATE/2)) / BAUD_RATE;

	// FSM States
	typedef enum {
		UART_IDLE,
		UART_START,
		UART_DATA,
		UART_STOP
	} UartRxStageType;
	
	UartRxStageType uart_stage;
	reg [$clog2(CLKS_PER_BIT+1)-1:0] rx_timer;
	reg [2:0] rx_data_pos;

	// Check and read UART data
	always_ff @(posedge clk) begin

		if (~rst_n) begin
			uart_stage <= UART_IDLE;

			rx_stream[7:0] <= 8'dx;
			rx_stream_valid <= 1'd0;

			rx_timer <= 'dx;
			rx_data_pos <= 3'dx;

		// Idle and no new message
		end else if (uart_stage == UART_IDLE && uart_rx == 1'd1) begin
			rx_stream <= 8'dx;
			rx_stream_valid <= 1'd0;

			rx_timer <= 'dx;
			rx_data_pos <= 3'dx;

		// Idle and new message detected
		// Begin to offset to sample center of bit
		end else if (uart_stage == UART_IDLE && uart_rx == 1'd0) begin
			uart_stage <= UART_START;

			rx_stream <= 8'dx;
			rx_stream_valid <= 1'd0;

			rx_timer <= 0;
			rx_data_pos <= 3'dx;

		// Let timer run until halfway though the bit
		// allowing us to sample in the middle
		end else if (uart_stage == UART_START) begin

			rx_stream <= 8'dx;
			rx_stream_valid <= 1'd0;

			rx_data_pos <= 3'd0;
			
			// Wait for half a bit duration to sample mid-bit
			// Next stage after half-bit duration
			if (rx_timer == CLKS_PER_BIT>>1) begin
				uart_stage <= UART_DATA;
				rx_timer <= 0;
			end else begin
				uart_stage <= UART_START;
				rx_timer <= rx_timer + 'd1;
			end

		// Read data bits if we are in the middle of a transmission
		end else if (uart_stage == UART_DATA) begin

			rx_stream_valid <= 1'd0;

			// If enough time has passed for next bit
			// Read next bit and reset timer
			if (rx_timer == (CLKS_PER_BIT-1)) begin
				rx_stream[rx_data_pos] <= uart_rx;
				rx_data_pos <= rx_data_pos + 3'd1;
				rx_timer <= 0;

				if (rx_data_pos == 3'd7) begin
					uart_stage <= UART_STOP;
				end

			// Else increment timer
			end else begin
				rx_timer <= rx_timer + 'd1;
			end

		// Transmit read data halfway though stop bit
		// Check that stop bit is high, else signal error with data
		end else if (uart_stage == UART_STOP) begin

			if (rx_timer == (CLKS_PER_BIT)>>1) begin
				uart_stage <= UART_IDLE;
				rx_stream_valid <= 1'd1;
				rx_timer <= 'dx;
			end else begin
				rx_stream_valid <= 1'd0;
				rx_timer <= rx_timer + 'd1;
			end

		// Unknown stage redirects to IDLE
		end else begin
			uart_stage <= UART_IDLE;

			rx_stream[7:0] <= 8'dx;
			rx_stream_valid <= 1'd0;

			rx_timer <= 'dx;
			rx_data_pos <= 3'dx;
		end
	end

	// Convey error uart_rx is low mid stop bit
	assign uart_violation = rx_stream_valid & (~uart_rx);

endmodule : uart_receiver



// Input Decoder
// Reads UART RX into buffer
module rx_decode
	#(
		parameter BAUD_RATE,
		parameter CLOCK_FREQ
	)
	(
		input clk,
		input rst_n,
		input uart_rx,
		input mark_read,
		output [7:0] rx_stream,
		output rx_stream_valid,
		output kill,
		output remote_reset,
		output error
	);

	uart_receiver #(.BAUD_RATE(BAUD_RATE), .CLOCK_FREQ(CLOCK_FREQ)) engine_uart_reciever (
		.clk(clk),
		.rst_n(rst_n),
		.uart_rx(uart_rx),
		.rx_stream(rx_stream),
		.rx_stream_valid(rx_stream_valid),
		.uart_violation(error)
	);

	assign kill = 1'b0;
	assign remote_reset = 1'b0;
	assign error = 1'b0;

endmodule : rx_decode
