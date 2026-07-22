`timescale 1ns/1ps

import general_chess_defs::*;

module tb_repetition_checker;
    logic clk = 1'b0;
    logic rst_n = 1'b0;
    logic flush = 1'b0;
    logic history_reset, history_write, init_start;
    ZobristKey history_key;
    logic init_busy, init_done, init_failed;
    logic line_write_valid;
    ThreadID line_write_thread;
    PlyIndex line_write_ply;
    ZobristKey line_write_key;
    logic req_valid;
    ThreadID req_thread;
    PlyIndex req_ply, req_start_ply;
    logic [3:0] req_epoch;
    ZobristKey req_key;
    logic resp_valid;
    ThreadID resp_thread;
    logic [3:0] resp_epoch;
    logic [1:0] resp_previous_count;
    logic resp_is_draw;
    int pass_count = 0;
    int fail_count = 0;

    always #5 clk = ~clk;

    repetition_checker #(.SEARCH_THREAD_COUNT(2), .SEARCH_STACK_DEPTH(8)) dut (
        .clk, .rst_n, .flush,
        .active_history_reset(history_reset), .active_history_write(history_write), .active_history_key(history_key),
        .init_start, .init_busy, .init_done, .init_failed,
        .line_write_valid, .line_write_thread, .line_write_ply, .line_write_key,
        .req_valid, .req_thread, .req_ply, .req_start_ply, .req_epoch, .req_key,
        .resp_valid, .resp_thread, .resp_epoch, .resp_previous_count, .resp_is_draw
    );

    task automatic check(input logic condition, input string label);
        if (condition) begin
            pass_count += 1;
        end else begin
            fail_count += 1;
            $error("[FAIL] %s", label);
        end
    endtask

    task automatic history_sample(input ZobristKey key, input logic reset_history);
        @(negedge clk); history_key = key; history_reset = reset_history; history_write = !reset_history;
        @(negedge clk); history_reset = 0; history_write = 0;
    endtask

    task automatic initialize;
        @(negedge clk); init_start = 1;
        @(negedge clk); init_start = 0;
        wait (init_done || init_failed);
        check(init_done && !init_failed, "static construction completes collision-free");
    endtask

    task automatic line_sample(input int thread_id, input int ply, input ZobristKey key);
        @(negedge clk); line_write_valid = 1; line_write_thread = ThreadID'(thread_id);
        line_write_ply = PlyIndex'(ply); line_write_key = key;
        @(negedge clk); line_write_valid = 0;
    endtask

    task automatic request(input int thread_id, input int ply, input int start_ply, input ZobristKey key,
                           input logic [1:0] expected_count, input string label);
        @(negedge clk); req_valid = 1; req_thread = ThreadID'(thread_id); req_ply = PlyIndex'(ply);
        req_start_ply = PlyIndex'(start_ply); req_key = key; req_epoch = 4'ha;
        @(negedge clk); req_valid = 0;
        wait (resp_valid);
        check(resp_thread == ThreadID'(thread_id) && resp_epoch == 4'ha, {label, " tag"});
        check(resp_previous_count == expected_count, {label, " count"});
        check(resp_is_draw == (expected_count >= 2), {label, " decision"});
    endtask

    // Drive four consecutive requests and verify that no response bubble is introduced.
    task automatic request_burst;
        int received;
        fork
            begin
                for (int index = 0; index < 4; index++) begin
                    @(negedge clk);
                    req_valid = 1;
                    req_thread = ThreadID'(index & 1);
                    req_ply = PlyIndex'((index >= 2) ? 1 : 0);
                    req_start_ply = 0;
                    req_key = (index == 0) ? 64'h1111
                        : (index == 1) ? 64'h9999
                        : (index == 2) ? 64'h2222 : 64'h1111;
                    req_epoch = 4'(index + 1);
                end
                @(negedge clk);
                req_valid = 0;
            end
            begin
                received = 0;
                while (received < 4) begin
                    @(negedge clk);
                    if (resp_valid && resp_epoch >= 1 && resp_epoch <= 4) begin
                        received++;
                        check(resp_epoch == 4'(received), "burst response order");
                        case (received)
                            1: check(resp_previous_count == 2, "burst root hit count");
                            2: check(resp_previous_count == 0, "burst root miss count");
                            3: check(resp_previous_count == 2, "burst odd-parity hit count");
                            4: check(resp_previous_count == 0, "burst odd-parity miss count");
                        endcase
                    end
                end
            end
        join
    endtask

    initial begin
        history_reset = 1'b0;
        history_write = 1'b0;
        init_start = 1'b0;
        line_write_valid = 1'b0;
        req_valid = 1'b0;
        history_key = '0;
        line_write_thread = '0;
        line_write_ply = '0;
        line_write_key = '0;
        req_thread = '0;
        req_ply = '0;
        req_start_ply = '0;
        req_epoch = '0;
        req_key = '0;
        repeat (3) @(negedge clk);
        rst_n = 1'b1;

        // A,B,A,B,A(root): excluding the root leaves two prior root-parity A positions.
        history_sample(64'h1111, 1);
        history_sample(64'h2222, 0);
        history_sample(64'h1111, 0);
        history_sample(64'h2222, 0);
        history_sample(64'h1111, 0);
        initialize();
        request(0, 0, 0, 64'h1111, 2, "pre-root threefold");
        request(1, 0, 0, 64'h9999, 0, "no occurrence");
        request_burst();

        line_sample(0, 1, 64'haaaa);
        line_sample(0, 2, 64'hbbbb);
        line_sample(0, 3, 64'haaaa);
        line_sample(0, 4, 64'hcccc);
        request(0, 5, 1, 64'haaaa, 2, "two line occurrences");
        request(0, 5, 4, 64'haaaa, 0, "irreversible lower boundary");

        @(negedge clk); flush = 1; req_valid = 1; req_key = 64'h1111;
        @(negedge clk); flush = 0; req_valid = 0;
        repeat (7) @(negedge clk);
        check(!resp_valid, "flush discards in-flight response");

        $display("Pass Count: %0d", pass_count);
        $display("Fail Count: %0d", fail_count);
        if (fail_count != 0) $fatal(1, "repetition checker testbench failed");
        $finish;
    end

    // Bound protocol waits so a missing response cannot stall the test run.
    initial begin
        #1_000_000;
        $fatal(1, "repetition checker testbench timed out");
    end
endmodule
