`timescale 1ns/1ps

// Testbench-only end-to-end TT request timing, including queued SDRAM writes.
module tt_latency_profiler #(parameter int THREAD_COUNT = 1) (
    input logic clk, memory_clk, rst_n, enable,
    input logic probe_accept, probe_classify, probe_cache_hit, probe_complete,
    input int probe_accept_thread, probe_classify_thread, probe_complete_thread,
    input logic store_accept, store_drop, store_issue, store_classify, store_cache_hit, store_enqueue,
    input logic replacement_valid, replacement_cache, replacement_write,
    input logic commit_valid, commit_ready, memory_write_done
);
    typedef struct packed { longint unsigned started_ps; bit hit; } StoreTime;
    StoreTime queued_stores[$], cache_stores[$], miss_stores[$], written_stores[$];
    StoreTime staged_store, committed_store;
    bit staged_valid, committed_valid;
    bit probe_active[THREAD_COUNT], probe_hit[THREAD_COUNT];
    longint unsigned probe_started_ps[THREAD_COUNT];
    longint unsigned samples[2][2], total_ps[2][2];
    longint unsigned histogram[2][2][longint unsigned];
    longint unsigned dropped_stores;

    // Picosecond timestamps preserve the phase difference between both clocks.
    function automatic longint unsigned now_ps();
        realtime sampled_ns;
        sampled_ns = $realtime;
        return longint'(sampled_ns * 1000.0);
    endfunction

    // Sparse exact histograms avoid allocating storage proportional to queue latency.
    task automatic record_latency(input int operation, input bit hit, input longint unsigned started_ps);
        longint unsigned elapsed_ps;
        elapsed_ps = now_ps() - started_ps;
        samples[operation][int'(hit)]++;
        total_ps[operation][int'(hit)] += elapsed_ps;
        if (!histogram[operation][int'(hit)].exists(elapsed_ps))
            histogram[operation][int'(hit)][elapsed_ps] = 0;
        histogram[operation][int'(hit)][elapsed_ps]++;
    endtask

    // Retire each stage before accepting its successor, allowing overlap and
    // cache-hit stores to complete ahead of older stores waiting on memory.
    always @(posedge clk) begin
        if (!rst_n) begin
            queued_stores.delete(); cache_stores.delete(); miss_stores.delete(); written_stores.delete();
            staged_valid = 0; committed_valid = 0; dropped_stores = 0;
            for (int operation = 0; operation < 2; operation++) begin
                for (int hit = 0; hit < 2; hit++) begin
                    samples[operation][hit] = 0; total_ps[operation][hit] = 0;
                    histogram[operation][hit].delete();
                end
            end
            for (int thread_id = 0; thread_id < THREAD_COUNT; thread_id++) begin
                probe_active[thread_id] = 0; probe_hit[thread_id] = 0;
            end
        end else if (enable) begin
            if (probe_classify) begin
                if (!probe_active[probe_classify_thread]) $fatal(1, "TT probe classification without acceptance");
                probe_hit[probe_classify_thread] = probe_cache_hit;
            end
            if (probe_complete) begin
                if (!probe_active[probe_complete_thread]) $fatal(1, "TT probe completion without acceptance");
                record_latency(0, probe_hit[probe_complete_thread], probe_started_ps[probe_complete_thread]);
                probe_active[probe_complete_thread] = 0;
            end
            if (probe_accept) begin
                if (probe_active[probe_accept_thread]) $fatal(1, "TT probe timestamp overwritten");
                probe_active[probe_accept_thread] = 1;
                probe_hit[probe_accept_thread] = 0;
                probe_started_ps[probe_accept_thread] = now_ps();
            end
            if (commit_valid) begin
                if (!committed_valid) $fatal(1, "TT write publication without store timestamp");
                if (commit_ready) written_stores.push_back(committed_store);
                else dropped_stores++;
                committed_valid = 0;
            end
            if (replacement_valid) begin
                StoreTime finished;
                if (replacement_cache) begin
                    if (cache_stores.size() == 0) $fatal(1, "TT cache replacement without timestamp");
                    finished = cache_stores.pop_front();
                end else begin
                    if (miss_stores.size() == 0) $fatal(1, "TT miss replacement without timestamp");
                    finished = miss_stores.pop_front();
                end
                if (replacement_write) begin
                    if (committed_valid) $fatal(1, "TT store commit timestamp overwritten");
                    committed_store = finished; committed_valid = 1;
                end else record_latency(1, finished.hit, finished.started_ps);
            end
            if (store_classify) begin
                if (!staged_valid) $fatal(1, "TT store classification without timestamp");
                staged_store.hit = store_cache_hit;
                if (store_cache_hit) cache_stores.push_back(staged_store);
                else if (store_enqueue) miss_stores.push_back(staged_store);
                else dropped_stores++;
                staged_valid = 0;
            end
            if (store_issue) begin
                if (queued_stores.size() == 0) $fatal(1, "TT store issue without acceptance");
                if (staged_valid) $fatal(1, "TT store stage timestamp overwritten");
                staged_store = queued_stores.pop_front(); staged_valid = 1;
            end
            if (store_drop) dropped_stores++;
            if (store_accept) begin
                StoreTime accepted;
                accepted.started_ps = now_ps(); accepted.hit = 0;
                queued_stores.push_back(accepted);
            end
        end
    end

    // Writes retire in transport FIFO order on the actual memory completion edge.
    always @(posedge memory_clk) begin
        if (rst_n && enable && memory_write_done) begin
            StoreTime finished;
            if (written_stores.size() == 0) $fatal(1, "TT memory write completion without timestamp");
            finished = written_stores.pop_front();
            record_latency(1, finished.hit, finished.started_ps);
        end
    end

    // Emit samples and exact bins; the host pools bins before deriving percentiles.
    task automatic write_metrics(input int fd);
        for (int operation = 0; operation < 2; operation++) begin
            for (int hit = 0; hit < 2; hit++) begin
                string prefix;
                string outcome;
                longint unsigned latency_bins[longint unsigned];
                outcome = "miss";
                if (hit) outcome = "hit";
                prefix = $sformatf("tt.latency.%s.%s", operation == 0 ? "probe" : "store", outcome);
                $fdisplay(fd, "METRIC\t%s.samples\t%0d", prefix, samples[operation][hit]);
                $fdisplay(fd, "METRIC\t%s.total_ps\t%0d", prefix, total_ps[operation][hit]);
                latency_bins = histogram[operation][hit];
                foreach (latency_bins[latency_ps])
                    $fdisplay(fd, "METRIC\t%s.histogram.%0d\t%0d", prefix, latency_ps, latency_bins[latency_ps]);
            end
        end
        begin
            int unfinished_probes;
            unfinished_probes = 0;
            foreach (probe_active[thread_id]) unfinished_probes += int'(probe_active[thread_id]);
            $fdisplay(fd, "METRIC\ttt.latency.probe.unfinished\t%0d", unfinished_probes);
            $fdisplay(fd, "METRIC\ttt.latency.store.unfinished\t%0d", queued_stores.size()
                + cache_stores.size() + miss_stores.size() + written_stores.size()
                + int'(staged_valid) + int'(committed_valid));
        end
        $fdisplay(fd, "METRIC\ttt.latency.store.dropped\t%0d", dropped_stores);
    endtask
endmodule
