`timescale 1ns/1ps

// Exercise overlapping probes and reordered stores across independent clocks.
module tb_tt_latency_profiler;
    logic clk = 0, memory_clk = 0, rst_n = 0, enable = 1;
    logic probe_accept = 0, probe_classify = 0, probe_cache_hit = 0, probe_complete = 0;
    int probe_accept_thread = 0, probe_classify_thread = 0, probe_complete_thread = 0;
    logic store_accept = 0, store_drop = 0, store_issue = 0, store_classify = 0;
    logic store_cache_hit = 0, store_enqueue = 0;
    logic replacement_valid = 0, replacement_cache = 0, replacement_write = 0;
    logic commit_valid = 0, commit_ready = 1, memory_write_done = 0;
    int checks = 0;
    int metrics_fd;
    string metrics_file;
    longint unsigned hit_started, miss_started, elapsed;
    always #5.123 clk = ~clk;
    always #7.321 memory_clk = ~memory_clk;
    tt_latency_profiler #(.THREAD_COUNT(2)) dut (.*);

    // Publish one set of stage events, then disable them away from the sampling edge.
    task automatic tick(input int events);
        @(negedge clk);
        {store_drop, commit_valid, replacement_valid, store_classify, store_issue,
            store_accept, probe_complete, probe_classify, probe_accept} = 9'(events);
        @(posedge clk); #1;
        {store_drop, commit_valid, replacement_valid, store_classify, store_issue,
            store_accept, probe_complete, probe_classify, probe_accept} = '0;
    endtask

    // Check each meaningful invariant without relying on engine configuration.
    task automatic check(input bit condition, input string message);
        if (!condition) $fatal(1, "%s", message);
        checks++;
    endtask

    // Retire a write on the memory clock and inspect its exact cross-clock duration.
    task automatic finish_write(input bit hit, input longint unsigned started);
        @(negedge memory_clk); memory_write_done = 1;
        @(posedge memory_clk); #1; memory_write_done = 0;
        elapsed = longint'(($realtime - 1.0) * 1000.0) - started;
        check(dut.histogram[1][int'(hit)][elapsed] == 1, "cross-clock write latency lost precision");
    endtask

    initial begin
        @(posedge clk); #1; rst_n = 1;
        tick(1);
        probe_accept_thread = 1;
        tick(3);
        probe_classify_thread = 1; probe_cache_hit = 1;
        tick(2);
        probe_complete_thread = 1; tick(4);
        probe_complete_thread = 0; tick(4);
        check(dut.samples[0][1] == 1 && dut.total_ps[0][1] == 20492, "cache-hit probe duration incorrect");
        check(dut.samples[0][0] == 1 && dut.total_ps[0][0] == 40984, "overlapping cache-miss probe duration incorrect");
        probe_accept_thread = 0; tick(1);
        check(dut.samples[0][0] == 1 && dut.probe_active[0], "unfinished probe entered completed samples");

        tick(8); miss_started = longint'(($realtime - 1.0) * 1000.0);
        tick(24); hit_started = longint'(($realtime - 1.0) * 1000.0);
        store_enqueue = 1; tick(48);
        store_cache_hit = 1; tick(32);
        replacement_cache = 1; replacement_write = 1; tick(64);
        tick(128);
        replacement_cache = 0; tick(64);
        tick(128);
        check(dut.samples[1][0] == 0 && dut.samples[1][1] == 0, "store completed before SDRAM acknowledgement");
        finish_write(1, hit_started);
        finish_write(0, miss_started);
        check(dut.samples[1][1] == 1 && dut.samples[1][0] == 1, "reordered stores lost cache classification");

        store_cache_hit = 0; tick(8); tick(16); tick(32);
        replacement_write = 0; tick(64);
        check(dut.samples[1][0] == 2, "non-replacing store did not complete at its decision");
        store_enqueue = 0; tick(8); tick(16); tick(32); tick(256);
        check(dut.dropped_stores == 2 && dut.samples[1][0] == 2, "dropped stores entered completed samples");
        store_cache_hit = 1; tick(8); tick(16); tick(32);
        replacement_cache = 1; replacement_write = 1; tick(64);
        commit_ready = 0; tick(128);
        check(dut.dropped_stores == 3 && dut.written_stores.size() == 0, "dropped writeback retained a timestamp");
        if ($value$plusargs("METRICS_FILE=%s", metrics_file)) begin
            metrics_fd = $fopen(metrics_file, "w");
            dut.write_metrics(metrics_fd);
            $fdisplay(metrics_fd, "PROFILE_COMPLETE");
            $fclose(metrics_fd);
        end
        rst_n = 0; tick(0);
        check(dut.samples[0][0] == 0 && dut.samples[1][1] == 0
            && dut.histogram[1][0].num() == 0, "reset retained latency measurements");
        $display("Pass Count: %0d", checks);
        $display("Fail Count: 0");
        $finish;
    end
endmodule
