`timescale 1ns/1ps
import chess_defs::*;
import tt_defs::*;
module tb_tt_external_load_store;
    parameter int TAG_BITS = 32;
    localparam int TEST_ENTRIES = 16;
    localparam int WAY_WORDS = (TAG_BITS+TT_ENTRY_PAYLOAD_BITS+TT_WORD_BITS-1)/TT_WORD_BITS;
    localparam int WORD_COUNT = TEST_ENTRIES*TT_WAYS*WAY_WORDS;
    logic clk = 0, memory_clk = 0, rst_n = 0;
    always #5 clk = !clk;
    always #3.5 memory_clk = !memory_clk;
    logic clear = 0, clear_busy;
    logic lookup_req_valid = 0, lookup_req_ready, lookup_resp_valid;
    TTLookupRequest lookup_req;
    TTLookupResponse lookup_resp;
    logic store_req_valid = 0, store_req_ready;
    TTStoreRequest store_req;
    logic cache_access, cache_hit, cache_store_access, store_bank_valid, store_bank, cache_store_hit;
    logic mem_req_valid, mem_req_ready, mem_req_write;
    TTWordAddress mem_req_address;
    TTBurstLength mem_req_length;
    logic mem_write_valid, mem_write_ready, mem_write_last;
    logic [15:0] mem_write_data;
    logic mem_read_valid, mem_read_ready, mem_read_last;
    logic [15:0] mem_read_data;
    logic mem_done_valid, mem_done_ready, mem_done_error;
    logic memory_enabled = 1, model_req_ready;
    int response_count = 0;
    always @(posedge clk) if (rst_n && lookup_resp_valid) response_count++;
    assign mem_req_ready = memory_enabled && model_req_ready;
    int pass_count = 0, fail_count = 0;
    tt_external_load_store #(.TAG_BITS(TAG_BITS), .CACHE_INDEX_BITS(3), .ENTRY_COUNT(TEST_ENTRIES),
        .STORE_FIFO_DEPTH(4), .OUTSTANDING_DEPTH(4)) dut (
        .clk, .rst_n, .memory_clk, .memory_rst_n(rst_n), .memory_ready(1'b1), .memory_error(1'b0),
        .clear, .clear_busy, .lookup_req_valid, .lookup_req_ready, .lookup_req, .lookup_resp_valid, .lookup_resp,
        .cache_access, .cache_hit, .cache_store_access, .cache_store_hit, .store_req_valid, .store_req_ready, .store_req,
        .store_bank_valid, .store_bank, .mem_req_valid, .mem_req_ready, .mem_req_write, .mem_req_address, .mem_req_length,
        .mem_write_valid, .mem_write_ready, .mem_write_data, .mem_write_last,
        .mem_read_valid, .mem_read_ready, .mem_read_data, .mem_read_last, .mem_done_valid, .mem_done_ready, .mem_done_error);
    tt_burst_memory_model #(.WORD_COUNT(WORD_COUNT), .READ_DELAY(12)) memory (
        .clk(memory_clk), .rst_n, .req_valid(mem_req_valid && memory_enabled), .req_ready(model_req_ready), .req_write(mem_req_write),
        .req_address(mem_req_address), .req_length(mem_req_length), .write_valid(mem_write_valid), .write_ready(mem_write_ready),
        .write_data(mem_write_data), .write_last(mem_write_last), .read_valid(mem_read_valid), .read_ready(mem_read_ready),
        .read_data(mem_read_data), .read_last(mem_read_last), .done_valid(mem_done_valid), .done_ready(mem_done_ready), .done_error(mem_done_error));
    // Drive and inspect away from active edges to avoid simulator scheduling races.
    task automatic check(input logic condition, input string label);
        if (condition) pass_count++; else begin fail_count++; $error("[FAIL] %s", label); end
    endtask
    // Concurrent misses and publications may lose heuristic data, but a hit must
    // retain one position's complete payload and return to its requesting thread.
    task automatic stress_concurrent_requests();
        bit pending[2];
        int target[2];
        int issued = 0, returned = 0, hits = 0;
        logic [31:0] random_state = 32'h71c9_02e5;
        bit accepted_probe;
        int identity, nonce, tid;
        ZobristKey key;
        pending[0] = 0; pending[1] = 0;
        // Seed known complete entries before saturating the best-effort stores.
        for (int id = 1; id <= 24; id++) begin
            key = (ZobristKey'(32'(id)*32'h9e37_79b9) << TAG_BITS) | ZobristKey'(id);
            key[63] = id[0];
            store(key, 0, id*256, 0, TT_BOUND_EXACT,
                Move'({Position'(id), Position'(0), PROMO_QUEEN}));
        end
        for (int cycle = 0; cycle < 20000 || pending[0] || pending[1]; cycle++) begin
            @(negedge clk);
            random_state ^= random_state << 13;
            random_state ^= random_state >> 17;
            random_state ^= random_state << 5;
            if (cycle < 20000) begin
                identity = 1 + int'(random_state[4:0]) % 24;
                nonce = int'(random_state[13:8]);
                key = (ZobristKey'(32'(identity)*32'h9e37_79b9) << TAG_BITS) | ZobristKey'(identity);
                key[63] = identity[0];
                store_req = '0; store_req.zobrist_key = key;
                store_req.score = EvalScore'(identity*256 + nonce);
                store_req.depth = TTDepth'(nonce);
                store_req.bound_type = TTBoundType'(1 + nonce % 3);
                store_req.age = TTAge'(cycle / 97);
                store_req.best_move = Move'({Position'(identity), Position'(nonce), PROMO_QUEEN});
                store_req_valid = random_state[16];
                tid = int'(random_state[17]);
                if (!lookup_req_valid && !pending[tid]) begin
                    identity = 1 + int'(random_state[22:18]) % 24;
                    key = (ZobristKey'(32'(identity)*32'h9e37_79b9) << TAG_BITS) | ZobristKey'(identity);
                    key[63] = identity[0];
                    lookup_req = '0; lookup_req.zobrist_key = key;
                    lookup_req.thread_id = ThreadID'(tid); lookup_req_valid = 1;
                end
            end else begin lookup_req_valid = 0; store_req_valid = 0; end
            @(posedge clk);
            accepted_probe = lookup_req_valid && lookup_req_ready;
            if (accepted_probe) begin
                tid = int'(lookup_req.thread_id);
                if (pending[tid]) $fatal(1, "stress reused pending thread %0d", tid);
                pending[tid] = 1; target[tid] = int'(TAG_BITS'(lookup_req.zobrist_key)); issued++;
            end
            if (lookup_resp_valid) begin
                tid = int'(lookup_resp.thread_id);
                if (!pending[tid]) $fatal(1, "stress returned an unowned response to thread %0d", tid);
                if (lookup_resp.hit) begin
                    nonce = int'(lookup_resp.score) % 256;
                    if (int'(lookup_resp.score)/256 != target[tid] || nonce >= 64
                            || lookup_resp.depth != TTDepth'(nonce)
                            || lookup_resp.bound_type != TTBoundType'(1 + nonce % 3)
                            || lookup_resp.best_move.from_pos != Position'(target[tid])
                            || lookup_resp.best_move.to_pos != Position'(nonce))
                        $fatal(1, "stress hit mixed or misrouted payload: thread %0d key %0d score %0d", tid, target[tid], lookup_resp.score);
                    hits++;
                end
                pending[tid] = 0; returned++;
            end
            #1;
            if (accepted_probe) lookup_req_valid = 0;
        end
        lookup_req_valid = 0; store_req_valid = 0; drain();
        check(issued == returned && issued > 100, "concurrent probes retire exactly once");
        check(hits > 0, "mixed concurrent traffic exercises checked hits");
    endtask
    task automatic drain();
        repeat (12) @(negedge clk);
        while (dut.store_fifo_count != 0 || dut.store_buffer_valid || dut.store_pending
                || dut.store_meta_count != 0 || dut.probe_meta_count != 0 || !dut.transport_idle || dut.fill_valid
                || dut.store_fill_valid || dut.bank_fill_pending != 0 || dut.cache_store_valid || dut.commit_valid)
            @(negedge clk);
        repeat (8) @(negedge clk);
    endtask
    task automatic store(input ZobristKey key, input int depth, input int score,
        input TTAge age = 0, input TTBoundType bound = TT_BOUND_EXACT, input Move move = Move'({6'd1,6'd18,PROMO_QUEEN}));
        @(negedge clk); store_req = '0; store_req.zobrist_key = key;
        store_req.depth = TTDepth'(depth); store_req.score = EvalScore'(score); store_req.age = age;
        store_req.bound_type = bound; store_req.best_move = move;
        store_req_valid = 1;
        do @(negedge clk); while (!store_req_ready);
        store_req_valid = 0; drain();
    endtask
    task automatic probe(input ZobristKey key, input logic hit, input int score = 0, input ThreadID tid = 0, input int stream_way = -1, input logic expect_cached = 0);
        int baseline, wait_cycles;
        baseline = response_count;
        @(negedge clk); lookup_req = '0; lookup_req.zobrist_key = key; lookup_req.thread_id = tid;
        lookup_req_valid = 1;
        do @(negedge clk); while (!lookup_req_ready);
        lookup_req_valid = 0; wait_cycles = 0;
        while (!lookup_resp_valid) begin @(negedge clk); wait_cycles++; end
        if (expect_cached) check(wait_cycles == 2, "cached probe retains its two-cycle acceptance-to-response latency");
        check(lookup_resp.hit == hit && lookup_resp.thread_id == tid, $sformatf("probe %h hit and routing", key));
        if (hit) check(lookup_resp.score == EvalScore'(score), $sformatf("probe %h score", key));
        if (stream_way >= 0) begin
            if (stream_way == 0)
                check(memory.busy && !memory.writing && memory.remaining != 0,
                    "first-way hit returns while the external read is still in flight");
            if (stream_way < TT_WAYS-1)
                check(!dut.probe_complete && int'(dut.probe_word_count) == (stream_way+1)*WAY_WORDS,
                    "hit returns at its way boundary before the complete entry");
            else check(dut.probe_complete, "last-way hit or complete miss waits for every word");
        end
        drain();
        if (stream_way >= 0) check(response_count == baseline+1, "streamed probe returns exactly once after draining its tail");
    endtask
    // Require the cache hit's fixed pipeline latency as well as the expected payload.
    task automatic cached_probe(input ZobristKey key, input int score);
        probe(key, 1, score, ThreadID'(0), -1, 1);
    endtask
    initial begin
        repeat (3) @(negedge clk); rst_n = 1;
        while (clear_busy) @(negedge clk);
        // All three external ways coexist, although only two positions fit in their cache set.
        store(64'h1, 8, 101); store(64'h2, 6, 102); store(64'h3, 4, 103);
        probe(64'h1, 1, 101); probe(64'h2, 1, 102); probe(64'h3, 1, 103);
        // Two unrelated positions sharing this set can evict both cached positions.
        begin
            ZobristKey evict_key, evict_partner;
            int reads_before;
            evict_key = '0;
            for (int i = 1; i < 100 && evict_key == 0; i++) begin
                ZobristKey candidate;
                candidate = (ZobristKey'(32'(i)*32'h9e37_79b9) << TAG_BITS) | ZobristKey'(17);
                candidate[63] = 1'b0;
                if (dut.entry_index(candidate) == 8) evict_key = candidate;
            end
            check(evict_key != 0, "found another external group sharing the cache set");
            evict_partner = evict_key ^ ZobristKey'(17 ^ 18);
            store(evict_key, 5, 117); store(evict_partner, 5, 118);
            reads_before = memory.read_count;
            probe(64'h1, 1, 101); probe(64'h2, 1, 102); probe(64'h3, 1, 103);
            check(memory.read_count == reads_before+3, "each uncached position fetches its own way despite sharing an external entry");
            // Touch one resident position, then admit a third: only the LRU must leave.
            probe(64'h2, 1, 102);
            probe(64'h1, 1, 101);
            reads_before = memory.read_count;
            probe(64'h2, 1, 102);
            check(memory.read_count == reads_before, "recently used cache way survives another admission");
            probe(64'h3, 1, 103);
            check(memory.read_count == reads_before+1, "cache admission evicts the least recently used way");
            // Evict before each lookup so every way position takes the streaming path.
            for (int way = 0; way < TT_WAYS; way++) begin
                store(evict_key, 5, 117); store(evict_partner, 5, 118);
                probe(ZobristKey'(way+1), 1, 101+way, ThreadID'(way % 2), way);
                reads_before = memory.read_count;
                cached_probe(ZobristKey'(way+1), 101+way);
                check(memory.read_count == reads_before, "stream hit admits its complete matching way to cache");
                probe(ZobristKey'((way+1)%TT_WAYS+1), 1, 101+(way+1)%TT_WAYS);
                check(memory.read_count == reads_before+1, "unrelated ways from the response are not admitted");
            end
            // Overlapping fills for the same position must update one slot, not consume both.
            store(evict_key, 5, 117); store(evict_partner, 5, 118);
            cached_probe(evict_key, 117);
            begin
                int returned, reads_start;
                logic [1:0] owners;
                returned = 0; owners = 0; reads_start = memory.read_count;
                @(negedge clk); lookup_req = '0; lookup_req.zobrist_key = 64'h1;
                lookup_req_valid = 1;
                do @(negedge clk); while (!lookup_req_ready);
                lookup_req.thread_id = ThreadID'(1);
                do @(negedge clk); while (!lookup_req_ready);
                lookup_req_valid = 0;
                while (returned < 2) begin
                    @(negedge clk);
                    if (lookup_resp_valid) begin
                        if (!lookup_resp.hit || lookup_resp.score != EvalScore'(101))
                            $fatal(1, "overlapping fill returned an incorrect payload");
                        owners[int'(lookup_resp.thread_id)] = 1'b1; returned++;
                    end
                end
                drain();
                check(owners == 2'b11 && memory.read_count == reads_start+2, "overlapping misses route both ordered memory responses");
                reads_start = memory.read_count;
                cached_probe(evict_key, 117); cached_probe(64'h1, 101);
                check(memory.read_count == reads_start, "duplicate fills retain the unrelated hot cache way");
            end
            // Use the other bank so the eventual stream fill cannot evict the cached target.
            // Sustained cache hits must neither starve the stream nor overwrite its reply.
            store(64'h8000_0000_0000_0011, 5, 117);
            store(evict_key, 5, 117); store(evict_partner, 5, 118);
            begin
                int baseline, reads_start, cache_issued, stream_hits;
                logic routed;
                baseline = response_count; reads_start = memory.read_count;
                cache_issued = 0; stream_hits = 0; routed = 1;
                @(negedge clk); lookup_req = '0; lookup_req.zobrist_key = 64'h1;
                lookup_req_valid = 1;
                do @(negedge clk); while (!lookup_req_ready);
                lookup_req_valid = 0;
                while (memory.read_count == reads_start) @(negedge clk);
                lookup_req.zobrist_key = 64'h8000_0000_0000_0011; lookup_req.thread_id = ThreadID'(1);
                lookup_req_valid = 1;
                for (int cycle = 0; cycle < 80; cycle++) begin
                    @(posedge clk);
                    if (lookup_req_valid && lookup_req_ready) cache_issued++;
                    if (lookup_resp_valid) begin
                        if (lookup_resp.thread_id == ThreadID'(0)) begin
                            stream_hits++;
                            routed &= lookup_resp.hit && lookup_resp.score == EvalScore'(101);
                        end else routed &= lookup_resp.hit && lookup_resp.score == EvalScore'(117);
                    end
                    @(negedge clk);
                end
                lookup_req_valid = 0;
                check(stream_hits == 1 && routed, "stream hit makes progress during sustained correctly routed cache replies");
                drain();
                check(response_count == baseline+cache_issued+1, "cache/stream response arbitration retires every probe exactly once");
            end
            // Reuse a thread immediately after its early hit, while its old tail still drains.
            store(evict_key, 5, 117); store(evict_partner, 5, 118);
            begin
                int baseline;
                baseline = response_count;
                @(negedge clk); lookup_req = '0; lookup_req.zobrist_key = 64'h1;
                lookup_req_valid = 1;
                do @(negedge clk); while (!lookup_req_ready);
                lookup_req_valid = 0;
                while (!lookup_resp_valid) @(negedge clk);
                check(lookup_resp.hit && lookup_resp.score == EvalScore'(101) && !dut.probe_complete,
                    "thread receives first-way hit with response tail outstanding");
                lookup_req.zobrist_key = 64'h2; lookup_req_valid = 1;
                do @(negedge clk); while (!lookup_req_ready);
                lookup_req_valid = 0;
                while (!lookup_resp_valid) @(negedge clk);
                check(lookup_resp.hit && lookup_resp.score == EvalScore'(102) && lookup_resp.thread_id == ThreadID'(0),
                    "reused thread gets the new probe payload while old metadata drains");
                drain();
                check(response_count == baseline+2, "early thread reuse returns each accepted probe exactly once");
            end
        end
        // An external miss must not allocate or evict any cache way.
        begin
            int reads_before; reads_before = memory.read_count;
            probe(64'h7, 0, 0, 0, TT_WAYS-1);
            check(memory.read_count == reads_before + 1, "uncached position fetches external entry");
            probe(64'h1, 1, 101); probe(64'h2, 1, 102);
            check(memory.read_count == reads_before + 1, "external miss preserves both resident cache ways");
        end
        begin
            int reads_before;
            logic neighbors_preserved, selected_changed;
            logic [TT_WORD_BITS-1:0] before_words[TT_WAYS*WAY_WORDS];
            reads_before = memory.read_count;
            for (int word = 0; word < TT_WAYS*WAY_WORDS; word++) before_words[word] = memory.memory[word];
            store(64'h2, 7, 202);
            check(memory.read_count == reads_before, "matching cache way skips memory read");
            neighbors_preserved = 1; selected_changed = 0;
            for (int word = 0; word < TT_WAYS*WAY_WORDS; word++)
                if (word < WAY_WORDS || word >= 2*WAY_WORDS)
                    neighbors_preserved &= memory.memory[word] == before_words[word];
                else selected_changed |= memory.memory[word] != before_words[word];
            check(neighbors_preserved && selected_changed,
                "cache-hit store uses saved external way selector and preserves neighboring ways");
        end
        probe(64'h1, 1, 101); probe(64'h2, 1, 202); probe(64'h3, 1, 103);
        store(64'h2, 1, 999); probe(64'h2, 1, 202);
        store(64'h4, 2, 104); probe(64'h3, 0); probe(64'h1, 1, 101); probe(64'h2, 1, 202); probe(64'h4, 1, 104);
        // A deep but old way loses to fresher shallower ways.
        @(negedge clk); clear = 1; @(negedge clk); clear = 0;
        while (clear_busy) @(negedge clk);
        store(64'h1, 20, 101, TTAge'(0));
        store(64'h2, 3, 102, TTAge'(3)); store(64'h3, 4, 103, TTAge'(3));
        store(64'h4, 2, 104, TTAge'(4)); probe(64'h1, 0); probe(64'h2, 1, 102);
        // Ages wrap modularly and do not invalidate hits from older searches.
        @(negedge clk); clear = 1; @(negedge clk); clear = 0;
        while (clear_busy) @(negedge clk);
        store(64'h5, 20, 305, TTAge'(-1));
        store(64'h2, 3, 102, TTAge'(0)); store(64'h3, 4, 103, TTAge'(0));
        store(64'h6, 1, 106, TTAge'(0)); probe(64'h5, 1, 305);
        // The MSB selects bank one independently of the low verification tag.
        store(64'h8000_0000_0000_0001, 3, 401); probe(64'h8000_0000_0000_0001, 1, 401, ThreadID'(1));
        probe(64'h6, 1, 106);
        // No move uses the impossible equal-square encoding, queen decoding needs no bit.
        store(64'h8000_0000_0000_0002, 3, 402, 0, TT_BOUND_EXACT, NULL_MOVE);
        probe(64'h8000_0000_0000_0002, 1, 402);
        check(lookup_resp.best_move.from_pos == lookup_resp.best_move.to_pos, "omitted move stays omitted");
        // Probe a matching way on the same edge as a store cache write.
        @(negedge clk); store_req = '0; store_req.zobrist_key = 64'h6;
        store_req.depth = TTDepth'(9); store_req.score = EvalScore'(606); store_req.bound_type = TT_BOUND_EXACT;
        store_req_valid = 1; @(negedge clk); store_req_valid = 0;
        while (!(dut.replacement_valid && dut.replacement_write)) @(negedge clk);
        lookup_req = '0; lookup_req.zobrist_key = 64'h6; lookup_req.thread_id = ThreadID'(1);
        lookup_req_valid = 1; @(negedge clk); lookup_req_valid = 0;
        check(dut.bank_read_enable[0] && dut.bank_write_enable[0]
            && dut.bank_read_index[0] == dut.bank_write_index[0], "forwarding test overlaps the physical cache ports");
        while (!lookup_resp_valid) @(negedge clk);
        check(lookup_resp.hit && lookup_resp.score == EvalScore'(606), "same-set read forwards the newly written individual way");
        drain();
        // A cached thread must finish while another thread waits for SDRAM.
        begin
            ZobristKey missing_key;
            int reads_before;
            missing_key = '0;
            for (int i = 1; i < 100 && missing_key == 0; i++) begin
                ZobristKey candidate;
                candidate = (ZobristKey'(32'(i)*32'h9e37_79b9) << TAG_BITS) | ZobristKey'(17);
                candidate[63] = 1'b0;
                if (dut.entry_index(candidate) == 2) missing_key = candidate;
            end
            reads_before = memory.read_count;
            @(negedge clk); lookup_req = '0; lookup_req.zobrist_key = missing_key; lookup_req_valid = 1;
            @(negedge clk); lookup_req_valid = 0;
            while (memory.read_count == reads_before) @(negedge clk);
            lookup_req.zobrist_key = 64'h8000_0000_0000_0001; lookup_req.thread_id = ThreadID'(1); lookup_req_valid = 1;
            @(negedge clk); lookup_req_valid = 0;
            while (!lookup_resp_valid) @(negedge clk);
            check(lookup_resp.hit && lookup_resp.thread_id == ThreadID'(1) && lookup_resp.score == 401,
                "cache-hit thread bypasses older outstanding memory probe");
            @(negedge clk); while (!lookup_resp_valid) @(negedge clk);
            check(!lookup_resp.hit && lookup_resp.thread_id == ThreadID'(0), "older memory probe keeps its own thread identity");
            drain();
        end
        // Write overflow still updates the matching cached way without stalling search.
        memory_enabled = 0;
        @(negedge clk); store_req = '0; store_req.zobrist_key = 64'h6;
        store_req.depth = TTDepth'(9); store_req.score = EvalScore'(707); store_req.bound_type = TT_BOUND_EXACT;
        store_req_valid = 1;
        repeat (60) @(negedge clk);
        store_req_valid = 0;
        while (dut.store_fifo_count != 0 || dut.store_buffer_valid || dut.store_pending) @(negedge clk);
        check(!dut.way_write_ready, "one-way FIFO fills while cache stores continue");
        lookup_req = '0; lookup_req.zobrist_key = 64'h6; lookup_req_valid = 1;
        @(negedge clk); lookup_req_valid = 0;
        while (!lookup_resp_valid) @(negedge clk);
        check(lookup_resp.hit && lookup_resp.score == EvalScore'(707), "cache retains publication even when external write is dropped");
        memory_enabled = 1; drain();
        // New Game physically invalidates every external and cached way.
        @(negedge clk); clear = 1; @(negedge clk); clear = 0;
        while (clear_busy) @(negedge clk);
        probe(64'h6, 0); probe(64'h8000_0000_0000_0001, 0);
        store(64'h1, 1, 501); probe(64'h1, 1, 501);
        // Exhaust the outstanding probe capacity while the memory port is blocked.
        begin
            ZobristKey missing_key;
            int baseline, reads_before;
            logic all_probes_ready;
            missing_key = '0;
            for (int i = 1; i < 100 && missing_key == 0; i++) begin
                ZobristKey candidate;
                candidate = (ZobristKey'(32'(i)*32'h9e37_79b9) << TAG_BITS) | ZobristKey'(17);
                candidate[63] = 1'b0;
                if (dut.entry_index(candidate) == 2) missing_key = candidate;
            end
            check(missing_key != 0, "found an uncached group for overflow testing");
            baseline = response_count; reads_before = memory.read_count; memory_enabled = 0;
            @(negedge clk); lookup_req = '0; lookup_req.zobrist_key = missing_key; lookup_req_valid = 1;
            all_probes_ready = 1;
            repeat (7) begin @(negedge clk); all_probes_ready &= lookup_req_ready; end
            check(all_probes_ready, "full miss queue does not stall probes");
            lookup_req_valid = 0; repeat (6) @(negedge clk);
            check(response_count-baseline == 3, "overflow probes immediately return miss");
            check(memory.read_count == reads_before, "blocked memory has no partially started request");
            memory_enabled = 1; drain();
            check(response_count-baseline == 7, "every accepted probe responds exactly once");
            check(memory.read_count-reads_before == 4, "only queued probes perform memory reads");
        end
        // Clear waits for an already-started probe and invalidates its eventual fill.
        begin
            int baseline, reads_before;
            baseline = response_count; reads_before = memory.read_count;
            @(negedge clk); lookup_req = '0; lookup_req.zobrist_key = 64'h9;
            lookup_req_valid = 1; @(negedge clk); lookup_req_valid = 0;
            while (memory.read_count == reads_before) @(negedge clk);
            clear = 1; @(negedge clk); clear = 0;
            while (clear_busy) @(negedge clk);
            check(response_count == baseline+1, "clear drains the in-flight probe exactly once");
            probe(64'h1, 0);
        end
        stress_concurrent_requests();
        $display("Pass Count: %0d", pass_count); $display("Fail Count: %0d", fail_count);
        if (fail_count) $fatal(1, "TT test failed"); $finish;
    end
    initial begin #2_000_000; $fatal(1, "TT test timeout"); end
endmodule

// Field-driven sizing must work on either side of a memory-word boundary.
module tb_tt_external_load_store_small_tag;
    tb_tt_external_load_store #(.TAG_BITS(16)) test();
endmodule
module tb_tt_external_load_store_large_tag;
    tb_tt_external_load_store #(.TAG_BITS(48)) test();
endmodule
