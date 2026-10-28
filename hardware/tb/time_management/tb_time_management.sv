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
    TimeType time_limit = TimeType'(0);
    TimeType move_overhead = TimeType'(0);
    TimeType remaining_time = TimeType'(0);
    TimeType clock_increment = TimeType'(0);
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
        // Golden allocations exercise a fixed fixture policy, independent of tuned defaults.
        .CLOCK_FREQ(3000),
        .MOVES_TO_GO_BUFFER(2), .DEFAULT_MOVES_DIVISOR(20),
        .INCREMENT_NUMERATOR(4), .INCREMENT_DENOMINATOR(5),
        .HARD_BASE_MULTIPLIER(4), .HARD_TIME_NUMERATOR(4), .HARD_TIME_DENOMINATOR(5),
        .SOFT_FACTOR_DEFAULT(4), .NEXT_DEPTH_NUMERATOR(3), .NEXT_DEPTH_DENOMINATOR(5),
        .SINGLE_LEGAL_MOVE_MS(10)
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
        repeat (9) @(negedge clk);
        timer_run = 1'b0;
        check(elapsed_ms == TimeType'(3), "timer counts running milliseconds");
        repeat (2) @(negedge clk);
        check(elapsed_ms == TimeType'(3), "timer pauses without losing elapsed time");

        // Pausing must retain sub-millisecond progress, not just whole milliseconds.
        timer_run = 1;
        repeat (2) @(negedge clk);
        timer_run = 0;
        repeat (4) @(negedge clk);
        check(elapsed_ms == TimeType'(3), "partial millisecond survives pause");
        timer_run = 1;
        @(negedge clk); timer_run = 0;
        check(elapsed_ms == TimeType'(4), "resume completes the partial millisecond");
        timer_reset = 1;
        @(negedge clk); timer_reset = 0;
        check(elapsed_ms == 0, "timer reset discards elapsed time");

        setup_fixed_time = 1'b1;
        time_limit = TimeType'(250);
        move_overhead = TimeType'(10);
        pulse_setup();
        check(base_ms == 26'd240 && soft_ms == TimeType'(240)
                && next_depth_ms == TimeType'(240) && hard_ms == TimeType'(240),
            "fixed time subtracts overhead from every deadline");

        setup_fixed_time = 1'b0;
        setup_clock_time = 1'b1;
        remaining_time = TimeType'(180_000);
        clock_increment = TimeType'(2_000);
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

        // Boundary allocations must clamp before unsigned subtraction or narrowing.
        setup_fixed_time = 1; setup_clock_time = 0;
        for (int limit = 9; limit <= 10; limit++) begin
            time_limit = TimeType'(limit);
            pulse_setup();
            check(base_ms == 0 && soft_ms == 0 && next_depth_ms == 0 && hard_ms == 0,
                "overhead at or above fixed time gives zero budget");
        end
        setup_fixed_time = 0; setup_clock_time = 1;
        remaining_time = 9; clock_increment = 0;
        pulse_setup();
        check(base_ms == 0 && soft_ms == 0 && hard_ms == 0, "exhausted clock does not underflow");
        remaining_time = 110; clock_increment = 1000; moves_to_go = 1;
        pulse_setup();
        check(base_ms == 833 && hard_ms == 80, "remaining clock caps a large increment budget");
        remaining_time = 131084; clock_increment = 0; moves_to_go = '1;
        pulse_setup();
        check(base_ms == 2, "maximum moves-to-go plus buffer does not wrap");

        adaptive_base_ms = 101; adaptive_hard_ms = 150;
        adaptive_factor = 8; adaptive_single_legal_move = 0;
        pulse_adaptive();
        check(soft_ms == 150 && next_depth_ms == 90, "hard cap precedes next-depth scaling");
        adaptive_factor = 3; adaptive_hard_ms = 400;
        pulse_adaptive();
        check(soft_ms == 75 && next_depth_ms == 45, "fractional budgets truncate consistently");

        // Cancel in-flight division and wait past its normal latency for stale completion.
        @(negedge clk); setup_start = 1;
        @(negedge clk); setup_start = 0;
        repeat (8) @(negedge clk);
        check(busy, "cancellation scenario reaches active arithmetic");
        cancel = 1;
        @(negedge clk); cancel = 0;
        repeat (110) begin
            @(negedge clk);
            check(!busy && !done, "cancel suppresses late completion");
        end
        setup_fixed_time = 1; setup_clock_time = 0; time_limit = 60;
        pulse_setup();
        check(base_ms == 50 && hard_ms == 50, "new allocation succeeds after cancellation");
        @(negedge clk);
        check(!done, "completion is a single-cycle pulse");

        $display("Pass Count: %0d", pass_count);
        $display("Fail Count: %0d", fail_count);
        if (fail_count != 0) $fatal(1, "time-management checks failed");
        $finish;
    end

    initial begin
        #100000;
        $fatal(1, "time-management test timed out");
    end

endmodule : tb_time_management
