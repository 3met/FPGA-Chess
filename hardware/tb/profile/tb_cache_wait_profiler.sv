`timescale 1ns/1ps

// Check overlapping requests, wraparound, and unfinished requests independently of the TT.
module tb_cache_wait_profiler;
    logic clk = 0, rst_n = 0, enable = 1, accept = 0, access = 0;
    longint unsigned wait_cycles, accesses;
    int pending, checks = 0;
    always #5 clk = ~clk;
    cache_wait_profiler #(.QUEUE_DEPTH(2)) dut (.*);

    // Hold controls for one measuring edge, then inspect committed counters.
    task automatic tick(input logic enqueue, issue);
        @(negedge clk);
        accept = enqueue;
        access = issue;
        @(posedge clk); #1;
    endtask

    // Completion markers let the normal RTL runner verify that assertions executed.
    task automatic check(input bit condition, input string message);
        if (!condition) $fatal(1, "%s", message);
        checks++;
    endtask
    initial begin
        @(posedge clk); #1;
        rst_n = 1;
        tick(1, 0);
        tick(1, 0);
        tick(1, 1);
        tick(0, 1);
        tick(0, 1);
        check(accesses == 3 && wait_cycles == 6 && pending == 0,
            "overlap or wraparound corrupted request wait times");
        tick(1, 0);
        tick(0, 0);
        tick(0, 0);
        check(accesses == 3 && wait_cycles == 6 && pending == 1,
            "unfinished request entered completed-access averages");
        tick(0, 1);
        check(accesses == 4 && wait_cycles == 9 && pending == 0,
            "queued idle cycles were excluded from request wait");
        enable = 0;
        tick(1, 0);
        check(pending == 0 && accesses == 4, "disabled measurement accepted a request");
        rst_n = 0;
        tick(0, 0);
        check(accesses == 0 && wait_cycles == 0 && pending == 0,
            "measurement reset did not clear counters");
        $display("Pass Count: %0d", checks); $display("Fail Count: 0");
        $finish;
    end
    initial begin #10_000; $fatal(1, "cache wait profiler timeout"); end
endmodule
