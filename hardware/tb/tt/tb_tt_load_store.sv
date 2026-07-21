// Run in Questa/ModelSim from the repository root after compiling RTL and this file:
// vsim -t ns work.tb_tt_load_store
// run -all

`timescale 1ns/1ns

import general_chess_defs::*;
import tt_defs::*;

module tb_tt_load_store;

    localparam int TEST_TT_INDEX_BITS = 4;
    localparam int TEST_STORE_FIFO_DEPTH = 4;

    typedef logic [15:0] KeySuffix;

    logic clk;
    logic rst_n;
    logic clear;
    logic clear_busy;

    logic lookup_req_valid;
    logic lookup_req_ready;
    TTLookupRequest lookup_req;
    logic lookup_resp_valid;
    TTLookupResponse lookup_resp;

    logic store_req_valid;
    logic store_req_ready;
    TTStoreRequest store_req;

    logic full_clear;
    logic full_clear_busy;
    logic full_lookup_req_valid;
    logic full_lookup_req_ready;
    TTLookupRequest full_lookup_req;
    logic full_lookup_resp_valid;
    TTLookupResponse full_lookup_resp;
    logic full_store_req_valid;
    logic full_store_req_ready;
    TTStoreRequest full_store_req;

    int pass_count = 0;
    int error_count = 0;

    tt_load_store #(
        .TT_INDEX_BITS(TEST_TT_INDEX_BITS),
        .STORE_FIFO_DEPTH(TEST_STORE_FIFO_DEPTH)
    ) dut (
        .clk(clk),
        .rst_n(rst_n),
        .clear(clear),
        .clear_busy(clear_busy),
        .lookup_req_valid(lookup_req_valid),
        .lookup_req_ready(lookup_req_ready),
        .lookup_req(lookup_req),
        .lookup_resp_valid(lookup_resp_valid),
        .lookup_resp(lookup_resp),
        .store_req_valid(store_req_valid),
        .store_req_ready(store_req_ready),
        .store_req(store_req)
    );

    tt_load_store #(
        .TT_INDEX_BITS(TEST_TT_INDEX_BITS),
        .STORE_FIFO_DEPTH(TEST_STORE_FIFO_DEPTH),
        .USE_FULL_KEY(1'b1)
    ) full_key_dut (
        .clk(clk),
        .rst_n(rst_n),
        .clear(full_clear),
        .clear_busy(full_clear_busy),
        .lookup_req_valid(full_lookup_req_valid),
        .lookup_req_ready(full_lookup_req_ready),
        .lookup_req(full_lookup_req),
        .lookup_resp_valid(full_lookup_resp_valid),
        .lookup_resp(full_lookup_resp),
        .store_req_valid(full_store_req_valid),
        .store_req_ready(full_store_req_ready),
        .store_req(full_store_req)
    );

    task automatic do_clock(input int cnt = 1);
        for (int i = 0; i < cnt; i++) begin
            clk = 1'b0; #5;
            clk = 1'b1; #5;
        end
    endtask

    function automatic Move make_move(input Position from_pos, input Position to_pos, input PromoType promo);
        automatic Move move;

        move.from_pos = from_pos;
        move.to_pos = to_pos;
        move.promo_piece = promo;
        return move;
    endfunction

    function automatic ZobristKey make_key(input TTVerifyKey verify_key, input logic [15:0] suffix);
        return {verify_key, suffix};
    endfunction

    function automatic TTStoreRequest make_store_req(
        input ZobristKey key,
        input TTDepth depth,
        input EvalScore score,
        input TTBoundType bound_type,
        input Move best_move,
        input TTAge age,
        input PlyIndex ply
    );
        automatic TTStoreRequest req;

        req.zobrist_key = key;
        req.depth = depth;
        req.score = score;
        req.bound_type = bound_type;
        req.best_move = best_move;
        req.age = age;
        req.ply = ply;
        return req;
    endfunction

    function automatic TTLookupRequest make_lookup_req(input ZobristKey key, input PlyIndex ply);
        automatic TTLookupRequest req;

        req.thread_id = ThreadID'(0);
        req.zobrist_key = key;
        req.depth = TTDepth'(0);
        req.alpha = MIN_EVAL_SCORE;
        req.beta = MAX_EVAL_SCORE;
        req.ply = ply;
        return req;
    endfunction

    task automatic record_pass();
        pass_count += 1;
    endtask

    task automatic record_fail(input string message);
        error_count += 1;
        $error("[%6t] %s", $time, message);
    endtask

    task automatic expect_equal(input bit condition, input string message);
        if (condition) begin
            record_pass();
        end else begin
            record_fail(message);
        end
    endtask

    task automatic reset_dut();
        clear = 1'b0;
        lookup_req_valid = 1'b0;
        lookup_req = TTLookupRequest'('0);
        store_req_valid = 1'b0;
        store_req = TTStoreRequest'('0);
        full_clear = 1'b0;
        full_lookup_req_valid = 1'b0;
        full_lookup_req = TTLookupRequest'('0);
        full_store_req_valid = 1'b0;
        full_store_req = TTStoreRequest'('0);
        rst_n = 1'b0;
        do_clock(2);
        rst_n = 1'b1;
        do_clock(1);
    endtask

    task automatic clear_table();
        clear = 1'b1;
        #1;
        expect_equal(!lookup_req_ready && !store_req_ready && clear_busy, "requests are stalled when clear is asserted");
        do_clock(1);
        clear = 1'b0;
        expect_equal(!lookup_req_ready && !store_req_ready, "requests are stalled while clear starts");
        while (clear_busy) begin
            do_clock(1);
        end
        do_clock(1);
        expect_equal(lookup_req_ready && store_req_ready, "requests are ready after clear");
    endtask

    task automatic full_clear_table();
        full_clear = 1'b1;
        #1;
        expect_equal(!full_lookup_req_ready && !full_store_req_ready && full_clear_busy, "full-key requests are stalled when clear is asserted");
        do_clock(1);
        full_clear = 1'b0;
        while (full_clear_busy) begin
            do_clock(1);
        end
        do_clock(1);
        expect_equal(full_lookup_req_ready && full_store_req_ready, "full-key requests are ready after clear");
    endtask

    task automatic clear_table_held_high();
        clear = 1'b1;
        #1;
        expect_equal(clear_busy && !lookup_req_ready && !store_req_ready, "held clear starts one clear operation");
        do_clock(3);
        while (clear_busy) begin
            do_clock(1);
        end
        expect_equal(lookup_req_ready && store_req_ready, "held clear does not restart after completion");
        clear = 1'b0;
        do_clock(1);
    endtask

    task automatic issue_store(input TTStoreRequest req);
        expect_equal(store_req_ready, "store request accepted when expected");
        store_req = req;
        store_req_valid = 1'b1;
        do_clock(1);
        store_req_valid = 1'b0;
        store_req = TTStoreRequest'('0);
    endtask

    task automatic full_issue_store(input TTStoreRequest req);
        expect_equal(full_store_req_ready, "full-key store request accepted when expected");
        full_store_req = req;
        full_store_req_valid = 1'b1;
        do_clock(1);
        full_store_req_valid = 1'b0;
        full_store_req = TTStoreRequest'('0);
    endtask

    task automatic drain_stores(input int cycles = 3);
        do_clock(cycles);
        while (dut.store_fifo_count != 0 || dut.store_fifo_valid || dut.store_state != dut.STORE_IDLE) do_clock(1);
    endtask

    task automatic full_drain_stores(input int cycles = 3);
        do_clock(cycles);
        while (full_key_dut.store_fifo_count != 0 || full_key_dut.store_fifo_valid
                || full_key_dut.store_state != full_key_dut.STORE_IDLE) do_clock(1);
    endtask

    task automatic issue_lookup(
        input TTLookupRequest req,
        output TTLookupResponse resp,
        output logic valid
    );
        expect_equal(lookup_req_ready, "lookup request accepted when expected");
        lookup_req = req;
        lookup_req_valid = 1'b1;
        do_clock(1);
        resp = lookup_resp;
        valid = lookup_resp_valid;
        lookup_req_valid = 1'b0;
        lookup_req = TTLookupRequest'('0);
        do_clock(1);
    endtask

    task automatic full_issue_lookup(
        input TTLookupRequest req,
        output TTLookupResponse resp,
        output logic valid
    );
        expect_equal(full_lookup_req_ready, "full-key lookup request accepted when expected");
        full_lookup_req = req;
        full_lookup_req_valid = 1'b1;
        do_clock(1);
        resp = full_lookup_resp;
        valid = full_lookup_resp_valid;
        full_lookup_req_valid = 1'b0;
        full_lookup_req = TTLookupRequest'('0);
        do_clock(1);
    endtask

    task automatic expect_lookup_hit(
        input ZobristKey key,
        input PlyIndex ply,
        input EvalScore expected_score,
        input TTDepth expected_depth,
        input TTBoundType expected_bound,
        input Move expected_move,
        input string test_name
    );
        automatic TTLookupResponse resp;
        automatic logic valid;

        issue_lookup(make_lookup_req(key, ply), resp, valid);
        expect_equal(valid, {test_name, " response valid"});
        expect_equal(resp.hit, {test_name, " hit"});
        expect_equal(resp.score === expected_score, {test_name, " score"});
        expect_equal(resp.depth == expected_depth, {test_name, " depth"});
        expect_equal(resp.bound_type == expected_bound, {test_name, " bound"});
        expect_equal(resp.best_move === expected_move, {test_name, " best move"});
    endtask

    task automatic expect_lookup_miss(input ZobristKey key, input string test_name);
        automatic TTLookupResponse resp;
        automatic logic valid;

        issue_lookup(make_lookup_req(key, PlyIndex'(0)), resp, valid);
        expect_equal(valid, {test_name, " response valid"});
        expect_equal(!resp.hit, {test_name, " miss"});
        expect_equal(resp.bound_type == TT_BOUND_INVALID, {test_name, " invalid bound"});
    endtask

    task automatic full_expect_lookup_hit(
        input ZobristKey key,
        input PlyIndex ply,
        input EvalScore expected_score,
        input TTDepth expected_depth,
        input TTBoundType expected_bound,
        input Move expected_move,
        input string test_name
    );
        automatic TTLookupResponse resp;
        automatic logic valid;

        full_issue_lookup(make_lookup_req(key, ply), resp, valid);
        expect_equal(valid, {test_name, " response valid"});
        expect_equal(resp.hit, {test_name, " hit"});
        expect_equal(resp.score === expected_score, {test_name, " score"});
        expect_equal(resp.depth == expected_depth, {test_name, " depth"});
        expect_equal(resp.bound_type == expected_bound, {test_name, " bound"});
        expect_equal(resp.best_move === expected_move, {test_name, " best move"});
    endtask

    task automatic full_expect_lookup_miss(input ZobristKey key, input string test_name);
        automatic TTLookupResponse resp;
        automatic logic valid;

        full_issue_lookup(make_lookup_req(key, PlyIndex'(0)), resp, valid);
        expect_equal(valid, {test_name, " response valid"});
        expect_equal(!resp.hit, {test_name, " miss"});
        expect_equal(resp.bound_type == TT_BOUND_INVALID, {test_name, " invalid bound"});
    endtask

    task automatic store_and_drain(input TTStoreRequest req);
        issue_store(req);
        drain_stores();
    endtask

    task automatic full_store_and_drain(input TTStoreRequest req);
        full_issue_store(req);
        full_drain_stores();
    endtask

    task automatic test_codec_layout();
        automatic Move move = make_move(Position'('d12), Position'('d28), PROMO_ROOK);
        automatic ZobristKey key = make_key(48'h1234_5678_9abc, 16'h0003);
        automatic TTEntry entry = tt_make_entry(key, move, EvalScore'(-123), TTDepth'(17), TT_BOUND_UPPER, TTAge'(8'h5a));
        automatic TTFullEntry full_entry = tt_make_full_entry(key, move, EvalScore'(-321), TTDepth'(18), TT_BOUND_LOWER, TTAge'(8'ha5), TTAux'(16'h55aa));

        expect_equal($bits(TTEntry) == TT_ENTRY_BITS, "TTEntry has declared compact width");
        expect_equal($bits(TTFullEntry) == TT_FULL_ENTRY_BITS, "TTFullEntry has declared full-key width");
        expect_equal(entry.verify_key == 48'h1234_5678_9abc, "entry stores high 48 key bits");
        expect_equal($bits(entry.best_move_bits) == $bits(Move), "entry stores only move bits");
        expect_equal(tt_decode_move(entry.best_move_bits) === move, "entry move round trips");
        expect_equal(entry.score === EvalScore'(-123), "entry stores score field");
        expect_equal(entry.depth == TTDepth'(17), "entry stores depth field");
        expect_equal(entry.bound_type == TT_BOUND_UPPER, "entry stores bound field");
        expect_equal(entry.age == TTAge'(8'h5a), "entry stores age field");
        expect_equal(full_entry.zobrist_key == key, "full entry stores complete key");
        expect_equal(tt_decode_move(full_entry.best_move_bits) === move, "full entry move round trips");
        expect_equal(full_entry.score === EvalScore'(-321), "full entry stores score field");
        expect_equal(full_entry.depth == TTDepth'(18), "full entry stores depth field");
        expect_equal(full_entry.bound_type == TT_BOUND_LOWER, "full entry stores bound field");
        expect_equal(full_entry.age == TTAge'(8'ha5), "full entry stores age field");
        expect_equal(full_entry.aux == TTAux'(16'h55aa), "full entry stores aux field");
    endtask

    task automatic test_empty_miss();
        clear_table();
        expect_lookup_miss(make_key(48'h1111_2222_3333, 16'h0001), "empty table");
    endtask

    task automatic test_store_hit_and_bounds();
        automatic Move move = make_move(Position'('d1), Position'('d18), PROMO_QUEEN);
        automatic TTBoundType bounds[3] = '{TT_BOUND_EXACT, TT_BOUND_LOWER, TT_BOUND_UPPER};

        clear_table();
        for (int idx = 0; idx < 3; idx++) begin
            automatic ZobristKey key = make_key(48'h0100_0000_0000 + TTVerifyKey'(idx), KeySuffix'(idx + 1));
            automatic EvalScore score = EvalScore'(100 + idx);
            automatic TTDepth depth = TTDepth'(6 + idx);

            store_and_drain(make_store_req(key, depth, score, bounds[idx], move, TTAge'(8'h10 + idx), PlyIndex'(0)));
            expect_lookup_hit(key, PlyIndex'(0), score, depth, bounds[idx], move, $sformatf("bound %0d", idx));
        end

        store_and_drain(make_store_req(
            make_key(48'h0100_0000_1000, 16'h0004),
            TTDepth'(5),
            EvalScore'(55),
            TT_BOUND_INVALID,
            move,
            TTAge'(1),
            PlyIndex'(0)
        ));
        expect_lookup_miss(make_key(48'h0100_0000_1000, 16'h0004), "invalid bound store");
    endtask

    task automatic test_verify_key_mismatch();
        automatic Move move = make_move(Position'('d2), Position'('d10), PROMO_KNIGHT);
        automatic ZobristKey key_a = make_key(48'haaaa_0000_0001, 16'h0007);
        automatic ZobristKey key_b = make_key(48'hbbbb_0000_0001, 16'h0007);

        clear_table();
        store_and_drain(make_store_req(key_a, TTDepth'(8), EvalScore'(80), TT_BOUND_EXACT, move, TTAge'(1), PlyIndex'(0)));
        expect_lookup_miss(key_b, "different verify key same index");
        store_and_drain(make_store_req(key_b, TTDepth'(1), EvalScore'(20), TT_BOUND_LOWER, move, TTAge'(1), PlyIndex'(0)));
        expect_lookup_miss(key_a, "old verify key replaced");
        expect_lookup_hit(key_b, PlyIndex'(0), EvalScore'(20), TTDepth'(1), TT_BOUND_LOWER, move, "new verify key replaced old slot");
    endtask

    task automatic test_replacement_policy();
        automatic Move move = make_move(Position'('d3), Position'('d11), PROMO_BISHOP);
        automatic ZobristKey key = make_key(48'hcccc_0000_0001, 16'h0008);

        clear_table();
        store_and_drain(make_store_req(key, TTDepth'(8), EvalScore'(80), TT_BOUND_EXACT, move, TTAge'(1), PlyIndex'(0)));
        store_and_drain(make_store_req(key, TTDepth'(4), EvalScore'(40), TT_BOUND_LOWER, move, TTAge'(2), PlyIndex'(0)));
        expect_lookup_hit(key, PlyIndex'(0), EvalScore'(40), TTDepth'(4), TT_BOUND_LOWER, move, "stale replace within depth window");

        clear_table();
        store_and_drain(make_store_req(key, TTDepth'(8), EvalScore'(80), TT_BOUND_EXACT, move, TTAge'(1), PlyIndex'(0)));
        store_and_drain(make_store_req(key, TTDepth'(3), EvalScore'(30), TT_BOUND_LOWER, move, TTAge'(2), PlyIndex'(0)));
        expect_lookup_hit(key, PlyIndex'(0), EvalScore'(80), TTDepth'(8), TT_BOUND_EXACT, move, "stale too shallow skipped");

        clear_table();
        store_and_drain(make_store_req(key, TTDepth'(4), EvalScore'(40), TT_BOUND_LOWER, move, TTAge'(3), PlyIndex'(0)));
        store_and_drain(make_store_req(key, TTDepth'(5), EvalScore'(50), TT_BOUND_UPPER, move, TTAge'(3), PlyIndex'(0)));
        expect_lookup_hit(key, PlyIndex'(0), EvalScore'(50), TTDepth'(5), TT_BOUND_UPPER, move, "deeper entry replaces old entry");

        clear_table();
        store_and_drain(make_store_req(key, TTDepth'(5), EvalScore'(51), TT_BOUND_LOWER, move, TTAge'(4), PlyIndex'(0)));
        store_and_drain(make_store_req(key, TTDepth'(5), EvalScore'(52), TT_BOUND_EXACT, move, TTAge'(4), PlyIndex'(0)));
        expect_lookup_hit(key, PlyIndex'(0), EvalScore'(52), TTDepth'(5), TT_BOUND_EXACT, move, "exact same-depth entry replaces bound");

        clear_table();
        store_and_drain(make_store_req(key, TTDepth'(8), EvalScore'(80), TT_BOUND_EXACT, move, TTAge'(5), PlyIndex'(0)));
        store_and_drain(make_store_req(key, TTDepth'(7), EvalScore'(70), TT_BOUND_LOWER, move, TTAge'(5), PlyIndex'(0)));
        expect_lookup_hit(key, PlyIndex'(0), EvalScore'(80), TTDepth'(8), TT_BOUND_EXACT, move, "current deeper exact entry keeps slot");
    endtask

    task automatic test_arbitration_and_backpressure();
        automatic Move move = make_move(Position'('d4), Position'('d12), PROMO_QUEEN);
        automatic ZobristKey key = make_key(48'hdddd_0000_0001, 16'h0009);
        automatic TTLookupResponse resp;
        automatic logic valid;

        clear_table();
        store_and_drain(make_store_req(key, TTDepth'(5), EvalScore'(100), TT_BOUND_EXACT, move, TTAge'(1), PlyIndex'(0)));
        issue_store(make_store_req(key, TTDepth'(6), EvalScore'(200), TT_BOUND_EXACT, move, TTAge'(1), PlyIndex'(0)));
        issue_lookup(make_lookup_req(key, PlyIndex'(0)), resp, valid);
        expect_equal(valid && resp.hit && resp.score === EvalScore'(100), "lookup wins over pending same-index store");
        drain_stores();
        expect_lookup_hit(key, PlyIndex'(0), EvalScore'(200), TTDepth'(6), TT_BOUND_EXACT, move, "pending store drains after lookup gap");

        clear_table();
        for (int idx = 0; idx < TEST_STORE_FIFO_DEPTH; idx++) begin
            automatic ZobristKey fifo_key = make_key(48'heeee_0000_0000 + TTVerifyKey'(idx), KeySuffix'(idx));
            expect_equal(store_req_ready, $sformatf("store FIFO ready before entry %0d", idx));
            lookup_req = make_lookup_req(make_key(48'heeee_1111_0000 + TTVerifyKey'(idx), KeySuffix'(idx)), PlyIndex'(0));
            lookup_req_valid = 1'b1;
            store_req = make_store_req(fifo_key, TTDepth'(idx + 1), EvalScore'(idx + 1), TT_BOUND_EXACT, move, TTAge'(1), PlyIndex'(0));
            store_req_valid = 1'b1;
            do_clock(1);
        end
        expect_equal(store_req_ready, "store FIFO consumes publication when full");
        store_req = make_store_req(make_key(48'heeee_ffff_0000, 16'h00ff),
            TTDepth'(9), EvalScore'(99), TT_BOUND_EXACT, move, TTAge'(1), PlyIndex'(0));
        do_clock(1);
        lookup_req_valid = 1'b0;
        lookup_req = TTLookupRequest'('0);
        store_req_valid = 1'b0;
        store_req = TTStoreRequest'('0);
        drain_stores(12);
        expect_equal(store_req_ready, "store FIFO ready after drain");
        expect_lookup_hit(make_key(48'heeee_0000_0003, 16'h0003), PlyIndex'(0), EvalScore'(4), TTDepth'(4), TT_BOUND_EXACT, move, "FIFO stores eventually drain");
        expect_lookup_miss(make_key(48'heeee_ffff_0000, 16'h00ff), "overflow store was safely dropped");
    endtask

    task automatic test_mate_scores();
        automatic Move move = make_move(Position'('d5), Position'('d13), PROMO_QUEEN);
        automatic ZobristKey win_key = make_key(48'hf001_0000_0001, 16'h000a);
        automatic ZobristKey loss_key = make_key(48'hf002_0000_0001, 16'h000b);
        automatic ZobristKey normal_key = make_key(48'hf003_0000_0001, 16'h000c);

        clear_table();
        store_and_drain(make_store_req(win_key, TTDepth'(9), EvalScore'(MATE_SCORE - 3), TT_BOUND_EXACT, move, TTAge'(1), PlyIndex'(3)));
        expect_lookup_hit(win_key, PlyIndex'(5), EvalScore'(MATE_SCORE - 5), TTDepth'(9), TT_BOUND_EXACT, move, "winning mate score restored by lookup ply");

        store_and_drain(make_store_req(loss_key, TTDepth'(9), EvalScore'(-MATE_SCORE + 4), TT_BOUND_EXACT, move, TTAge'(1), PlyIndex'(4)));
        expect_lookup_hit(loss_key, PlyIndex'(6), EvalScore'(-MATE_SCORE + 6), TTDepth'(9), TT_BOUND_EXACT, move, "losing mate score restored by lookup ply");

        store_and_drain(make_store_req(normal_key, TTDepth'(9), EvalScore'(1234), TT_BOUND_EXACT, move, TTAge'(1), PlyIndex'(7)));
        expect_lookup_hit(normal_key, PlyIndex'(9), EvalScore'(1234), TTDepth'(9), TT_BOUND_EXACT, move, "non-mate score unchanged by ply");
    endtask

    task automatic test_clear_behavior();
        automatic Move move = make_move(Position'('d6), Position'('d14), PROMO_ROOK);
        automatic ZobristKey key = make_key(48'hf100_0000_0001, 16'h000d);

        clear_table();
        store_and_drain(make_store_req(key, TTDepth'(4), EvalScore'(44), TT_BOUND_EXACT, move, TTAge'(1), PlyIndex'(0)));
        expect_lookup_hit(key, PlyIndex'(0), EvalScore'(44), TTDepth'(4), TT_BOUND_EXACT, move, "entry exists before clear");
        clear_table_held_high();
        expect_lookup_miss(key, "entry cleared");
        store_and_drain(make_store_req(key, TTDepth'(5), EvalScore'(55), TT_BOUND_LOWER, move, TTAge'(2), PlyIndex'(0)));
        expect_lookup_hit(key, PlyIndex'(0), EvalScore'(55), TTDepth'(5), TT_BOUND_LOWER, move, "new store works after clear");
    endtask

    task automatic test_full_key_profile();
        automatic Move move_a = make_move(Position'('d7), Position'('d15), PROMO_QUEEN);
        automatic Move move_b = make_move(Position'('d8), Position'('d16), PROMO_ROOK);
        automatic ZobristKey key_a = 64'h1234_5678_9abc_0011;
        automatic ZobristKey key_b = 64'h1234_5678_9abc_1011;
        automatic ZobristKey key_c = 64'h1234_5678_9abc_2011;

        full_clear_table();
        full_store_and_drain(make_store_req(key_a, TTDepth'(7), EvalScore'(77), TT_BOUND_EXACT, move_a, TTAge'(3), PlyIndex'(0)));
        full_expect_lookup_hit(key_a, PlyIndex'(0), EvalScore'(77), TTDepth'(7), TT_BOUND_EXACT, move_a, "full-key stored entry");
        full_expect_lookup_miss(key_b, "full-key distinguishes middle hash bits");
        full_store_and_drain(make_store_req(key_b, TTDepth'(8), EvalScore'(88), TT_BOUND_LOWER, move_b, TTAge'(3), PlyIndex'(0)));
        full_expect_lookup_miss(key_a, "full-key same-index replacement removes old full key");
        full_expect_lookup_hit(key_b, PlyIndex'(0), EvalScore'(88), TTDepth'(8), TT_BOUND_LOWER, move_b, "full-key replacement hit");
        full_expect_lookup_miss(key_c, "full-key miss on third same-index key");
    endtask

    initial begin
        $display("=== TT load/store testbench ===");
        reset_dut();
        test_codec_layout();
        test_empty_miss();
        test_store_hit_and_bounds();
        test_verify_key_mismatch();
        test_replacement_policy();
        test_arbitration_and_backpressure();
        test_mate_scores();
        test_clear_behavior();
        test_full_key_profile();

        $display("Pass Count: %0d", pass_count);
        $display("Fail Count: %0d", error_count);

        if (error_count == 0) begin
            $display("TT load/store testbench passed");
        end else begin
            $fatal(1, "TT load/store testbench failed");
        end

        $finish;
    end

endmodule : tb_tt_load_store
