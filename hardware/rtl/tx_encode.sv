// By Emet Behrendt

// Takes data bytes and transmits them as UART frames.
module uart_transmitter #(
    parameter int BAUD_RATE = 2_000_000,
    parameter int CLOCK_FREQ = 50_000_000
) (
    input clk,
    input rst_n,
    input logic [7:0] tx_stream,
    input tx_stream_valid,
    output logic ready,
    output logic uart_tx
);

    localparam int CLKS_PER_BIT = (CLOCK_FREQ + (BAUD_RATE / 2)) / BAUD_RATE;
    localparam int TIMER_BITS = $clog2(CLKS_PER_BIT + 1);

    initial begin
        if (BAUD_RATE <= 0) begin
            $error("uart_transmitter BAUD_RATE must be positive");
        end
        if (CLOCK_FREQ <= 0) begin
            $error("uart_transmitter CLOCK_FREQ must be positive");
        end
        if (CLKS_PER_BIT < 4) begin
            $error("uart_transmitter needs at least 4 clocks per UART bit");
        end
    end

    typedef enum logic [1:0] {
        UART_IDLE,
        UART_START,
        UART_DATA,
        UART_STOP
    } UartTxStageType;

    UartTxStageType uart_stage;
    logic [7:0] data_packet;
    logic [2:0] bit_index;
    logic [TIMER_BITS-1:0] tx_timer;

    assign ready = (uart_stage == UART_IDLE)
        || (uart_stage == UART_STOP && tx_timer == TIMER_BITS'(CLKS_PER_BIT - 1));

    always_comb begin
        case (uart_stage)
            UART_IDLE:  uart_tx = 1'b1;
            UART_START: uart_tx = 1'b0;
            UART_DATA:  uart_tx = data_packet[bit_index];
            UART_STOP:  uart_tx = 1'b1;
            default:    uart_tx = 1'b1;
        endcase
    end

    always_ff @(posedge clk) begin
        if (!rst_n) begin
            uart_stage <= UART_IDLE;
            data_packet <= '0;
            bit_index <= '0;
            tx_timer <= '0;
        end else begin
            case (uart_stage)
                UART_IDLE: begin
                    tx_timer <= '0;
                    bit_index <= '0;
                    if (tx_stream_valid) begin
                        data_packet <= tx_stream;
                        uart_stage <= UART_START;
                    end
                end

                UART_START: begin
                    if (tx_timer == TIMER_BITS'(CLKS_PER_BIT - 1)) begin
                        uart_stage <= UART_DATA;
                        tx_timer <= '0;
                        bit_index <= '0;
                    end else begin
                        tx_timer <= tx_timer + TIMER_BITS'(1);
                    end
                end

                UART_DATA: begin
                    if (tx_timer == TIMER_BITS'(CLKS_PER_BIT - 1)) begin
                        tx_timer <= '0;
                        if (bit_index == 3'd7) begin
                            uart_stage <= UART_STOP;
                        end else begin
                            bit_index <= bit_index + 3'd1;
                        end
                    end else begin
                        tx_timer <= tx_timer + TIMER_BITS'(1);
                    end
                end

                UART_STOP: begin
                    if (tx_timer == TIMER_BITS'(CLKS_PER_BIT - 1)) begin
                        tx_timer <= '0;
                        bit_index <= '0;
                        if (tx_stream_valid) begin
                            data_packet <= tx_stream;
                            uart_stage <= UART_START;
                        end else begin
                            uart_stage <= UART_IDLE;
                        end
                    end else begin
                        tx_timer <= tx_timer + TIMER_BITS'(1);
                    end
                end

                default: begin
                    uart_stage <= UART_IDLE;
                    tx_timer <= '0;
                    bit_index <= '0;
                end
            endcase
        end
    end

endmodule : uart_transmitter


// Output encoder. Engine bytes are written in clk and transmitted in uart_clk.
module tx_encode #(
    parameter int BAUD_RATE = 2_000_000,
    parameter int UART_CLOCK_FREQ = 50_000_000,
    parameter int FIFO_DEPTH = 1024
) (
    input clk,
    input uart_clk,
    input rst_n,
    input logic [7:0] tx_stream,
    input tx_stream_valid,
    output logic uart_tx,
    output logic full
);

    logic [7:0] fifo_tx_stream;
    logic fifo_empty;
    logic fifo_rd_en;
    logic uart_ready;

    async_fifo #(
        .DATA_WIDTH(8),
        .DEPTH(FIFO_DEPTH)
    ) tx_fifo (
        .wr_clk(clk),
        .wr_rst_n(rst_n),
        .wr_en(tx_stream_valid && !full),
        .wr_data(tx_stream),
        .full(full),
        .rd_clk(uart_clk),
        .rd_rst_n(rst_n),
        .rd_en(fifo_rd_en),
        .rd_data(fifo_tx_stream),
        .empty(fifo_empty)
    );

    assign fifo_rd_en = uart_ready && !fifo_empty;

    uart_transmitter #(
        .BAUD_RATE(BAUD_RATE),
        .CLOCK_FREQ(UART_CLOCK_FREQ)
    ) engine_uart_transmitter (
        .clk(uart_clk),
        .rst_n(rst_n),
        .tx_stream(fifo_tx_stream),
        .tx_stream_valid(!fifo_empty),
        .ready(uart_ready),
        .uart_tx(uart_tx)
    );

endmodule : tx_encode
