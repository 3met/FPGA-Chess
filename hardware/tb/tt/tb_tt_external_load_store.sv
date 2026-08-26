`timescale 1ns/1ns

import chess_defs::*;
import tt_defs::*;

module tb_tt_external_load_store;
    logic clk = 1'b0;
    logic rst_n = 1'b0;
    logic clear = 1'b0;
    always #5 clk = ~clk;
    TTLookupRequest lookup_req; logic lookup_req_valid, lookup_req_ready, lookup_resp_valid;
    TTLookupResponse lookup_resp;
    TTStoreRequest store_req; logic store_req_valid, store_req_ready;
    logic mem_req_valid, mem_req_ready, mem_req_write; TTWordAddress mem_req_address; logic [3:0] mem_req_length;
    logic mem_write_valid, mem_write_ready, mem_write_last; logic [15:0] mem_write_data;
    logic mem_read_valid, mem_read_ready, mem_read_last; logic [15:0] mem_read_data;
    logic mem_done_valid, mem_done_ready, mem_done_error;
    logic cache_access, cache_hit, cache_access_is_store;
    logic [15:0] memory[0:95];
    logic read_active, write_active, completion_pending; logic [24:0] memory_address; logic [3:0] memory_remaining;
    int request_count, pass_count, fail_count;
    int lookup_cache_access_count, lookup_cache_hit_count, store_cache_access_count;
    TTAge old_generation;

    tt_external_load_store #(
        .CACHE_INDEX_BITS(2), .TAG_BITS(32), .ENTRY_COUNT(16), .STORE_FIFO_DEPTH(2)
    ) dut (
        .clk, .rst_n, .memory_ready(1'b1), .memory_error(1'b0), .clear, .clear_busy(),
        .lookup_req_valid, .lookup_req_ready, .lookup_req, .lookup_resp_valid, .lookup_resp,
        .cache_access, .cache_hit, .cache_access_is_store,
        .store_req_valid, .store_req_ready, .store_req,
        .mem_req_valid, .mem_req_ready, .mem_req_write, .mem_req_address, .mem_req_length,
        .mem_write_valid, .mem_write_ready, .mem_write_data, .mem_write_last,
        .mem_read_valid, .mem_read_ready, .mem_read_data, .mem_read_last,
        .mem_done_valid, .mem_done_ready, .mem_done_error);

    assign mem_req_ready = !read_active && !write_active;
    assign mem_write_ready = write_active;
    assign mem_done_valid = completion_pending;
    assign mem_done_error = 1'b0;

    always @(posedge clk) begin
        mem_read_valid <= 1'b0;
        if (!rst_n) begin
            read_active <= 1'b0; write_active <= 1'b0; completion_pending <= 1'b0; request_count <= 0;
            lookup_cache_access_count <= 0; lookup_cache_hit_count <= 0; store_cache_access_count <= 0;
        end else begin
            if (cache_access) begin
                if (cache_access_is_store) store_cache_access_count <= store_cache_access_count + 1;
                else begin
                    lookup_cache_access_count <= lookup_cache_access_count + 1;
                    if (cache_hit) lookup_cache_hit_count <= lookup_cache_hit_count + 1;
                end
            end
            if (completion_pending && mem_done_ready) completion_pending <= 1'b0;
            if (mem_req_valid && mem_req_ready) begin
                request_count <= request_count + 1;
                memory_address <= mem_req_address;
                memory_remaining <= mem_req_length;
                if (mem_req_write) write_active <= 1'b1; else read_active <= 1'b1;
            end
            if (read_active && mem_read_ready) begin
                mem_read_valid <= 1'b1;
                mem_read_data <= memory[memory_address];
                mem_read_last <= memory_remaining == 1;
                memory_address <= memory_address + 1;
                memory_remaining <= memory_remaining - 1;
                if (memory_remaining == 1) begin
                    read_active <= 1'b0;
                    completion_pending <= 1'b1;
                end
            end
            if (write_active && mem_write_valid) begin
                memory[memory_address] <= mem_write_data;
                memory_address <= memory_address + 1;
                memory_remaining <= memory_remaining - 1;
                if (mem_write_last || memory_remaining == 1) begin
                    write_active <= 1'b0;
                    completion_pending <= 1'b1;
                end
            end
        end
    end

    task automatic check(input logic condition, input string label);
        if (condition) begin
            pass_count += 1;
        end else begin
            fail_count += 1;
            $error("[FAIL] %s", label);
        end
    endtask
    task automatic do_store(
        input ZobristKey key,
        input TTDepth depth = TTDepth'(6),
        input EvalScore score = EvalScore'(123),
        input TTBoundType bound_type = TT_BOUND_EXACT,
        input PlyIndex ply = PlyIndex'(0)
    );
        store_req = TTStoreRequest'('0); store_req.zobrist_key = key;
        store_req.depth = depth; store_req.score = score; store_req.bound_type = bound_type;
        store_req.ply = ply;
        store_req.best_move.from_pos = 1; store_req.best_move.to_pos = 18;
        store_req_valid = 1;
        do @(posedge clk); while (!store_req_ready);
        store_req_valid = 0;
        do @(posedge clk); while (dut.store_fifo_count != 0 || dut.store_write_pending
            || dut.state != dut.S_IDLE);
    endtask
    task automatic do_lookup(
        input ZobristKey key,
        input logic expected_hit,
        input ThreadID thread_id,
        input EvalScore expected_score = EvalScore'(123),
        input PlyIndex ply = PlyIndex'(0),
        input string label = "lookup"
    );
        lookup_req = TTLookupRequest'('0); lookup_req.zobrist_key = key; lookup_req.thread_id = thread_id;
        lookup_req.ply = ply;
        lookup_req_valid = 1;
        do @(posedge clk); while (!lookup_req_ready);
        lookup_req_valid = 0;
        do @(posedge clk); while (!lookup_resp_valid);
        check(lookup_resp.thread_id == thread_id, {label, " retained thread tag"});
        check(lookup_resp.hit == expected_hit, {label, expected_hit ? " hit" : " miss"});
        if (expected_hit) check(lookup_resp.score == expected_score, {label, " score"});
    endtask

    initial begin
        lookup_req_valid = 0; store_req_valid = 0; mem_read_valid = 0;
        pass_count = 0; fail_count = 0;
        for (int i = 0; i < 96; i++) memory[i] = 0;
        repeat (3) @(posedge clk); rst_n = 1; repeat (8) @(posedge clk);
        do_store(64'h0123_4567_89ab_cdef);
        check(request_count == 2, "store used read and write bursts");
        do_store(64'h0123_4567_89ab_cdef);
        check(request_count == 3, "cache-resident store skipped replacement read");
        do_lookup(64'h0123_4567_89ab_cdef, 1'b1, ThreadID'(1),
            EvalScore'(123), PlyIndex'(0), "cache-resident lookup");
        @(posedge clk);
        check(request_count == 3, "cache hit avoided SDRAM");
        check(store_cache_access_count == 2, "store cache probes identified separately");
        check(lookup_cache_access_count == 1, "lookup cache probe counted");
        check(lookup_cache_hit_count == 1, "lookup cache hit counted");

        // A cache hit must bypass an unrelated external lookup miss instead of
        // waiting for the single SDRAM transaction to finish.
        lookup_req = TTLookupRequest'('0);
        lookup_req.zobrist_key = 64'h1000_0000_0000_0001;
        lookup_req.thread_id = ThreadID'(0);
        lookup_req_valid = 1;
        do @(posedge clk); while (!lookup_req_ready);
        lookup_req_valid = 0;
        do @(posedge clk); while (!read_active);
        lookup_req = TTLookupRequest'('0);
        lookup_req.zobrist_key = 64'h0123_4567_89ab_cdef;
        lookup_req.thread_id = ThreadID'(1);
        lookup_req_valid = 1;
        do @(posedge clk); while (!lookup_req_ready);
        lookup_req_valid = 0;
        do @(posedge clk); while (!lookup_resp_valid);
        check(lookup_resp.thread_id == ThreadID'(1) && lookup_resp.hit,
            "cache hit bypassed active SDRAM miss");
        do @(posedge clk); while (!lookup_resp_valid);
        check(lookup_resp.thread_id == ThreadID'(0) && !lookup_resp.hit,
            "older external miss completed after bypass hit");

        // A lookup miss arriving during a store replacement read must run
        // before the store's deferred write.
        store_req = TTStoreRequest'('0);
        store_req.zobrist_key = 64'h2345_6789_abcd_ef01;
        store_req.depth = TTDepth'(7);
        store_req.score = EvalScore'(77);
        store_req.bound_type = TT_BOUND_EXACT;
        store_req_valid = 1;
        do @(posedge clk); while (!store_req_ready);
        store_req_valid = 0;
        do @(posedge clk); while (!read_active);
        lookup_req = TTLookupRequest'('0);
        lookup_req.zobrist_key = 64'h789a_bcde_f012_3456;
        lookup_req.thread_id = ThreadID'(1);
        lookup_req_valid = 1;
        do @(posedge clk); while (!lookup_req_ready);
        lookup_req_valid = 0;
        do @(posedge clk); while (!dut.lookup_miss_valid);
        do @(posedge clk); while (!(mem_req_valid && mem_req_ready));
        check(!mem_req_write, "lookup miss preempted deferred store write");
        do @(posedge clk); while (!lookup_resp_valid);
        check(lookup_resp.thread_id == ThreadID'(1), "preempting lookup retained thread tag");
        do @(posedge clk); while (dut.store_write_pending || dut.state != dut.S_IDLE);

        // Stores are accepted while the backend is occupied. Once the queue
        // fills, later publications are consumed and dropped without stalling.
        lookup_req = TTLookupRequest'('0);
        lookup_req.zobrist_key = 64'h1000_0000_0000_0001;
        lookup_req_valid = 1;
        do @(posedge clk); while (!lookup_req_ready);
        lookup_req_valid = 0;
        do @(posedge clk); while (!read_active);
        begin
            automatic bit all_stores_accepted = 1'b1;
            for (int idx = 0; idx < 3; idx++) begin
                store_req = TTStoreRequest'('0);
                store_req.zobrist_key = 64'h2000_0000_0000_0000 + idx;
                store_req.depth = TTDepth'(idx + 1);
                store_req.bound_type = TT_BOUND_EXACT;
                store_req_valid = 1;
                @(posedge clk);
                all_stores_accepted &= store_req_ready;
            end
            check(all_stores_accepted, "busy frontend consumed every store publication");
        end
        store_req_valid = 0;
        check(dut.store_fifo_count == 2, "external store FIFO bounded overflow by dropping");
        do @(posedge clk); while (!lookup_resp_valid);

        // A New Game pulse must remain pending while another thread owns the
        // external-memory transaction, then invalidate it when the port idles.
        old_generation = dut.generation;
        lookup_req = TTLookupRequest'('0);
        lookup_req.zobrist_key = 64'hfedc_ba98_7654_3210;
        lookup_req.thread_id = ThreadID'(1);
        lookup_req_valid = 1;
        do @(posedge clk); while (!lookup_req_ready);
        lookup_req_valid = 0;
        do @(posedge clk); while (!read_active);
        clear = 1; @(posedge clk); clear = 0;
        do @(posedge clk); while (!lookup_resp_valid);
        do @(posedge clk); while (dut.clear_busy);
        check(dut.generation == old_generation + TTAge'(1), "busy clear pulse advanced generation");

        clear = 1; @(posedge clk); clear = 0; repeat (2) @(posedge clk);
        do_lookup(64'h0123_4567_89ab_cdef, 1'b0, ThreadID'(0),
            EvalScore'(123), PlyIndex'(0), "post-clear lookup");
        check(mem_req_address < 80 && mem_req_length == 5, "bounded aligned burst mapping");

        // An old-generation result survives a much shallower publication. This
        // must match the inferred-RAM backend's shared depth/age policy.
        do_store(64'h3456_789a_bcde_f012, TTDepth'(12), EvalScore'(321));
        clear = 1; @(posedge clk); clear = 0;
        do @(posedge clk); while (dut.clear_busy);
        request_count = 0;
        do_store(64'h3456_789a_bcde_f012, TTDepth'(1), EvalScore'(111));
        check(request_count == 1, "stale deep entry read but rejected shallow replacement write");

        // At equal depth, an exact result replaces a non-exact bound.
        do_store(64'h4567_89ab_cdef_0123, TTDepth'(8), EvalScore'(210), TT_BOUND_UPPER);
        request_count = 0;
        do_store(64'h4567_89ab_cdef_0123, TTDepth'(8), EvalScore'(211), TT_BOUND_EXACT);
        check(request_count == 1, "equal-depth exact result replaced upper bound");
        do_lookup(64'h4567_89ab_cdef_0123, 1'b1, ThreadID'(0),
            EvalScore'(211), PlyIndex'(0), "exact replacement lookup");
        request_count = 0;
        do_store(64'h4567_89ab_cdef_0123, TTDepth'(8), EvalScore'(212), TT_BOUND_LOWER);
        check(request_count == 0, "equal-depth bound did not overwrite exact entry");
        do_lookup(64'h4567_89ab_cdef_0123, 1'b1, ThreadID'(0),
            EvalScore'(211), PlyIndex'(0), "exact entry survives equal-depth bound");

        // Stored mate distance is node-relative and restored for the lookup ply.
        do_store(64'h5678_9abc_def0_1234, TTDepth'(4),
            EvalScore'(MATE_SCORE - 5), TT_BOUND_EXACT, PlyIndex'(5));
        do_lookup(64'h5678_9abc_def0_1234, 1'b1, ThreadID'(0),
            EvalScore'(MATE_SCORE - 2), PlyIndex'(2), "mate-distance lookup");

        $display("Pass Count: %0d", pass_count);
        $display("Fail Count: %0d", fail_count);
        if (fail_count != 0) $fatal(1, "external TT test failed");
        $finish;
    end

    // Bound frontend and memory-model waits so a stalled transaction fails promptly in CI.
    initial begin
        #1_000_000;
        $fatal(1, "external TT testbench timed out");
    end
endmodule
