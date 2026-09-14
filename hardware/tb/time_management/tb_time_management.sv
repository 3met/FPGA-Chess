`timescale 1ns/1ps

import chess_defs::*;

module tb_time_management;

    logic clk = 1'b0;
    logic rst_n = 1'b0;
    logic cancel = 1'b0;
    logic timer_reset = 1'b1;
    logic timer_run = 1'b0;
    TimeType elapsed_ms;
    logic setup_start = 1'b0;
    logic setup_fixed_time = 1'b0;
    logic setup_clock_time = 1'b0;
    logic side_to_move_white = 1'b1;
    TimeType time_limit = TimeType'(0);
    TimeType move_overhead = TimeType'(0);
    TimeType white_time = TimeType'(0);
    TimeType black_time = TimeType'(0);
    TimeType white_increment = TimeType'(0);
    TimeType black_increment = TimeType'(0);
    logic [15:0] moves_to_go = 16'd0;
    logic adaptive_start = 1'b0;
    logic [TIME_BITS+1:0] adaptive_base_ms = '0;
    TimeType adaptive_hard_ms = TimeType'(0);
    logic [3:0] adaptive_factor = 4'd4;
    logic adaptive_single_legal_move = 1'b0;
    logic busy;
    logic done;
    logic [TIME_BITS+1:0] base_ms;
    TimeType soft_ms;
    TimeType next_depth_ms;
    TimeType hard_ms;
    integer pass_count = 0;
    integer fail_count = 0;

    always #5 clk = ~clk;

    time_management #(
        .CLOCK_FREQ(1000)
    ) dut (.*);

    task automatic check(input logic condition, input string label);
        if (condition) begin
            pass_count++;
        end else begin
            fail_count++;
            $display("FAIL: %s", label);
        end
    endtask : check

    task automatic pulse_setup;
        @(negedge clk);
        setup_start = 1'b1;
        @(negedge clk);
        setup_start = 1'b0;
        while (!done) @(negedge clk);
        check(!busy, "setup completion returns allocator to idle");
    endtask : pulse_setup

    task automatic pulse_adaptive;
        @(negedge clk);
        adaptive_start = 1'b1;
        @(negedge clk);
        adaptive_start = 1'b0;
        while (!done) @(negedge clk);
        check(!busy, "adaptive completion returns allocator to idle");
    endtask : pulse_adaptive

    initial begin
        repeat (2) @(negedge clk);
        rst_n = 1'b1;
        timer_reset = 1'b0;

        timer_run = 1'b1;
        repeat (3) @(negedge clk);
        timer_run = 1'b0;
        check(elapsed_ms == TimeType'(3), "timer counts running milliseconds");
        repeat (2) @(negedge clk);
        check(elapsed_ms == TimeType'(3), "timer pauses without losing elapsed time");

        setup_fixed_time = 1'b1;
        time_limit = TimeType'(250);
        move_overhead = TimeType'(10);
        pulse_setup();
        check(base_ms == 26'd240 && soft_ms == TimeType'(240)
                && next_depth_ms == TimeType'(240) && hard_ms == TimeType'(240),
            "fixed time subtracts overhead from every deadline");

        setup_fixed_time = 1'b0;
        setup_clock_time = 1'b1;
        white_time = TimeType'(180_000);
        black_time = TimeType'(60_000);
        white_increment = TimeType'(2_000);
        black_increment = TimeType'(1_000);
        moves_to_go = 16'd0;
        pulse_setup();
        check(base_ms == 26'd10_599, "sudden-death base allocation is exact");
        check(soft_ms == TimeType'(10_599) && next_depth_ms == TimeType'(0),
            "initial soft deadline equals base and threshold waits for a completed depth");
        check(hard_ms == TimeType'(42_396), "hard deadline is capped at four times base");

        moves_to_go = 16'd40;
        pulse_setup();
        check(base_ms == 26'd5_885, "moves-to-go allocation includes the configured buffer");

        adaptive_base_ms = 26'd100;
        adaptive_hard_ms = TimeType'(400);
        adaptive_factor = 4'd8;
        adaptive_single_legal_move = 1'b1;
        pulse_adaptive();
        check(soft_ms == TimeType'(10), "single legal move caps the adaptive soft deadline");
        check(next_depth_ms == TimeType'(6), "next-depth threshold uses the capped soft deadline");

        $display("Pass Count: %0d", pass_count);
        $display("Fail Count: %0d", fail_count);
        if (fail_count != 0) $fatal(1, "time-management checks failed");
        $finish;
    end

    initial begin
        #20000;
        $fatal(1, "time-management test timed out");
    end

endmodule : tb_time_management
