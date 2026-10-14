`timescale 1ns/1ps

import chess_defs::*;
import move_generator_defs::*;

// Exercise signed ordinary history with an independent narrow, negative-prior policy.
module tb_quiet_history;
    localparam int ENTRY_BITS = 5;
    localparam int PRIOR = -7;
    logic clk = 0;
    always #5 clk = ~clk;
    logic rst_n = 0, clear = 0, init_busy;
    logic lookup_valid = 0, update_valid = 0;
    Position from_pos = Position'(1), to_pos = Position'(18);
    logic signed [ENTRY_BITS-1:0] value;
    logic [1:0] failed_count = 0;
    int pass_count = 0, fail_count = 0;

    move_generator_quiet_history #(
        .HISTORY_ENTRY_COUNT(64), .HISTORY_ENTRY_BITS(ENTRY_BITS), .DEFAULT_SCORE(PRIOR),
        .REWARD_PER_DEPTH(3), .MAXIMUM_REWARD(15), .MALUS_DIVISOR(3)
    ) dut (
        .clk, .rst_n, .clear, .init_busy,
        .lookup_valid, .lookup_thread(ThreadID'(0)), .lookup_color(WHITE),
        .lookup_from(from_pos), .lookup_to(to_pos), .lookup_value(value),
        .update_valid, .update_ready(), .update_thread(ThreadID'(0)), .update_color(WHITE),
        .update_from(from_pos), .update_to(to_pos), .update_depth(PlyIndex'(2)),
        .update_failed0({Position'(2), Position'(19)}), .update_failed1('0),
        .update_failed2('0), .update_failed_count(failed_count)
    );

    // Drive away from the active edge and sample after synchronous RAM settles.
    task automatic tick;
        @(posedge clk); #1;
        @(negedge clk);
    endtask

    // Report fixture properties without depending on production settings.
    task automatic check(input logic condition, input string message);
        if (condition) pass_count++;
        else begin fail_count++; $display("FAIL: %s", message); end
    endtask

    // Each update drains independently before checking its resulting lookup.
    task automatic update;
        update_valid = 1; tick(); update_valid = 0;
        while (dut.state != HISTORY_UPDATE_IDLE) tick();
    endtask

    // A lookup owns the synchronous read port for one cycle.
    task automatic lookup;
        lookup_valid = 1; tick(); lookup_valid = 0;
    endtask

    initial begin
        tick(); rst_n = 1;
        while (init_busy) tick();
        lookup();
        check(value == PRIOR, "negative reset prior is stored as a signed entry");
        update(); lookup();
        check(value == 1, "gravity is centered on zero rather than the reset prior");
        failed_count = 1;
        update();
        from_pos = Position'(2); to_pos = Position'(19); lookup();
        check(value == -9, "failed quiet receives the configured fractional malus");
        from_pos = Position'(1); to_pos = Position'(18); failed_count = 0;
        repeat (32) update(); lookup();
        check(value == (1 << (ENTRY_BITS - 1)) - 1, "rewards saturate at the signed maximum");

        // The generator's same-address lookup suppresses a conflicting write.
        clear = 1; tick(); clear = 0;
        while (init_busy) tick();
        update_valid = 1; tick(); update_valid = 0;
        while (dut.state != HISTORY_UPDATE_WRITE) tick();
        lookup_valid = 1; tick(); lookup_valid = 0;
        lookup();
        check(value == PRIOR, "same-address lookup wins over the pending update");

        clear = 1; tick(); clear = 0;
        while (init_busy) tick();
        lookup(); check(value == PRIOR, "clear restores the signed prior");
        $display("Pass Count: %0d", pass_count);
        $display("Fail Count: %0d", fail_count);
        if (fail_count != 0) $fatal(1, "quiet history tests failed");
        $finish;
    end

    initial begin
        #100000;
        $fatal(1, "quiet history test timed out");
    end
endmodule : tb_quiet_history
