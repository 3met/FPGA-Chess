// By Emet Behrendt

// Receives UART RX one bit at a time and emits valid data bytes.
module uart_receiver #(
    parameter int BAUD_RATE = 2_000_000,
    parameter int CLOCK_FREQ = 50_000_000,
    parameter int BREAK_BIT_COUNT = 20
) (
    input logic clk,
    input logic rst_n,
    input logic uart_rx,
    output logic [7:0] rx_stream,
    output logic rx_stream_valid,
    output logic uart_violation,
    output logic break_active
);

    localparam int CLKS_PER_BIT = (CLOCK_FREQ + (BAUD_RATE / 2)) / BAUD_RATE;
    localparam int HALF_BIT_CLKS = CLKS_PER_BIT / 2;
    localparam int BREAK_CLKS = CLKS_PER_BIT * BREAK_BIT_COUNT;
    localparam int TIMER_BITS = $clog2(CLKS_PER_BIT + 1);
    localparam int BREAK_TIMER_BITS = $clog2(BREAK_CLKS + 1);

    initial begin
        if (BAUD_RATE <= 0) begin
            $error("uart_receiver BAUD_RATE must be positive");
        end
        if (CLOCK_FREQ <= 0) begin
            $error("uart_receiver CLOCK_FREQ must be positive");
        end
        if (CLKS_PER_BIT < 4) begin
            $error("uart_receiver needs at least 4 clocks per UART bit");
        end
        if (BREAK_BIT_COUNT < 10) begin
            $error("uart_receiver BREAK_BIT_COUNT must cover at least one UART frame");
        end
    end

    typedef enum logic [1:0] {
        UART_IDLE,
        UART_START,
        UART_DATA,
        UART_STOP
    } UartRxStageType;

    UartRxStageType uart_stage;
    logic [TIMER_BITS-1:0] rx_timer;
    logic [BREAK_TIMER_BITS-1:0] low_timer;
    logic [2:0] rx_data_pos;
    logic [7:0] rx_shift;
    logic uart_rx_meta, uart_rx_sync;

    always_ff @(posedge clk) begin
        if (!rst_n) begin
            uart_rx_meta <= 1'b1;
            uart_rx_sync <= 1'b1;
        end else begin
            uart_rx_meta <= uart_rx;
            uart_rx_sync <= uart_rx_meta;
        end
    end

    always_ff @(posedge clk) begin
        if (!rst_n) begin
            low_timer <= '0;
        end else if (uart_rx_sync) begin
            low_timer <= '0;
        end else if (low_timer != BREAK_TIMER_BITS'(BREAK_CLKS)) begin
            low_timer <= low_timer + BREAK_TIMER_BITS'(1);
        end
    end

    assign break_active = (low_timer >= BREAK_TIMER_BITS'(BREAK_CLKS));

    always_ff @(posedge clk) begin
        if (!rst_n) begin
            uart_stage <= UART_IDLE;
            rx_timer <= '0;
            rx_data_pos <= '0;
            rx_shift <= '0;
            rx_stream <= '0;
            rx_stream_valid <= 1'b0;
            uart_violation <= 1'b0;
        end else begin
            rx_stream_valid <= 1'b0;
            uart_violation <= 1'b0;

            if (break_active) begin
                uart_stage <= UART_IDLE;
                rx_timer <= '0;
                rx_data_pos <= '0;
                rx_shift <= '0;
            end else begin
                case (uart_stage)
                    UART_IDLE: begin
                        rx_timer <= '0;
                        rx_data_pos <= '0;
                        if (!uart_rx_sync) begin
                            uart_stage <= UART_START;
                        end
                    end

                    UART_START: begin
                        if (rx_timer == TIMER_BITS'(HALF_BIT_CLKS)) begin
                            rx_timer <= '0;
                            if (!uart_rx_sync) begin
                                uart_stage <= UART_DATA;
                                rx_data_pos <= '0;
                            end else begin
                                uart_stage <= UART_IDLE;
                            end
                        end else begin
                            rx_timer <= rx_timer + TIMER_BITS'(1);
                        end
                    end

                    UART_DATA: begin
                        if (rx_timer == TIMER_BITS'(CLKS_PER_BIT - 1)) begin
                            rx_timer <= '0;
                            rx_shift[rx_data_pos] <= uart_rx_sync;
                            rx_data_pos <= rx_data_pos + 3'd1;
                            if (rx_data_pos == 3'd7) begin
                                uart_stage <= UART_STOP;
                            end
                        end else begin
                            rx_timer <= rx_timer + TIMER_BITS'(1);
                        end
                    end

                    UART_STOP: begin
                        if (rx_timer == TIMER_BITS'(CLKS_PER_BIT - 1)) begin
                            uart_stage <= UART_IDLE;
                            rx_timer <= '0;
                            if (uart_rx_sync) begin
                                rx_stream <= rx_shift;
                                rx_stream_valid <= 1'b1;
                            end else begin
                                uart_violation <= 1'b1;
                            end
                        end else begin
                            rx_timer <= rx_timer + TIMER_BITS'(1);
                        end
                    end

                    default: begin
                        uart_stage <= UART_IDLE;
                        rx_timer <= '0;
                        rx_data_pos <= '0;
                    end
                endcase
            end
        end
    end

endmodule : uart_receiver


// Input decoder. UART bytes are written in uart_clk and consumed in clk.
module rx_decode #(
    parameter int BAUD_RATE = 2_000_000,
    parameter int UART_CLOCK_FREQ = 50_000_000,
    parameter int FIFO_DEPTH = 1024,
    parameter int BREAK_BIT_COUNT = 20
) (
    input logic clk,
    input logic uart_clk,
    input logic engine_rst_n,
    input logic uart_rst_n,
    input logic uart_rx,
    input logic mark_read,
    output logic [7:0] rx_stream,
    output logic rx_stream_valid,
    output logic remote_reset,
    output logic error
);

    logic [7:0] uart_rx_stream;
    logic uart_rx_valid;
    logic uart_violation;
    logic break_active_uart;
    logic rx_fifo_full;
    logic rx_fifo_empty;
    logic rx_fifo_wr_en;
    logic rx_fifo_rd_en;
    logic uart_error_latched;
    logic uart_error_engine_meta;
    logic uart_error_engine_sync;

    logic break_engine_meta;
    logic break_engine_sync;
    logic break_engine_sync_prev;

    logic engine_fifo_rst_n;
    logic uart_fifo_rst_n;

    // A BREAK clears both sides of the byte FIFO before the reset event is
    // reported to the engine clock domain.
    assign engine_fifo_rst_n = engine_rst_n && !break_engine_sync;
    assign uart_fifo_rst_n = uart_rst_n && !break_active_uart;

    uart_receiver #(
        .BAUD_RATE(BAUD_RATE),
        .CLOCK_FREQ(UART_CLOCK_FREQ),
        .BREAK_BIT_COUNT(BREAK_BIT_COUNT)
    ) uart_receiver_inst (
        .clk(uart_clk),
        .rst_n(uart_rst_n),
        .uart_rx(uart_rx),
        .rx_stream(uart_rx_stream),
        .rx_stream_valid(uart_rx_valid),
        .uart_violation(uart_violation),
        .break_active(break_active_uart)
    );

    assign rx_fifo_wr_en = uart_rx_valid && !rx_fifo_full && !break_active_uart;
    assign rx_fifo_rd_en = mark_read && !rx_fifo_empty;

    async_fifo #(
        .DATA_WIDTH(8),
        .DEPTH(FIFO_DEPTH)
    ) rx_fifo (
        .wr_clk(uart_clk),
        .wr_rst_n(uart_fifo_rst_n),
        .wr_en(rx_fifo_wr_en),
        .wr_data(uart_rx_stream),
        .full(rx_fifo_full),
        .rd_clk(clk),
        .rd_rst_n(engine_fifo_rst_n),
        .rd_en(rx_fifo_rd_en),
        .rd_data(rx_stream),
        .empty(rx_fifo_empty)
    );

    always_ff @(posedge clk) begin
        if (!engine_rst_n) begin
            break_engine_meta <= 1'b0;
            break_engine_sync <= 1'b0;
            break_engine_sync_prev <= 1'b0;
            uart_error_engine_meta <= 1'b0;
            uart_error_engine_sync <= 1'b0;
        end else begin
            break_engine_meta <= break_active_uart;
            break_engine_sync <= break_engine_meta;
            break_engine_sync_prev <= break_engine_sync;
            uart_error_engine_meta <= uart_error_latched;
            uart_error_engine_sync <= uart_error_engine_meta;
        end
    end

    always_ff @(posedge uart_clk) begin
        if (!uart_rst_n || break_active_uart) begin
            uart_error_latched <= 1'b0;
        end else if (uart_violation || (uart_rx_valid && rx_fifo_full)) begin
            uart_error_latched <= 1'b1;
        end
    end

    always_ff @(posedge clk) begin
        if (!engine_rst_n || break_engine_sync) begin
            error <= 1'b0;
        end else if (uart_error_engine_sync) begin
            error <= 1'b1;
        end
    end

    assign rx_stream_valid = !rx_fifo_empty;
    assign remote_reset = break_engine_sync && !break_engine_sync_prev;

endmodule : rx_decode
