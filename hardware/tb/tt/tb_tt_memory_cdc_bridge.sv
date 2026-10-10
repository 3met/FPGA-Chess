`timescale 1ns/1ps
import tt_defs::*;
module tb_tt_memory_cdc_bridge;
    localparam int ENTRIES = 8;
    localparam int ENTRY_INDEX_BITS = $clog2(ENTRIES+1);
    typedef logic [ENTRY_INDEX_BITS-1:0] EntryIndex;
    localparam int WAY_WORDS = TT_WORDS_PER_WAY;
    localparam int ENTRY_WORDS = TT_WORDS_PER_ENTRY;
    localparam int RESPONSE_DEPTH = 1 << $clog2(2*ENTRY_WORDS);
    logic clk = 0, mem_clk = 0, rst_n = 0;
    always #5 clk = !clk;
    always #3.5 mem_clk = !mem_clk;
    logic clear_toggle = 0, clear_ack, idle;
    logic probe_valid = 0, probe_ready, probe_response_valid, probe_response_ready = 0;
    EntryIndex probe_entry_index = 0;
    logic [15:0] probe_response_data;
    logic store_valid = 0, store_ready, store_response_valid, store_response_ready = 0;
    EntryIndex store_entry_index = 1;
    logic [15:0] store_response_data;
    logic write_valid = 0, write_ready;
    EntryIndex write_entry_index = 2;
    logic [$clog2(TT_WAYS)-1:0] write_way_index = 1;
    TTPhysicalEntry write_way = '1;
    logic backend_req_valid, backend_req_ready, backend_req_write;
    TTWordAddress backend_req_address;
    TTBurstLength backend_req_length;
    logic backend_write_valid, backend_write_ready, backend_write_last;
    logic [15:0] backend_write_data;
    logic backend_read_valid, backend_read_ready, backend_read_last;
    logic [15:0] backend_read_data;
    logic backend_done_valid, backend_done_ready, backend_done_error;
    logic enabled = 0, model_ready;
    logic [1:0] read_fault = 0;
    int pass_count = 0, fail_count = 0;
    int accepted = 0;
    logic reservations_safe = 1, bursts_unstalled = 1;
    logic probe_streamed_early = 0, store_streamed_early = 0;
    int addresses[32], lengths[32];
    logic writes[32];
    tt_memory_cdc_bridge #(.ENTRY_COUNT(ENTRIES), .READ_FIFO_DEPTH(4), .RESPONSE_FIFO_DEPTH(RESPONSE_DEPTH)) dut (
        .req_clk(clk), .req_rst_n(rst_n), .mem_clk, .mem_rst_n(rst_n),
        .clear_toggle, .clear_ack, .idle, .probe_valid, .probe_ready, .probe_entry_index,
        .probe_response_valid, .probe_response_ready, .probe_response_data,
        .store_valid, .store_ready, .store_entry_index, .store_response_valid, .store_response_ready, .store_response_data,
        .write_valid, .write_ready, .write_entry_index, .write_way_index, .write_way,
        .backend_req_valid, .backend_req_ready, .backend_req_write, .backend_req_address, .backend_req_length,
        .backend_write_valid, .backend_write_ready, .backend_write_data, .backend_write_last,
        .backend_read_valid, .backend_read_ready, .backend_read_data, .backend_read_last,
        .backend_done_valid, .backend_done_ready, .backend_done_error);
    assign backend_req_ready = enabled && model_ready;
    tt_burst_memory_model #(.WORD_COUNT(ENTRIES*ENTRY_WORDS)) memory (
        .clk(mem_clk), .rst_n, .req_valid(backend_req_valid && enabled), .req_ready(model_ready), .req_write(backend_req_write),
        .req_address(backend_req_address), .req_length(backend_req_length),
        .write_valid(backend_write_valid), .write_ready(backend_write_ready), .write_data(backend_write_data), .write_last(backend_write_last),
        .read_valid(backend_read_valid), .read_ready(backend_read_ready), .read_data(backend_read_data), .read_last(backend_read_last),
        .done_valid(backend_done_valid), .done_ready(backend_done_ready), .done_error(backend_done_error), .read_fault);
    always @(posedge mem_clk) if (rst_n && backend_req_valid && backend_req_ready) begin
        if (accepted < 32) begin
            addresses[accepted] = int'(backend_req_address); lengths[accepted] = int'(backend_req_length);
            writes[accepted] = backend_req_write;
        end
        accepted++;
    end
    // Observe actual capacity when staged eligibility advances a request FIFO.
    always @(posedge mem_clk) if (rst_n) begin
        if (backend_read_valid) bursts_unstalled &= backend_read_ready;
        if (dut.probe_pop) reservations_safe &= int'(dut.probe_free) >= ENTRY_WORDS;
        if (dut.store_pop) reservations_safe &= int'(dut.store_free) >= ENTRY_WORDS;
        reservations_safe &= !(dut.probe_response_push && dut.probe_response_full)
            && !(dut.store_response_push && dut.store_response_full);
    end
    // Observe FIFO visibility before physical capture finishes, for both response classes.
    always @(posedge clk) if (rst_n && memory.busy && !memory.writing && memory.remaining > 1) begin
        if (dut.operation_probe && probe_response_valid) probe_streamed_early = 1;
        if (!dut.operation_probe && store_response_valid) store_streamed_early = 1;
    end
    task automatic check(input logic condition, input string label);
        if (condition) pass_count++; else begin fail_count++; $error("[FAIL] %s", label); end
    endtask
    // Enqueue all classes while memory is held off so priority is unambiguous.
    task automatic enqueue(input logic probe, input logic store, input logic write);
        @(negedge clk); probe_valid = probe; store_valid = store; write_valid = write;
        @(negedge clk); check((!probe || probe_ready) && (!store || store_ready) && (!write || write_ready), "request enqueue has space");
        check(!idle, "newly queued request immediately inhibits clear readiness");
        probe_valid = 0; store_valid = 0; write_valid = 0;
    endtask
    task automatic settle(); repeat (120) @(negedge clk); endtask
    // Distinct address-derived words detect missing/reordered words and wrong routing.
    function automatic logic [TT_WORD_BITS-1:0] expected_word(input int address);
        return TT_WORD_BITS'(16'h1357 + address * 17);
    endfunction
    task automatic consume_response(input logic probe, input int count, input int start_address, input int valid_words = ENTRY_WORDS);
        logic ordered;
        ordered = 1;
        for (int i = 0; i < count; i++) begin
            while (!(probe ? probe_response_valid : store_response_valid)) @(negedge clk);
            ordered &= (probe ? probe_response_data : store_response_data)
                == (i % ENTRY_WORDS >= valid_words ? TT_WORD_BITS'(0) : expected_word(start_address + i % ENTRY_WORDS));
            if (probe) probe_response_ready = 1; else store_response_ready = 1;
            @(negedge clk);
            probe_response_ready = 0; store_response_ready = 0;
        end
        check(ordered, probe ? "complete ordered probe response" : "complete ordered store response");
    endtask
    initial begin
        repeat (3) @(negedge clk); rst_n = 1;
        for (int i = 0; i < ENTRIES*ENTRY_WORDS; i++) memory.memory[i] = expected_word(i);
        repeat (8) @(negedge clk); check(idle, "empty transport reports clear readiness");
        enqueue(1,1,1); repeat (8) @(negedge clk); enabled = 1; settle();
        check(accepted == 3 && !writes[0] && addresses[0] == 0
            && !writes[1] && addresses[1] == ENTRY_WORDS && writes[2], "probe then store then one-way write priority");
        check(probe_streamed_early && store_streamed_early, "both response FIFOs stream before the backend burst finishes");
        check(lengths[0] == ENTRY_WORDS && lengths[1] == ENTRY_WORDS && lengths[2] == WAY_WORDS, "reads whole groups and writes one way");
        begin
            logic preserved; preserved = 1;
            for (int i = 0; i < ENTRY_WORDS; i++)
                preserved &= memory.memory[2*ENTRY_WORDS+i] == ((i >= WAY_WORDS && i < 2*WAY_WORDS) ? 16'hffff : expected_word(2*ENTRY_WORDS+i));
            check(preserved, "single-way write preserves neighboring ways");
        end
        enqueue(1,0,0); settle(); check(accepted == 4, "second complete probe response fits");
        enqueue(1,0,0); settle(); check(accepted == 4, "probe burst blocked without whole-response reservation");
        enqueue(0,1,0); settle(); check(accepted == 5, "store read proceeds while probe response space is blocked");
        enqueue(0,1,0); settle(); check(accepted == 5, "store burst blocked without whole-response reservation");
        enqueue(0,0,1); settle(); check(accepted == 6, "write proceeds while response FIFOs are blocked");
        consume_response(1, ENTRY_WORDS, 0); settle(); check(accepted == 7, "probe resumes only after enough response words drain");
        consume_response(1, 2*ENTRY_WORDS, 0);
        consume_response(0, 2*ENTRY_WORDS, ENTRY_WORDS); settle();
        check(accepted == 8, "store resumes after response space becomes available");
        consume_response(0, ENTRY_WORDS, ENTRY_WORDS);
        while (!idle) @(negedge clk);
        // Short reads preserve streamed words and pad the tail; late errors cannot retract data.
        for (int fault = 1; fault <= 3; fault++) begin
            read_fault = 2'(fault);
            enqueue(1, 1, 0);
            consume_response(1, ENTRY_WORDS, 0, fault == 1 ? 0 : fault == 2 ? ENTRY_WORDS/2 : ENTRY_WORDS);
            consume_response(0, ENTRY_WORDS, ENTRY_WORDS, fault == 1 ? 0 : fault == 2 ? ENTRY_WORDS/2 : ENTRY_WORDS);
            while (!idle) @(negedge clk);
        end
        read_fault = 0;
        enqueue(1, 1, 0);
        consume_response(1, ENTRY_WORDS, 0);
        consume_response(0, ENTRY_WORDS, ENTRY_WORDS);
        while (!idle) @(negedge clk);
        // Fast failures exercise reservations while the previous group still drains.
        begin
            int baseline;
            baseline = accepted; read_fault = 1; enabled = 0;
            repeat (3) enqueue(1,0,0);
            enabled = 1; settle();
            check(accepted == baseline+2, "pending response words reserve capacity for fast consecutive reads");
            consume_response(1, 2*ENTRY_WORDS, 0, 0); settle();
            check(accepted == baseline+3, "reserved read resumes after complete response space is freed");
            consume_response(1, ENTRY_WORDS, 0, 0);
            while (!idle) @(negedge clk);
            read_fault = 0;
        end
        // Translate the highest legal entry and every way selector without touching neighbors.
        write_entry_index = EntryIndex'(ENTRIES-1);
        for (int way = 0; way < TT_WAYS; way++) begin
            int baseline;
            logic preserved;
            baseline = accepted;
            write_way_index = $clog2(TT_WAYS)'(way);
            for (int word = 0; word < WAY_WORDS; word++)
                write_way[word*TT_WORD_BITS +: TT_WORD_BITS] = TT_WORD_BITS'(16'ha000 + way*WAY_WORDS + word);
            enqueue(0,0,1);
            while (!idle) @(negedge clk);
            check(accepted == baseline+1 && writes[baseline]
                && addresses[baseline] == (ENTRIES-1)*ENTRY_WORDS + way*WAY_WORDS,
                "logical entry and way select the exact physical write address");
            preserved = 1;
            for (int word = 0; word < ENTRY_WORDS; word++)
                preserved &= memory.memory[(ENTRIES-1)*ENTRY_WORDS+word]
                    == (word < (way+1)*WAY_WORDS ? TT_WORD_BITS'(16'ha000 + word)
                        : expected_word((ENTRIES-1)*ENTRY_WORDS+word));
            check(preserved, "selected-way translation preserves the rest of the entry");
        end
        probe_entry_index = EntryIndex'(ENTRIES-1);
        enqueue(1,0,0);
        begin
            logic ordered;
            ordered = 1;
            for (int word = 0; word < ENTRY_WORDS; word++) begin
                while (!probe_response_valid) @(negedge clk);
                ordered &= probe_response_data == TT_WORD_BITS'(16'ha000 + word);
                probe_response_ready = 1;
                @(negedge clk); probe_response_ready = 0;
            end
            check(ordered, "logical last-entry probe returns all three written ways in order");
        end
        while (!idle) @(negedge clk);
        // Make the last response push cross the whole-entry capacity threshold.
        // Stale eligibility on that edge would wrongly admit the next queued read.
        begin
            int baseline, groups, drain_words;
            baseline = accepted;
            groups = RESPONSE_DEPTH / ENTRY_WORDS;
            read_fault = 1; enabled = 0;
            repeat (groups) enqueue(1,0,0);
            enabled = 1; settle();
            check(accepted == baseline + groups, "response FIFO filled with complete invalid groups");
            enabled = 0;
            repeat (2) enqueue(1,0,0);
            drain_words = 2*ENTRY_WORDS - 1 - (RESPONSE_DEPTH - groups*ENTRY_WORDS);
            consume_response(1, drain_words, 0, 0); settle();
            enabled = 1; settle();
            check(accepted == baseline + groups + 1,
                "last response push revoked eligibility before another read was selected");
            consume_response(1, (groups+1)*ENTRY_WORDS - drain_words, 0, 0); settle();
            check(accepted == baseline + groups + 2, "threshold-blocked read resumed after draining space");
            consume_response(1, ENTRY_WORDS, 0, 0);
            while (!idle) @(negedge clk);
            read_fault = 0;
        end
        // A pending clear must drain the last queued write even if the backend
        // was blocked when its request pointer crossed into the memory domain.
        enabled = 0;
        enqueue(0,0,1);
        clear_toggle = 1;
        repeat (8) @(negedge clk); enabled = 1;
        while (!clear_ack) @(negedge clk);
        begin
            logic cleared; cleared = 1;
            for (int i = 0; i < ENTRIES*TT_WAYS; i++) cleared &= memory.memory[i*WAY_WORDS][1:0] == 0;
            check(cleared, "clear invalidates every external way");
        end
        check(bursts_unstalled, "reserved responses accept every backend word without stalls");
        check(reservations_safe, "registered eligibility always reserves actual whole-response capacity");
        $display("Pass Count: %0d", pass_count); $display("Fail Count: %0d", fail_count);
        if (fail_count) $fatal(1, "TT transport test failed"); $finish;
    end
    initial begin #1_000_000; $fatal(1, "TT transport timeout"); end
endmodule
