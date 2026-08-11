`timescale 1ns/1ps

module tb_uart_primitives;

    localparam int CLOCK_FREQ = 100_000_000;
    localparam int BAUD_RATE = 2_000_000;
    localparam real CLK_NS = 1_000_000_000.0 / CLOCK_FREQ;
    localparam real BIT_NS = 1_000_000_000.0 / BAUD_RATE;

    logic clk = 1'b0;
    logic rst_n = 1'b1;
    logic uart_rx = 1'b1;
    logic [7:0] rx_stream;
    logic rx_stream_valid;
    logic uart_violation;
    logic break_active;

    logic [7:0] tx_stream = '0;
    logic tx_stream_valid = 1'b0;
    logic tx_ready;
    logic uart_tx;
    logic rx_seen;
    logic rx_error_seen;
    logic [7:0] last_rx_stream;

    int pass_count = 0;
    int fail_count = 0;

    always #(CLK_NS / 2.0) clk = ~clk;

    always_ff @(posedge clk) begin
        if (!rst_n) begin
            rx_seen <= 1'b0;
            rx_error_seen <= 1'b0;
            last_rx_stream <= '0;
        end else begin
            if (rx_stream_valid) begin
                rx_seen <= 1'b1;
                last_rx_stream <= rx_stream;
            end
            if (uart_violation) begin
                rx_error_seen <= 1'b1;
            end
        end
    end

    uart_receiver #(
        .BAUD_RATE(BAUD_RATE),
        .CLOCK_FREQ(CLOCK_FREQ),
        .BREAK_BIT_COUNT(20)
    ) rx_dut (
        .clk(clk),
        .rst_n(rst_n),
        .uart_rx(uart_rx),
        .rx_stream(rx_stream),
        .rx_stream_valid(rx_stream_valid),
        .uart_violation(uart_violation),
        .break_active(break_active)
    );

    uart_transmitter #(
        .BAUD_RATE(BAUD_RATE),
        .CLOCK_FREQ(CLOCK_FREQ)
    ) tx_dut (
        .clk(clk),
        .rst_n(rst_n),
        .tx_stream(tx_stream),
        .tx_stream_valid(tx_stream_valid),
        .ready(tx_ready),
        .uart_tx(uart_tx)
    );

    task automatic check(input logic condition, input string label);
        if (condition) begin
            pass_count += 1;
        end else begin
            fail_count += 1;
            $error("[FAIL] %s", label);
        end
    endtask : check

    task automatic reset_duts();
        rst_n = 1'b0;
        uart_rx = 1'b1;
        tx_stream_valid = 1'b0;
        repeat (5) @(posedge clk);
        rst_n = 1'b1;
        repeat (5) @(posedge clk);
    endtask : reset_duts

    task automatic clear_rx_events();
        @(negedge clk);
        rx_seen = 1'b0;
        rx_error_seen = 1'b0;
    endtask : clear_rx_events

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

    task automatic send_uart_byte_with_center_glitch(input logic [7:0] value);
        uart_rx = 1'b0;
        #(BIT_NS);
        for (int idx = 0; idx < 8; idx += 1) begin
            uart_rx = value[idx];
            if (idx == 3) begin
                #(BIT_NS / 2.0 - CLK_NS / 2.0);
                uart_rx = ~value[idx];
                #(CLK_NS);
                uart_rx = value[idx];
                #(BIT_NS / 2.0 - CLK_NS / 2.0);
            end else begin
                #(BIT_NS);
            end
        end
        uart_rx = 1'b1;
        #(BIT_NS);
    endtask : send_uart_byte_with_center_glitch

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

    task automatic expect_rx_byte(input logic [7:0] expected);
        check(rx_seen, $sformatf("RX valid for 0x%02h", expected));
        check(last_rx_stream === expected, $sformatf("RX byte 0x%02h", expected));
        check(!rx_error_seen, $sformatf("RX no error for 0x%02h", expected));
        @(posedge clk);
    endtask : expect_rx_byte

    task automatic transmit_byte(input logic [7:0] value);
        wait (tx_ready);
        @(negedge clk);
        tx_stream = value;
        tx_stream_valid = 1'b1;
        @(negedge clk);
        tx_stream_valid = 1'b0;
    endtask : transmit_byte

    task automatic expect_tx_byte(input logic [7:0] expected);
        wait (uart_tx == 1'b0);
        #(BIT_NS / 2.0);
        check(uart_tx == 1'b0, "TX start bit");
        #(BIT_NS);
        for (int idx = 0; idx < 8; idx += 1) begin
            check(uart_tx == expected[idx], $sformatf("TX data bit %0d for 0x%02h", idx, expected));
            #(BIT_NS);
        end
        check(uart_tx == 1'b1, "TX stop bit");
        #(BIT_NS / 2.0);
    endtask : expect_tx_byte

    initial begin
        reset_duts();

        // Use a fixed non-edge-aligned phase so failures remain reproducible.
        #(CLK_NS * 0.37);
        clear_rx_events();
        send_uart_byte(8'h00);
        expect_rx_byte(8'h00);
        clear_rx_events();
        send_uart_byte(8'hff);
        expect_rx_byte(8'hff);
        clear_rx_events();
        send_uart_byte(8'ha5);
        expect_rx_byte(8'ha5);

        clear_rx_events();
        send_uart_byte_with_center_glitch(8'ha5);
        expect_rx_byte(8'ha5);

        clear_rx_events();
        uart_rx = 1'b0;
        #(BIT_NS / 4.0);
        uart_rx = 1'b1;
        #(BIT_NS * 3.0);
        check(!rx_seen && !rx_error_seen, "false start rejected");

        clear_rx_events();
        send_bad_stop(8'h5a);
        check(rx_error_seen, "bad stop bit reports framing violation");
        @(posedge clk);

        uart_rx = 1'b0;
        #(BIT_NS * 21.0);
        check(break_active, "BREAK active after low interval");
        uart_rx = 1'b1;
        #(BIT_NS * 2.0);
        check(!break_active, "BREAK clears after high line");

        fork
            begin
                transmit_byte(8'h12);
            end
            begin
                expect_tx_byte(8'h12);
            end
        join

        $display("Pass Count: %0d", pass_count);
        $display("Fail Count: %0d", fail_count);
        if (fail_count != 0) $fatal(1, "tb_uart_primitives failed");
        $finish;
    end

    initial begin
        #200_000;
        fail_count += 1;
        $fatal(1, "tb_uart_primitives timed out (pass=%0d fail=%0d)", pass_count, fail_count);
    end

endmodule : tb_uart_primitives
