`timescale 1ns/1ps

module tb_tx_encode;

    localparam int UART_CLOCK_FREQ = 50_000_000;
    localparam int ENGINE_CLOCK_FREQ = 100_000_000;
    localparam int BAUD_RATE = 2_000_000;
    localparam real UART_CLK_NS = 1_000_000_000.0 / UART_CLOCK_FREQ;
    localparam real ENGINE_CLK_NS = 1_000_000_000.0 / ENGINE_CLOCK_FREQ;
    localparam real BIT_NS = 1_000_000_000.0 / BAUD_RATE;

    logic clk = 1'b0;
    logic uart_clk = 1'b0;
    logic rst_n = 1'b1;
    logic [7:0] tx_stream = '0;
    logic tx_stream_valid = 1'b0;
    logic uart_tx;
    logic full;

    int pass_count = 0;
    int fail_count = 0;

    always #(ENGINE_CLK_NS / 2.0) clk = ~clk;
    always #(UART_CLK_NS / 2.0) uart_clk = ~uart_clk;

    tx_encode #(
        .BAUD_RATE(BAUD_RATE),
        .UART_CLOCK_FREQ(UART_CLOCK_FREQ),
        .FIFO_DEPTH(4)
    ) dut (
        .clk(clk),
        .uart_clk(uart_clk),
        .engine_rst_n(rst_n),
        .uart_rst_n(rst_n),
        .tx_stream(tx_stream),
        .tx_stream_valid(tx_stream_valid),
        .uart_tx(uart_tx),
        .full(full)
    );

    task automatic check(input logic condition, input string label);
        if (condition) begin
            pass_count += 1;
        end else begin
            fail_count += 1;
            $error("[FAIL] %s", label);
        end
    endtask : check

    task automatic reset_dut();
        rst_n = 1'b0;
        tx_stream_valid = 1'b0;
        repeat (8) @(posedge clk);
        repeat (8) @(posedge uart_clk);
        rst_n = 1'b1;
        repeat (8) @(posedge clk);
        repeat (8) @(posedge uart_clk);
    endtask : reset_dut

    task automatic enqueue_byte(input logic [7:0] value);
        wait (!full);
        @(posedge clk);
        tx_stream <= value;
        tx_stream_valid <= 1'b1;
        @(posedge clk);
        tx_stream_valid <= 1'b0;
    endtask : enqueue_byte

    task automatic expect_uart_byte(input logic [7:0] expected);
        wait (uart_tx == 1'b0);
        #(BIT_NS / 2.0);
        check(uart_tx == 1'b0, "start bit low");
        #(BIT_NS);
        for (int idx = 0; idx < 8; idx += 1) begin
            check(uart_tx == expected[idx], $sformatf("data bit %0d for 0x%02h", idx, expected));
            #(BIT_NS);
        end
        check(uart_tx == 1'b1, "stop bit high");
        #(BIT_NS / 2.0);
    endtask : expect_uart_byte

    initial begin
        logic saw_full;

        reset_dut();
        check(uart_tx == 1'b1, "UART TX idles high");
        check(!full, "TX FIFO not full after reset");

        fork
            begin
                enqueue_byte(8'h01);
                enqueue_byte(8'h23);
                enqueue_byte(8'h45);
                enqueue_byte(8'h67);
            end
            begin
                expect_uart_byte(8'h01);
                expect_uart_byte(8'h23);
                expect_uart_byte(8'h45);
                expect_uart_byte(8'h67);
            end
        join

        saw_full = 1'b0;
        for (int idx = 0; idx < 32; idx += 1) begin
            @(posedge clk);
            tx_stream <= idx[7:0];
            tx_stream_valid <= !full;
            if (full) begin
                saw_full = 1'b1;
            end
        end
        @(posedge clk);
        tx_stream_valid <= 1'b0;
        repeat (20) @(posedge clk);
        check(saw_full || full, "TX FIFO reports full during rapid enqueue");

        reset_dut();
        enqueue_byte(8'hde);
        expect_uart_byte(8'hde);

        $display("Pass Count: %0d", pass_count);
        $display("Fail Count: %0d", fail_count);
        if (fail_count != 0) $fatal(1, "tb_tx_encode failed");
        $finish;
    end

    initial begin
        #200_000;
        fail_count += 1;
        $fatal(1, "tb_tx_encode timed out (pass=%0d fail=%0d)", pass_count, fail_count);
    end

endmodule : tb_tx_encode
