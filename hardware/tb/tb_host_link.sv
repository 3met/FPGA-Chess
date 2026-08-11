`timescale 1ns/1ps

import engine_defs::*;

module tb_host_link;

    localparam int UART_CLOCK_FREQ = 100_000_000;
    localparam int ENGINE_CLOCK_FREQ = 50_000_000;
    localparam int BAUD_RATE = 2_000_000;
    localparam real UART_CLK_NS = 1_000_000_000.0 / UART_CLOCK_FREQ;
    localparam real ENGINE_CLK_NS = 1_000_000_000.0 / ENGINE_CLOCK_FREQ;
    localparam real BIT_NS = 1_000_000_000.0 / BAUD_RATE;

    logic clk = 1'b0;
    logic uart_clk = 1'b0;
    logic domain_rst_n = 1'b0;
    logic uart_rx = 1'b1;
    logic uart_tx;
    logic [7:0] rx_stream;
    logic rx_stream_valid;
    logic remote_reset;
    logic rx_error;
    logic engine_rst_n;
    logic engine_core_rst_n;
    logic uart_tx_rst_n;
    logic engine_ready;
    logic engine_command_ready;
    logic engine_error;
    logic [7:0] engine_data_out;
    logic engine_data_out_valid;
    logic tx_full;
    logic search_req_valid;
    logic search_req_ready = 1'b1;
    EngineControllerRequest search_req;
    logic search_resp_valid;
    EngineControllerResponse search_resp;
    logic [7:0] debug_stat_address;

    assign engine_core_rst_n = engine_rst_n && !rx_error;
    assign engine_ready = engine_core_rst_n && engine_command_ready;

    int pass_count = 0;
    int fail_count = 0;

    always #(ENGINE_CLK_NS / 2.0) clk = ~clk;
    always #(UART_CLK_NS / 2.0) uart_clk = ~uart_clk;

    reset_release engine_reset (
        .clk,
        .async_reset_n(domain_rst_n && !remote_reset),
        .reset_n(engine_rst_n)
    );

    reset_release uart_tx_reset (
        .clk(uart_clk),
        .async_reset_n(domain_rst_n && !remote_reset),
        .reset_n(uart_tx_rst_n)
    );

    rx_decode #(
        .BAUD_RATE(BAUD_RATE),
        .UART_CLOCK_FREQ(UART_CLOCK_FREQ),
        .FIFO_DEPTH(8),
        .BREAK_BIT_COUNT(20)
    ) rx (
        .clk,
        .uart_clk,
        .engine_rst_n(domain_rst_n),
        .uart_rst_n(domain_rst_n),
        .uart_rx,
        .mark_read(rx_stream_valid && engine_ready),
        .rx_stream,
        .rx_stream_valid,
        .remote_reset,
        .error(rx_error)
    );

    engine_command_layer #(
        .BUILD_ID(64'h0123_4567_89ab_cdef),
        .CLOCK_FREQ(ENGINE_CLOCK_FREQ),
        .SEARCH_THREAD_COUNT(1),
        .SEARCH_STACK_DEPTH(32)
    ) engine (
        .clk,
        .rst_n(engine_core_rst_n),
        .data_in(rx_stream),
        .data_in_valid(rx_stream_valid),
        .ready_for_result(!tx_full),
        .error_flag(engine_error),
        .ready(engine_command_ready),
        .data_out(engine_data_out),
        .data_out_valid(engine_data_out_valid),
        .search_req_valid,
        .search_req_ready,
        .search_req,
        .search_resp_valid,
        .search_resp,
        .debug_stat_address,
        .debug_stat_value(40'd0)
    );

    tx_encode #(
        .BAUD_RATE(BAUD_RATE),
        .UART_CLOCK_FREQ(UART_CLOCK_FREQ),
        .FIFO_DEPTH(8)
    ) tx (
        .clk,
        .uart_clk,
        .engine_rst_n,
        .uart_rst_n(uart_tx_rst_n),
        .tx_stream(engine_data_out),
        .tx_stream_valid(engine_data_out_valid),
        .uart_tx,
        .full(tx_full)
    );

    // A one-cycle delayed controller completion is enough to exercise command acknowledgments.
    always_ff @(posedge clk) begin
        if (!engine_rst_n) begin
            search_resp_valid <= 1'b0;
            search_resp <= '0;
        end else begin
            search_resp_valid <= search_req_valid && search_req_ready;
            search_resp <= '0;
        end
    end

    task automatic check(input logic condition, input string label);
        if (condition) begin
            pass_count += 1;
        end else begin
            fail_count += 1;
            $error("[FAIL] %s", label);
        end
    endtask : check

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

    task automatic expect_uart_byte(input logic [7:0] expected);
        wait (uart_tx == 1'b0);
        #(BIT_NS / 2.0);
        check(uart_tx == 1'b0, "TX start bit");
        #(BIT_NS);
        for (int idx = 0; idx < 8; idx += 1) begin
            check(uart_tx == expected[idx], $sformatf("TX byte 0x%02h bit %0d", expected, idx));
            #(BIT_NS);
        end
        check(uart_tx == 1'b1, "TX stop bit");
        #(BIT_NS / 2.0);
    endtask : expect_uart_byte

    task automatic send_break();
        uart_rx = 1'b0;
        #(BIT_NS * 25.0);
        check(remote_reset && !engine_rst_n && !uart_tx_rst_n, "BREAK holds command and TX domains in reset");
        uart_rx = 1'b1;
        #(BIT_NS * 3.0);
        wait (engine_rst_n && uart_tx_rst_n);
        check(!remote_reset && !rx_stream_valid, "BREAK release leaves an empty synchronized link");
    endtask : send_break

    task automatic expect_idle_status();
        send_uart_byte(ENGINE_CMD_GET_STATUS);
        expect_uart_byte(ENGINE_RESP_STATUS);
        expect_uart_byte(8'h01);
        expect_uart_byte(ENGINE_ERR_NONE);
        expect_uart_byte(8'h00);
    endtask : expect_idle_status

    task automatic start_link();
        repeat (5) @(posedge uart_clk);
        domain_rst_n = 1'b1;
        wait (engine_rst_n && uart_tx_rst_n);
        check(uart_tx && !rx_stream_valid,
            "link starts idle after synchronized reset release");
        expect_idle_status();
    endtask : start_link

    task automatic test_break_during_payload();
        send_uart_byte(ENGINE_CMD_SET_BOARD);
        send_uart_byte(8'h24);
        send_uart_byte(8'h53);
        send_break();
        send_uart_byte(ENGINE_CMD_NEW_GAME);
        expect_uart_byte(ENGINE_RESP_ACK);
        expect_uart_byte(8'h01);
    endtask : test_break_during_payload

    task automatic test_framing_error_recovery();
        send_bad_stop(ENGINE_CMD_GET_STATUS);
        wait (rx_error);
        @(posedge clk);
        #1;
        check(!engine_core_rst_n && !engine_ready,
            "framing error fails the command core closed");
        send_break();
        expect_idle_status();
    endtask : test_framing_error_recovery

    task automatic test_break_during_response();
        send_uart_byte(ENGINE_CMD_GET_BUILD_INFO);
        wait (uart_tx == 1'b0);
        #(BIT_NS * 2.0);
        send_break();
        expect_idle_status();
    endtask : test_break_during_response

    initial begin
        start_link();
        test_break_during_payload();
        test_framing_error_recovery();
        test_break_during_response();

        check(!engine_error && !rx_error, "recovered link ends without latched errors");
        $display("Pass Count: %0d", pass_count);
        $display("Fail Count: %0d", fail_count);
        if (fail_count != 0) $fatal(1, "tb_host_link failed");
        $finish;
    end

    initial begin
        #500_000;
        $fatal(1, "tb_host_link timed out (pass=%0d fail=%0d)", pass_count, fail_count);
    end

endmodule : tb_host_link
