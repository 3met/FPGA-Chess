`timescale 1ns/1ps

module tb_rx_decode;

    localparam int UART_CLOCK_FREQ = 50_000_000;
    localparam int ENGINE_CLOCK_FREQ = 100_000_000;
    localparam int BAUD_RATE = 2_000_000;
    localparam real UART_CLK_NS = 1_000_000_000.0 / UART_CLOCK_FREQ;
    localparam real ENGINE_CLK_NS = 1_000_000_000.0 / ENGINE_CLOCK_FREQ;
    localparam real BIT_NS = 1_000_000_000.0 / BAUD_RATE;

    logic clk = 1'b0;
    logic uart_clk = 1'b0;
    logic rst_n = 1'b1;
    logic uart_rx = 1'b1;
    logic mark_read = 1'b0;
    logic [7:0] rx_stream;
    logic rx_stream_valid;
    logic remote_reset;
    logic error;
    logic remote_reset_seen;

    int pass_count = 0;
    int fail_count = 0;

    always #(ENGINE_CLK_NS / 2.0) clk = ~clk;
    always #(UART_CLK_NS / 2.0) uart_clk = ~uart_clk;

    always_ff @(posedge clk) begin
        if (!rst_n) begin
            remote_reset_seen <= 1'b0;
        end else if (remote_reset) begin
            remote_reset_seen <= 1'b1;
        end
    end

    rx_decode #(
        .BAUD_RATE(BAUD_RATE),
        .UART_CLOCK_FREQ(UART_CLOCK_FREQ),
        .FIFO_DEPTH(4),
        .BREAK_BIT_COUNT(20)
    ) dut (
        .clk(clk),
        .uart_clk(uart_clk),
        .engine_rst_n(rst_n),
        .uart_rst_n(rst_n),
        .uart_rx(uart_rx),
        .mark_read(mark_read),
        .rx_stream(rx_stream),
        .rx_stream_valid(rx_stream_valid),
        .remote_reset(remote_reset),
        .error(error)
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
        uart_rx = 1'b1;
        mark_read = 1'b0;
        remote_reset_seen = 1'b0;
        repeat (8) @(posedge clk);
        repeat (8) @(posedge uart_clk);
        rst_n = 1'b1;
        repeat (8) @(posedge clk);
        repeat (8) @(posedge uart_clk);
    endtask : reset_dut

    task automatic clear_remote_reset_seen();
        @(posedge clk);
        remote_reset_seen <= 1'b0;
        @(posedge clk);
    endtask : clear_remote_reset_seen

    task automatic send_uart_byte(input logic [7:0] value);
        uart_rx = 1'b0;
        #(BIT_NS);
        for (int idx = 0; idx < 8; idx += 1) begin
            uart_rx = value[idx];
            #(BIT_NS);
        end
        uart_rx = 1'b1;
        #(BIT_NS);
    endtask : send_uart_byte

    task automatic send_bad_stop(input logic [7:0] value);
        uart_rx = 1'b0;
        #(BIT_NS);
        for (int idx = 0; idx < 8; idx += 1) begin
            uart_rx = value[idx];
            #(BIT_NS);
        end
        uart_rx = 1'b0;
        #(BIT_NS);
        uart_rx = 1'b1;
        #(BIT_NS);
    endtask : send_bad_stop

    task automatic pop_byte(input logic [7:0] expected);
        wait (rx_stream_valid);
        #1;
        check(rx_stream === expected, $sformatf("rx_decode byte 0x%02h", expected));
        @(posedge clk);
        mark_read <= 1'b1;
        @(posedge clk);
        mark_read <= 1'b0;
    endtask : pop_byte

    initial begin
        reset_dut();
        check(!rx_stream_valid, "RX FIFO empty after reset");

        send_uart_byte(8'h10);
        send_uart_byte(8'h1f);
        send_uart_byte(8'h20);
        pop_byte(8'h10);
        pop_byte(8'h1f);
        pop_byte(8'h20);
        repeat (8) @(posedge clk);
        check(!rx_stream_valid, "RX FIFO empty after reads");

        send_uart_byte(8'h30);
        wait (rx_stream_valid);
        repeat (10) @(posedge clk);
        check(rx_stream_valid && rx_stream === 8'h30, "mark_read low holds head byte");
        pop_byte(8'h30);

        send_bad_stop(8'h44);
        wait (error);
        check(error, "framing error latches");

        clear_remote_reset_seen();
        uart_rx = 1'b0;
        #(BIT_NS * 25.0);
        check(remote_reset_seen, "BREAK creates remote_reset pulse");
        check(!error, "BREAK clears error latch");
        uart_rx = 1'b1;
        #(BIT_NS * 3.0);
        repeat (8) @(posedge clk);
        check(!rx_stream_valid, "BREAK clears RX FIFO");

        send_uart_byte(8'h00);
        send_uart_byte(8'h01);
        send_uart_byte(8'h02);
        send_uart_byte(8'h03);
        send_uart_byte(8'h04);
        send_uart_byte(8'h05);
        send_uart_byte(8'h06);
        send_uart_byte(8'h07);
        wait (error);
        check(error, "RX overflow latches error");

        $display("Pass Count: %0d", pass_count);
        $display("Fail Count: %0d", fail_count);
        if (fail_count != 0) $fatal(1, "tb_rx_decode failed");
        $finish;
    end

    initial begin
        #200_000;
        fail_count += 1;
        $fatal(1, "tb_rx_decode timed out (pass=%0d fail=%0d)", pass_count, fail_count);
    end

endmodule : tb_rx_decode
