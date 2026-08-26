`timescale 1ns/1ns

import chess_defs::*;
import board_update_pipeline_defs::*;
import engine_defs::*;
import nnue_defs::*;
import tt_defs::*;

module tb_search_controller;

    // Acceptance testing intentionally uses the DE1 one-thread configuration.
    localparam int THREAD_COUNT = 1;
    localparam int SEARCH_STACK_DEPTH = 24;

    logic clk;
    logic rst_n;
    logic req_valid;
    logic req_ready;
    EngineControllerRequest req;
    EngineControllerRequest clock_budget_request;
    logic resp_valid;
    EngineControllerResponse resp;
    logic [7:0] debug_stat_address;
    logic [39:0] debug_stat_value;
    logic stats_reset_pending;
    logic [39:0] last_move_generation_cycles;
    logic [39:0] last_move_destination_count;
    logic [39:0] last_move_candidate_count;

    int pass_count = 0;
    int fail_count = 0;
    int tt_lookup_count = 0;
    int tt_store_count = 0;
    int tt_validation_repetition_count = 0;
    int tt_validation_pass_count = 0;
    int tt_validation_repeat_reject_count = 0;
    int tt_validation_nonpositive_reject_count = 0;
    int tt_validation_illegal_reject_count = 0;
    bit tt_thread_seen[0:THREAD_COUNT-1];
    bit tt_response_thread_seen[0:THREAD_COUNT-1];
    bit root_push_seen[0:THREAD_COUNT-1];
    bit root_stack_seen[0:THREAD_COUNT-1];
    bit root_stack_capture_pending[0:THREAD_COUNT-1];
    bit repetition_root_request_seen;
    bit repetition_child_request_seen;
    bit all_threads_root_active_seen;
    bit search_dispatch_state_seen;
    bit active_thread_count_full_seen;
    bit active_thread_count_decrement_seen;
    bit store_wait_dispatch_seen;
    bit store_wait_issue_seen;
    bit return_pending_dispatch_seen;
    bit tt_response_pending_dispatch_seen;
    bit multi_move_inflight_seen;
    bit pipeline_overlap_seen;
    bit pvs_scout_seen;
    bit pvs_research_seen;
    bit aspiration_window_seen;
    bit lmr_reduced_issue_seen;
    bit lmr_illegal_candidate_seen;
    bit lmr_recovery_issue_seen;
    bit lmr_reduced_tt_depth_seen;
    bit lmr_full_tt_depth_seen;
    bit stats_reset_correct = 1'b1;
    bit tt_lookup_depth_correct = 1'b1;
    bit tt_store_depth_correct = 1'b1;
    bit null_push_seen;
    bit null_reverse_seen;
    bit nnue_delta_seen;
    bit nnue_rebuild_seen;
    bit nnue_pending_state_invalid = 1'b1;
    bit nnue_root_initialization_seen;
    bit nnue_root_initialization_correct = 1'b1;
    bit nnue_king_delta_seen;
    bit nnue_king_delta_correct = 1'b1;
    bit nnue_castle_delta_seen;
    bit nnue_castle_request_count_correct = 1'b1;
    bit nnue_castle_state_seen;
    bit nnue_en_passant_state_seen;
    bit nnue_promotion_state_seen;
    bit nnue_special_state_correct = 1'b1;
    bit nnue_reverse_delta_seen;
    bit nnue_recovery_rebuild_seen;
    bit nnue_null_state_seen;
    bit nnue_null_state_correct = 1'b1;
    int nnue_root_rebuild_count[0:THREAD_COUNT-1];
    int nnue_castle_request_count[0:THREAD_COUNT-1];
    bit lmr_depth_check_pending[0:THREAD_COUNT-1];
    bit lmr_recovery_check_pending[0:THREAD_COUNT-1];
    bit lmr_full_tt_pending[0:THREAD_COUNT-1];
    logic [7:0] lmr_expected_child_depth[0:THREAD_COUNT-1];
    logic [7:0] lmr_issue_legal_count[0:THREAD_COUNT-1];
    bit shallow_tt_hit_seen;
    bit shallow_tt_target_seen;
    bit shallow_tt_target_pending[0:THREAD_COUNT-1];
    Move shallow_tt_target_move[0:THREAD_COUNT-1];
    bit thread_selected_active_seen[0:THREAD_COUNT-1];
    bit thread_rr_cursor_seen[0:THREAD_COUNT-1];
    bit thread_board_cursor_seen[0:THREAD_COUNT-1];
    bit thread_move_cursor_seen[0:THREAD_COUNT-1];
    bit thread_eval_cursor_seen[0:THREAD_COUNT-1];
    bit thread_tt_lookup_cursor_seen[0:THREAD_COUNT-1];
    bit thread_tt_store_cursor_seen[0:THREAD_COUNT-1];
    bit thread_tt_response_cursor_seen[0:THREAD_COUNT-1];
    bit thread_return_cursor_seen[0:THREAD_COUNT-1];
    bit thread_ready_phase_seen[0:THREAD_COUNT-1];
    bit thread_move_phase_seen[0:THREAD_COUNT-1];
    bit thread_board_phase_seen[0:THREAD_COUNT-1];
    bit thread_eval_phase_seen[0:THREAD_COUNT-1];
    bit thread_store_phase_seen[0:THREAD_COUNT-1];
    bit thread_board_inflight_seen[0:THREAD_COUNT-1];
    bit thread_move_inflight_seen[0:THREAD_COUNT-1];
    bit thread_eval_inflight_seen[0:THREAD_COUNT-1];
    bit thread_tt_lookup_inflight_seen[0:THREAD_COUNT-1];
    bit thread_tt_store_inflight_seen[0:THREAD_COUNT-1];
    bit thread_board_wait_seen[0:THREAD_COUNT-1];
    bit thread_move_wait_seen[0:THREAD_COUNT-1];
    bit thread_eval_wait_seen[0:THREAD_COUNT-1];
    bit thread_board_tag_seen[0:THREAD_COUNT-1];
    bit thread_move_tag_seen[0:THREAD_COUNT-1];
    bit thread_eval_tag_seen[0:THREAD_COUNT-1];
    bit thread_move_handoff_seen[0:THREAD_COUNT-1];
    bit thread_eval_handoff_seen[0:THREAD_COUNT-1];
    Move root_first_move[0:THREAD_COUNT-1];
    Move root_first_stack_move[0:THREAD_COUNT-1];

    search_controller #(
        .CLOCK_FREQ(1_000_000),
        .TT_INDEX_BITS(4),
        .SEARCH_THREAD_COUNT(THREAD_COUNT),
        .SEARCH_STACK_DEPTH(SEARCH_STACK_DEPTH),
        .ENABLE_SEARCH_STATS(1'b1)
    ) dut (
        .clk(clk),
        .rst_n(rst_n),
        .req_valid(req_valid),
        .req_ready(req_ready),
        .req(req),
        .resp_valid(resp_valid),
        .resp(resp),
        .debug_stat_address(debug_stat_address),
        .debug_stat_value(debug_stat_value)
    );

    task automatic do_clock(input int count = 1);
        for (int idx = 0; idx < count; idx++) begin
            clk = 1'b0; #5;
            clk = 1'b1; #5;
        end
    endtask : do_clock

    task automatic check(input logic condition, input string label);
        if (condition) begin
            pass_count += 1;
        end else begin
            fail_count += 1;
            $error("[FAIL] %s", label);
        end
    endtask : check

    // Rebuild the two-perspective accumulator directly from a board so special
    // move deltas can be checked against their complete positional state.
    function automatic logic [
        NNUE_STATE_VALUE_COUNT * NNUE_ACCUMULATOR_BITS-1:0]
        reference_nnue_state(input FullBoard board);
        automatic logic [
            NNUE_STATE_VALUE_COUNT * NNUE_ACCUMULATOR_BITS-1:0] expected = '0;

        for (int perspective = 0; perspective < 2; perspective++) begin
            for (int lane = 0; lane < NNUE_ACCUMULATOR_COUNT; lane++) begin
                automatic NnueAccumulator sum = NnueAccumulator'($signed(
                    dut.nnue_evaluator.accumulator_bias[lane][
                        NNUE_ACCUMULATOR_BIAS_BITS-1:0]));
                for (int pos = 0; pos < 64; pos++) begin
                    automatic Tile tile = board.tiles[pos];
                    if (tile.piece_type != NULL_PIECE) begin
                        automatic NnueFeatureIndex feature = nnue_feature_index(
                            Position'(pos), tile, Color'(perspective));
                        automatic logic signed [NNUE_FEATURE_WEIGHT_BITS-1:0]
                            feature_weight =
                            $signed(dut.nnue_evaluator.feature_rom[feature][
                                lane * NNUE_FEATURE_WEIGHT_BITS
                                    +: NNUE_FEATURE_WEIGHT_BITS]);
                        sum = NnueAccumulator'(
                            sum + NnueAccumulator'(feature_weight));
                    end
                end
                expected[(perspective * NNUE_ACCUMULATOR_COUNT + lane)
                        * NNUE_ACCUMULATOR_BITS +: NNUE_ACCUMULATOR_BITS] = sum;
            end
        end
        return expected;
    endfunction : reference_nnue_state

    function automatic EngineControllerRequest zero_request();
        automatic EngineControllerRequest request;

        request = EngineControllerRequest'('0);
        request.operation = ENGINE_CTRL_IDLE;
        request.board_op = BOARD_IDLE_OP;
        return request;
    endfunction : zero_request

    function automatic Move make_move(input Position from_pos, input Position to_pos, input PromoType promo);
        automatic Move move;

        move.from_pos = from_pos;
        move.to_pos = to_pos;
        move.promo_piece = promo;
        return move;
    endfunction : make_move

    function automatic logic is_null_move(input Move move);
        return move.from_pos == Position'(0) && move.to_pos == Position'(0);
    endfunction : is_null_move

    function automatic ThreadID expected_next_thread(input int thread_idx);
        return (thread_idx >= THREAD_COUNT - 1) ? ThreadID'(0) : ThreadID'(thread_idx + 1);
    endfunction : expected_next_thread

    task automatic reset_dut();
        req_valid = 1'b0;
        req = zero_request();
        rst_n = 1'b0;
        do_clock(3);
        rst_n = 1'b1;
        do_clock(2);
        check(req_ready, "controller ready after reset");
        check(!resp_valid, "no response valid after reset");
    endtask : reset_dut

    task automatic check_search_stats(input string label);
        automatic logic [39:0] phase_total;

        debug_stat_address = ENGINE_STAT_ENABLED;
        #1;
        check(debug_stat_value == 40'd1, {label, " enabled"});
        debug_stat_address = ENGINE_STAT_THREAD_COUNT;
        #1;
        check(debug_stat_value == 40'(THREAD_COUNT), {label, " thread count"});
        debug_stat_address = ENGINE_STAT_PHASE_COUNT;
        #1;
        check(debug_stat_value == 40'(ENGINE_STAT_PHASE_COUNT_VALUE), {label, " phase count"});
        debug_stat_address = ENGINE_STAT_TT_LOOKUPS;
        #1;
        check(debug_stat_value != 40'd0, {label, " recorded TT lookups"});
        for (int tid = 0; tid < THREAD_COUNT; tid++) begin
            phase_total = 40'd0;
            for (int phase = 0; phase < ENGINE_STAT_PHASE_COUNT_VALUE; phase++) begin
                debug_stat_address = ENGINE_STAT_PHASE_BASE
                    + 8'(tid * ENGINE_STAT_PHASE_COUNT_VALUE + phase);
                #1;
                phase_total += debug_stat_value;
            end
            check(phase_total == dut.stat_search_cycle,
                $sformatf("%s thread %0d phase total matches search cycles", label, tid));
        end
        $display("Search cycle profile %s: nodes=%0d total=%0d ready=%0d tt=%0d eval=%0d move=%0d board=%0d reverse=%0d repetition=%0d store=%0d terminal=%0d done=%0d",
            label, resp.nodes_count, dut.stat_search_cycle,
            dut.stat_phase_cycles[0][0], dut.stat_phase_cycles[0][1],
            dut.stat_phase_cycles[0][2], dut.stat_phase_cycles[0][3],
            dut.stat_phase_cycles[0][4], dut.stat_phase_cycles[0][5],
            dut.stat_phase_cycles[0][6], dut.stat_phase_cycles[0][7],
            dut.stat_phase_cycles[0][8], dut.stat_phase_cycles[0][9]);
    endtask : check_search_stats

    task automatic hold_request_until_ready(input EngineControllerRequest request, input string label);
        automatic int wait_cycles = 0;

        req = request;
        req_valid = 1'b1;
        while (!req_ready && wait_cycles < 5000) begin
            do_clock(1);
            wait_cycles += 1;
        end
        check(req_ready, {label, " accepted"});
        do_clock(1);
        req_valid = 1'b0;
        req = zero_request();
        wait_response(label);
    endtask : hold_request_until_ready

    task automatic pulse_request(input EngineControllerRequest request, input string label);
        req = request;
        req_valid = 1'b1;
        #1;
        check(req_ready, {label, " accepted"});
        do_clock(1);
        req_valid = 1'b0;
        req = zero_request();
    endtask : pulse_request

    task automatic wait_response(input string label);
        automatic int wait_cycles = 0;

        while (!resp_valid && wait_cycles < 200000) begin
            do_clock(1);
            wait_cycles += 1;
        end
        check(resp_valid, {label, " response valid"});
        do_clock(1);
    endtask : wait_response

    task automatic new_game();
        automatic EngineControllerRequest request = zero_request();
        automatic logic nnue_metadata_clear = 1'b1;

        request.operation = ENGINE_CTRL_NEW_GAME;
        hold_request_until_ready(request, "new game");
        check(!resp.error, "new game response has no error");
        for (int tid = 0; tid < THREAD_COUNT; tid++) begin
            nnue_metadata_clear &= !dut.nnue_plan_pending[tid];
            nnue_metadata_clear &= !dut.nnue_state_valid[tid];
        end
        check(nnue_metadata_clear, "new game invalidates queued NNUE plans and accumulator states");
        check(dut.nnue_update_idle && dut.nnue_eval_ready,
            "new game leaves the NNUE datapath idle and ready");
    endtask : new_game

    task automatic apply_game_move(input Move move, input string label);
        automatic EngineControllerRequest request = zero_request();

        request.operation = ENGINE_CTRL_BOARD_UPDATE;
        request.board_op = BOARD_COMMIT_MOVE_OP;
        request.move = move;
        hold_request_until_ready(request, label);
        check(!resp.error, {label, " response has no error"});
    endtask : apply_game_move

    task automatic run_perft(input logic [7:0] depth, input NodeCountType expected_nodes, input string label);
        automatic EngineControllerRequest request = zero_request();
        automatic time start_time = $time;

        request.operation = ENGINE_CTRL_PERFT;
        request.depth_limit = depth;
        pulse_request(request, label);
        wait_response(label);
        check(!resp.error, {label, " no error"});
        check(resp.nodes_count == expected_nodes,
            $sformatf("%s expected nodes=%0d found=%0d", label, expected_nodes, resp.nodes_count));
        check(resp.completed_depth == depth, {label, " completed depth"});
        check(resp.end_reason == ENGINE_END_DEPTH_LIMIT, {label, " end reason"});
        $display("Perft cycle profile %s: nodes=%0d cycles=%0d",
            label, resp.nodes_count, ($time - start_time) / 10);
    endtask : run_perft

    task automatic run_search_depth(input logic [7:0] depth, input string label);
        automatic EngineControllerRequest request = zero_request();
        automatic logic [39:0] generation_cycles_before;
        automatic logic [39:0] destinations_before;
        automatic logic [39:0] candidates_before;

        repetition_root_request_seen = 1'b0;
        repetition_child_request_seen = 1'b0;
        generation_cycles_before = dut.move_stat_generation_cycles;
        destinations_before = dut.move_stat_destination_count;
        candidates_before = dut.move_stat_candidate_count;
        request.operation = ENGINE_CTRL_SEARCH_DEPTH;
        request.depth_limit = depth;
        pulse_request(request, label);
        wait_response(label);
        check(!resp.error, {label, " no error"});
        check(resp.nodes_count != NodeCountType'(0), {label, " searches below root"});
        check(resp.completed_depth == depth, {label, " completed requested depth"});
        check(resp.end_reason == ENGINE_END_DEPTH_LIMIT, {label, " end reason"});
        check(!(resp.best_move.from_pos == Position'(0) && resp.best_move.to_pos == Position'(0)), {label, " best move is non-null"});
        if (depth >= 8'd2)
            check(!is_null_move(resp.ponder_move), {label, " ponder move is non-null"});
        check(repetition_root_request_seen, {label, " checks root repetition"});
        check(repetition_child_request_seen, {label, " checks legal child repetition"});
        last_move_generation_cycles =
            dut.move_stat_generation_cycles - generation_cycles_before;
        last_move_destination_count =
            dut.move_stat_destination_count - destinations_before;
        last_move_candidate_count =
            dut.move_stat_candidate_count - candidates_before;
        $display("Move generation profile %s: active_cycles=%0d destinations=%0d candidates=%0d",
            label, last_move_generation_cycles,
            last_move_destination_count, last_move_candidate_count);
    endtask : run_search_depth

    task automatic run_search_depth_record(
        input logic [7:0] depth,
        input string label,
        output Move best_move,
        output EvalScore score,
        output NodeCountType nodes
    );
        automatic EngineControllerRequest request = zero_request();

        request.operation = ENGINE_CTRL_SEARCH_DEPTH;
        request.depth_limit = depth;
        pulse_request(request, label);
        wait_response(label);
        check(!resp.error, {label, " no error"});
        check(resp.completed_depth == depth, {label, " completed requested depth"});
        check(resp.end_reason == ENGINE_END_DEPTH_LIMIT, {label, " end reason"});
        best_move = resp.best_move;
        score = resp.score;
        nodes = resp.nodes_count;
    endtask : run_search_depth_record

    task automatic run_tt_reuse_test(input string label);
        automatic Move first_move;
        automatic Move second_move;
        automatic EvalScore first_score;
        automatic EvalScore second_score;
        automatic NodeCountType first_nodes;
        automatic NodeCountType second_nodes;
        automatic int first_lookup_count;
        automatic int first_store_count;

        tt_lookup_count = 0;
        tt_store_count = 0;
        run_search_depth_record(8'd1, {label, " first search"}, first_move, first_score, first_nodes);
        first_lookup_count = tt_lookup_count;
        first_store_count = tt_store_count;
        check(first_lookup_count > 0, {label, " first search issued TT lookups"});
        check(first_store_count > 0, {label, " first search issued TT stores"});
        check(first_nodes >= NodeCountType'(20),
            {label, " first search visited every legal root child"});

        tt_lookup_count = 0;
        tt_store_count = 0;
        run_search_depth_record(8'd1, {label, " second search"}, second_move, second_score, second_nodes);
        check(tt_lookup_count > 0, {label, " second search issued TT lookup"});
        check(tt_lookup_count >= first_lookup_count, {label, " second search issued repeated TT lookups"});
        check(second_nodes < first_nodes, {label, " second search searched fewer nodes"});
        check(second_score == first_score, {label, " second search same score"});
        check(second_move == first_move, {label, " second search same best move"});
    endtask : run_tt_reuse_test

    // Install a controlled exact root entry without paying to search its depth.
    task automatic preload_root_tt(
        input Move best_move,
        input EvalScore score,
        input TTDepth depth
    );
        automatic int index = int'(
            dut.internal_tt_gen.tt_load_store.tt_index(dut.active_zobrist_key));
        dut.internal_tt_gen.tt_load_store.entry_memory.mem[index] = tt_make_entry(
            dut.active_zobrist_key,
            best_move,
            score,
            depth,
            TT_BOUND_EXACT,
            dut.tt_age
        );
    endtask : preload_root_tt

    task automatic kill_running_search(input string label);
        automatic EngineControllerRequest kill_request = zero_request();

        kill_request.operation = ENGINE_CTRL_KILL;
        req = kill_request;
        req_valid = 1'b1;
        #1;
        check(req_ready, {label, " kill accepted"});
        do_clock(1);
        req_valid = 1'b0;
        req = zero_request();
        wait_response(label);
        check(!resp.error, {label, " kill no error"});
        check(resp.end_reason == ENGINE_END_KILLED, {label, " killed end reason"});
    endtask : kill_running_search

    task automatic start_search_depth(input logic [7:0] depth, input string label);
        automatic EngineControllerRequest request = zero_request();
        request.operation = ENGINE_CTRL_SEARCH_DEPTH;
        request.depth_limit = depth;
        pulse_request(request, label);
    endtask : start_search_depth

    task automatic wait_for_counter(
        ref int counter,
        input int previous_value,
        input string label
    );
        automatic int cycles = 0;
        while (counter == previous_value && cycles < 20_000) begin
            do_clock(1);
            cycles += 1;
        end
        check(counter > previous_value, label);
    endtask : wait_for_counter

    // Depth and halfmove thresholds retain cheap TT reuse, while a deep entry
    // with meaningful reversible history validates its legal non-drawing child.
    task automatic run_tt_child_validation_policy_test(input string label);
        automatic Move cached_move = make_move(Position'(12), Position'(28), PROMO_QUEEN);
        automatic Move best_move;
        automatic EvalScore score;
        automatic NodeCountType nodes;
        automatic int validations_before;
        automatic int passes_before;

        new_game();
        set_halfmove_clock(HalfmoveClock'(5), {label, " shallow halfmove"});
        preload_root_tt(cached_move, EvalScore'(600), TTDepth'(9));
        validations_before = tt_validation_repetition_count;
        run_search_depth_record(8'd7, {label, " shallow depth bypass"},
            best_move, score, nodes);
        check(nodes == NodeCountType'(0), {label, " shallow depth accepts TT score"});
        check(best_move == cached_move, {label, " shallow depth returns TT move"});
        check(tt_validation_repetition_count == validations_before,
            {label, " shallow depth skips child validation"});

        new_game();
        set_halfmove_clock(HalfmoveClock'(4), {label, " low halfmove"});
        dut.search_board[0].halfmove_clock = HalfmoveClock'(4);
        dut.search_tt_validation_forced[0] = 1'b1;
        #1;
        check(!dut.tt_history_validation_required(ThreadID'(0)),
            {label, " low halfmove bypass survives forced depth validation"});
        dut.search_tt_validation_forced[0] = 1'b0;
        preload_root_tt(cached_move, EvalScore'(600), TTDepth'(9));
        validations_before = tt_validation_repetition_count;
        run_search_depth_record(8'd8, {label, " low halfmove bypass"},
            best_move, score, nodes);
        check(nodes == NodeCountType'(0), {label, " low halfmove accepts TT score"});
        check(best_move == cached_move, {label, " low halfmove returns TT move"});
        check(tt_validation_repetition_count == validations_before,
            {label, " low halfmove skips child validation"});

        new_game();
        set_halfmove_clock(HalfmoveClock'(5), {label, " deep halfmove"});
        preload_root_tt(cached_move, EvalScore'(600), TTDepth'(9));
        validations_before = tt_validation_repetition_count;
        passes_before = tt_validation_pass_count;
        run_search_depth_record(8'd8, {label, " deep legal child"},
            best_move, score, nodes);
        check(nodes == NodeCountType'(0), {label, " validation avoids child search"});
        check(best_move == cached_move, {label, " validated TT move returned"});
        check(score == EvalScore'(600), {label, " validated TT score returned"});
        check(tt_validation_repetition_count == validations_before + 1,
            {label, " deep hit checks child repetition"});
        check(tt_validation_pass_count == passes_before + 1,
            {label, " legal non-draw child accepts TT score"});
    endtask : run_tt_child_validation_policy_test

    // Build C-R-C-R so the cached R->C move enters C for the third time.
    task automatic run_tt_immediate_draw_rejection_test(input string label);
        automatic Move white_out = make_move(Position'(6), Position'(21), PROMO_QUEEN);
        automatic Move black_out = make_move(Position'(62), Position'(45), PROMO_QUEEN);
        automatic Move white_back = make_move(Position'(21), Position'(6), PROMO_QUEEN);
        automatic Move black_back = make_move(Position'(45), Position'(62), PROMO_QUEEN);
        automatic int rejects_before;

        new_game();
        apply_game_move(white_out, {label, " establish C"});
        set_halfmove_clock(HalfmoveClock'(5), {label, " reset history at C"});
        apply_game_move(black_out, {label, " first black out"});
        apply_game_move(white_back, {label, " first white back"});
        apply_game_move(black_back, {label, " establish R"});
        apply_game_move(white_out, {label, " second C"});
        apply_game_move(black_out, {label, " second black out"});
        apply_game_move(white_back, {label, " second white back"});
        apply_game_move(black_back, {label, " second R"});
        preload_root_tt(white_out, EvalScore'(600), TTDepth'(9));
        rejects_before = tt_validation_repeat_reject_count;
        start_search_depth(8'd8, {label, " search"});
        wait_for_counter(tt_validation_repeat_reject_count, rejects_before,
            {label, " rejects immediate threefold TT score"});
        do_clock(1);
        check(dut.search_tt_validation_forced[0],
            {label, " forces validation below depth threshold"});
        kill_running_search({label, " stop after rejection"});
    endtask : run_tt_immediate_draw_rejection_test

    // The stored move need not draw immediately: entering any previously seen
    // child can put a forced reply one step away from the terminal occurrence.
    task automatic run_tt_repeated_child_rejection_test(input string label);
        automatic Move white_out = make_move(Position'(6), Position'(21), PROMO_QUEEN);
        automatic Move black_out = make_move(Position'(62), Position'(45), PROMO_QUEEN);
        automatic Move white_back = make_move(Position'(21), Position'(6), PROMO_QUEEN);
        automatic Move black_back = make_move(Position'(45), Position'(62), PROMO_QUEEN);
        automatic int rejects_before;

        new_game();
        apply_game_move(white_out, {label, " establish I"});
        apply_game_move(black_out, {label, " establish B"});
        set_halfmove_clock(HalfmoveClock'(5), {label, " reset history at B"});
        apply_game_move(white_back, {label, " first white back"});
        apply_game_move(black_back, {label, " establish R"});
        apply_game_move(white_out, {label, " first I"});
        apply_game_move(black_out, {label, " second B"});
        apply_game_move(white_back, {label, " second white back"});
        apply_game_move(black_back, {label, " second R"});
        preload_root_tt(white_out, EvalScore'(600), TTDepth'(9));
        rejects_before = tt_validation_repeat_reject_count;
        start_search_depth(8'd8, {label, " search"});
        wait_for_counter(tt_validation_repeat_reject_count, rejects_before,
            {label, " rejects nonterminal repeated child TT score"});
        do_clock(1);
        check(dut.search_tt_validation_forced[0],
            {label, " forces validation below depth threshold"});
        kill_running_search({label, " stop after rejection"});
    endtask : run_tt_repeated_child_rejection_test

    task automatic run_tt_nonpositive_score_rejection_test(input string label);
        automatic Move cached_move = make_move(Position'(12), Position'(28), PROMO_QUEEN);
        automatic int rejects_before;

        new_game();
        set_halfmove_clock(HalfmoveClock'(5), {label, " halfmove"});
        preload_root_tt(cached_move, EvalScore'(-600), TTDepth'(9));
        rejects_before = tt_validation_nonpositive_reject_count;
        start_search_depth(8'd8, {label, " search"});
        wait_for_counter(tt_validation_nonpositive_reject_count, rejects_before,
            {label, " rejects non-positive deep TT score"});
        kill_running_search({label, " stop after rejection"});
    endtask : run_tt_nonpositive_score_rejection_test

    task automatic run_tt_illegal_move_rejection_test(input string label);
        automatic Move illegal_move = make_move(Position'(12), Position'(36), PROMO_QUEEN);
        automatic int rejects_before;

        new_game();
        set_halfmove_clock(HalfmoveClock'(5), {label, " halfmove"});
        preload_root_tt(illegal_move, EvalScore'(600), TTDepth'(9));
        rejects_before = tt_validation_illegal_reject_count;
        start_search_depth(8'd8, {label, " search"});
        wait_for_counter(tt_validation_illegal_reject_count, rejects_before,
            {label, " rejects illegal TT move"});
        kill_running_search({label, " stop after rejection"});
    endtask : run_tt_illegal_move_rejection_test

    task automatic run_shallow_tt_move_ordering_test(input string label);
        automatic Move best_move;
        automatic EvalScore score;
        automatic NodeCountType nodes;

        shallow_tt_hit_seen = 1'b0;
        shallow_tt_target_seen = 1'b0;
        for (int idx = 0; idx < THREAD_COUNT; idx++) begin
            shallow_tt_target_pending[idx] = 1'b0;
            shallow_tt_target_move[idx] = NULL_MOVE;
        end
        run_search_depth_record(8'd2, label, best_move, score, nodes);
        check(shallow_tt_hit_seen, {label, " received a TT hit too shallow for cutoff use"});
        check(shallow_tt_target_seen, {label, " reused shallow TT best move in targeted generation"});
    endtask : run_shallow_tt_move_ordering_test

    task automatic clear_tt_thread_seen();
        for (int idx = 0; idx < THREAD_COUNT; idx++) begin
            tt_thread_seen[idx] = 1'b0;
            tt_response_thread_seen[idx] = 1'b0;
        end
    endtask : clear_tt_thread_seen

    task automatic clear_root_push_seen();
        all_threads_root_active_seen = 1'b0;
        search_dispatch_state_seen = 1'b0;
        active_thread_count_full_seen = 1'b0;
        active_thread_count_decrement_seen = 1'b0;
        store_wait_dispatch_seen = 1'b0;
        store_wait_issue_seen = 1'b0;
        return_pending_dispatch_seen = 1'b0;
        tt_response_pending_dispatch_seen = 1'b0;
        multi_move_inflight_seen = 1'b0;
        pipeline_overlap_seen = 1'b0;
        for (int idx = 0; idx < THREAD_COUNT; idx++) begin
            root_push_seen[idx] = 1'b0;
            root_stack_seen[idx] = 1'b0;
            root_stack_capture_pending[idx] = 1'b0;
            thread_selected_active_seen[idx] = 1'b0;
            thread_rr_cursor_seen[idx] = 1'b0;
            thread_board_cursor_seen[idx] = 1'b0;
            thread_move_cursor_seen[idx] = 1'b0;
            thread_eval_cursor_seen[idx] = 1'b0;
            thread_tt_lookup_cursor_seen[idx] = 1'b0;
            thread_tt_store_cursor_seen[idx] = 1'b0;
            thread_tt_response_cursor_seen[idx] = 1'b0;
            thread_return_cursor_seen[idx] = 1'b0;
            thread_ready_phase_seen[idx] = 1'b0;
            thread_move_phase_seen[idx] = 1'b0;
            thread_board_phase_seen[idx] = 1'b0;
            thread_eval_phase_seen[idx] = 1'b0;
            thread_store_phase_seen[idx] = 1'b0;
            thread_board_inflight_seen[idx] = 1'b0;
            thread_move_inflight_seen[idx] = 1'b0;
            thread_eval_inflight_seen[idx] = 1'b0;
            thread_tt_lookup_inflight_seen[idx] = 1'b0;
            thread_tt_store_inflight_seen[idx] = 1'b0;
            thread_board_wait_seen[idx] = 1'b0;
            thread_move_wait_seen[idx] = 1'b0;
            thread_eval_wait_seen[idx] = 1'b0;
            thread_board_tag_seen[idx] = 1'b0;
            thread_move_tag_seen[idx] = 1'b0;
            thread_eval_tag_seen[idx] = 1'b0;
            thread_move_handoff_seen[idx] = 1'b0;
            thread_eval_handoff_seen[idx] = 1'b0;
            root_first_move[idx] = NULL_MOVE;
            root_first_stack_move[idx] = NULL_MOVE;
            nnue_root_rebuild_count[idx] = 0;
            nnue_castle_request_count[idx] = 0;
        end
    endtask : clear_root_push_seen

    task automatic run_scheduler_lifecycle_test(input string label);
        automatic Move best_move;
        automatic EvalScore score;
        automatic NodeCountType nodes;

        clear_tt_thread_seen();
        clear_root_push_seen();
        run_search_depth_record(8'd1, label, best_move, score, nodes);
        check(tt_thread_seen[0], {label, " used root TT lookup on primary thread"});
        check(tt_response_thread_seen[0], {label, " received root TT response on primary thread"});
        check(thread_tt_lookup_inflight_seen[0], {label, " tracked TT lookup in-flight on primary thread"});
        check(thread_tt_lookup_cursor_seen[0], {label, " advanced TT lookup dispatch cursor on primary thread"});
        check(tt_response_pending_dispatch_seen, {label, " held pending TT response in run scheduler"});
        check(thread_tt_response_cursor_seen[0], {label, " applied pending TT response through response cursor"});
        check(all_threads_root_active_seen, {label, " initialized all threads active before root scheduling"});
        check(search_dispatch_state_seen, {label, " used concurrent search run state"});
        check(active_thread_count_full_seen, {label, " initialized active-thread count"});
        if (THREAD_COUNT > 1)
            check(active_thread_count_decrement_seen, {label, " decremented active-thread count"});
        check(store_wait_dispatch_seen, {label, " held pending TT store in run scheduler"});
        check(store_wait_issue_seen, {label, " issued pending TT store from store-wait phase"});
        check(return_pending_dispatch_seen, {label, " held pending child return in run scheduler"});
        if (THREAD_COUNT > 1) begin
            check(multi_move_inflight_seen, {label, " overlapped multiple move-generator requests"});
            check(pipeline_overlap_seen, {label, " overlapped different tagged pipelines"});
        end
        for (int idx = 0; idx < THREAD_COUNT; idx++) begin
            check(root_push_seen[idx], $sformatf("%s pushed root move for thread %0d", label, idx));
            check(thread_selected_active_seen[idx],
                $sformatf("%s selected active scheduler context for thread %0d", label, idx));
                    check(thread_rr_cursor_seen[idx],
                        $sformatf("%s thread %0d was selected by the run scheduler", label, idx));
            check(thread_ready_phase_seen[idx],
                $sformatf("%s thread %0d reached ready phase", label, idx));
            check(thread_move_phase_seen[idx],
                $sformatf("%s thread %0d reached move-wait phase", label, idx));
            check(thread_board_phase_seen[idx],
                $sformatf("%s thread %0d reached board-wait phase", label, idx));
            check(thread_eval_phase_seen[idx],
                $sformatf("%s thread %0d reached eval-wait phase", label, idx));
            check(thread_store_phase_seen[idx],
                $sformatf("%s thread %0d reached store-wait phase", label, idx));
            check(thread_board_inflight_seen[idx],
                $sformatf("%s thread %0d tracked board in-flight", label, idx));
            check(thread_move_inflight_seen[idx],
                $sformatf("%s thread %0d tracked move in-flight", label, idx));
            check(thread_eval_inflight_seen[idx],
                $sformatf("%s thread %0d tracked eval in-flight", label, idx));
            check(thread_tt_store_inflight_seen[idx],
                $sformatf("%s thread %0d tracked TT store in-flight", label, idx));
            check(thread_board_cursor_seen[idx],
                $sformatf("%s thread %0d advanced board dispatch cursor", label, idx));
            check(thread_move_cursor_seen[idx],
                $sformatf("%s thread %0d advanced move dispatch cursor", label, idx));
            check(thread_eval_cursor_seen[idx],
                $sformatf("%s thread %0d advanced eval dispatch cursor", label, idx));
            check(thread_tt_store_cursor_seen[idx],
                $sformatf("%s thread %0d advanced TT store dispatch cursor", label, idx));
            check(thread_return_cursor_seen[idx],
                $sformatf("%s thread %0d advanced return dispatch cursor", label, idx));
            check(!is_null_move(root_first_move[idx]),
                $sformatf("%s thread %0d selected a legal root move", label, idx));
            check(root_stack_seen[idx], $sformatf("%s captured root stack move for thread %0d", label, idx));
            check(root_first_stack_move[idx] == root_first_move[idx],
                $sformatf("%s thread %0d retained selected root move on stack", label, idx));
            check(dut.search_thread_nodes[idx] > NodeCountType'(0),
                $sformatf("%s thread %0d searched nonzero nodes", label, idx));
            check(dut.search_thread_status[idx] == dut.SEARCH_THREAD_DONE,
                $sformatf("%s thread %0d lifecycle done", label, idx));
            check(dut.search_thread_phase[idx] == dut.SEARCH_PHASE_DONE,
                $sformatf("%s thread %0d phase done", label, idx));
            check(!dut.search_board_inflight[idx],
                $sformatf("%s thread %0d board in-flight cleared", label, idx));
            check(!dut.search_move_inflight[idx],
                $sformatf("%s thread %0d move in-flight cleared", label, idx));
            check(!dut.search_eval_inflight[idx],
                $sformatf("%s thread %0d eval in-flight cleared", label, idx));
            check(!dut.search_tt_lookup_inflight[idx],
                $sformatf("%s thread %0d TT lookup in-flight cleared", label, idx));
            check(!dut.search_tt_store_inflight[idx],
                $sformatf("%s thread %0d TT store in-flight cleared", label, idx));
            check(dut.search_active_thread_count == 0,
                $sformatf("%s active-thread count cleared after thread %0d checks", label, idx));
            check(thread_board_wait_seen[idx],
                $sformatf("%s thread %0d used board wait state", label, idx));
            check(thread_move_wait_seen[idx],
                $sformatf("%s thread %0d used move wait state", label, idx));
            check(thread_eval_wait_seen[idx],
                $sformatf("%s thread %0d used eval wait state", label, idx));
            check(thread_board_tag_seen[idx],
                $sformatf("%s thread %0d produced board result tag", label, idx));
            check(thread_move_tag_seen[idx],
                $sformatf("%s thread %0d produced move result tag", label, idx));
            check(thread_eval_tag_seen[idx],
                $sformatf("%s thread %0d produced eval result tag", label, idx));
            check(thread_move_handoff_seen[idx],
                $sformatf("%s thread %0d restored scheduler thread after move result", label, idx));
            check(thread_eval_handoff_seen[idx],
                $sformatf("%s thread %0d restored scheduler thread after eval result", label, idx));
            check(dut.search_thread_completed_depth[idx] == 8'd1,
                $sformatf("%s thread %0d completed depth", label, idx));
            check(nnue_root_rebuild_count[idx] == 1,
                $sformatf("%s thread %0d built its root exactly once", label, idx));
            check(dut.nnue_state_valid[idx],
                $sformatf("%s thread %0d retained a valid root accumulator", label, idx));
            check(!(dut.search_thread_completed_best_move[idx].from_pos == Position'(0)
                    && dut.search_thread_completed_best_move[idx].to_pos == Position'(0)),
                $sformatf("%s thread %0d completed best move non-null found %0d->%0d",
                    label,
                    idx,
                    dut.search_thread_completed_best_move[idx].from_pos,
                    dut.search_thread_completed_best_move[idx].to_pos));
        end
    endtask : run_scheduler_lifecycle_test

    task automatic run_perft_error(input logic [7:0] depth, input string label);
        automatic EngineControllerRequest request = zero_request();

        request.operation = ENGINE_CTRL_PERFT;
        request.depth_limit = depth;
        pulse_request(request, label);
        wait_response(label);
        check(resp.error, {label, " reports error"});
        check(resp.end_reason == ENGINE_END_ERROR, {label, " end reason"});
    endtask : run_perft_error

    task automatic run_search_depth_error(input logic [7:0] depth, input string label);
        automatic EngineControllerRequest request = zero_request();

        request.operation = ENGINE_CTRL_SEARCH_DEPTH;
        request.depth_limit = depth;
        pulse_request(request, label);
        wait_response(label);
        check(resp.error, {label, " reports error"});
        check(resp.end_reason == ENGINE_END_ERROR, {label, " end reason"});
    endtask : run_search_depth_error

    task automatic kill_active_perft(input string label);
        automatic EngineControllerRequest request = zero_request();
        automatic EngineControllerRequest kill_request = zero_request();

        request.operation = ENGINE_CTRL_PERFT;
        request.depth_limit = 8'd4;
        pulse_request(request, {label, " start"});
        do_clock(20);

        kill_request.operation = ENGINE_CTRL_KILL;
        req = kill_request;
        req_valid = 1'b1;
        #1;
        check(req_ready, {label, " kill accepted while active"});
        do_clock(1);
        req_valid = 1'b0;
        req = zero_request();
        wait_response(label);
        check(!resp.error, {label, " kill no error"});
        check(resp.end_reason == ENGINE_END_KILLED, {label, " killed end reason"});
    endtask : kill_active_perft

    task automatic kill_active_search(input string label);
        automatic EngineControllerRequest request = zero_request();
        automatic EngineControllerRequest kill_request = zero_request();
        automatic logic nnue_metadata_clear = 1'b1;
        automatic int completion_wait_cycles = 0;

        request.operation = ENGINE_CTRL_SEARCH_DEPTH;
        request.depth_limit = 8'd4;
        pulse_request(request, {label, " start"});
        while (dut.search_completed_depth == 0 && completion_wait_cycles < 200_000) begin
            do_clock(1);
            completion_wait_cycles += 1;
        end
        check(dut.search_completed_depth != 0, {label, " completed an iteration before kill"});

        kill_request.operation = ENGINE_CTRL_KILL;
        req = kill_request;
        req_valid = 1'b1;
        #1;
        check(req_ready, {label, " kill accepted while active"});
        do_clock(1);
        req_valid = 1'b0;
        req = zero_request();
        wait_response(label);
        check(!resp.error, {label, " kill no error"});
        check(resp.end_reason == ENGINE_END_KILLED, {label, " killed end reason"});
        check(!is_null_move(resp.best_move), {label, " kill preserves completed best move"});
        check(resp.completed_depth != 0, {label, " kill preserves completed depth"});
        check(dut.nnue_update_idle && dut.nnue_eval_ready,
            {label, " flushes queued NNUE work"});
        for (int tid = 0; tid < THREAD_COUNT; tid++) begin
            nnue_metadata_clear &= !dut.nnue_plan_pending[tid];
            nnue_metadata_clear &= !dut.nnue_state_valid[tid];
            check(dut.search_board_wait_count[tid] == 0,
                $sformatf("%s thread %0d board wait canceled", label, tid));
            check(dut.search_move_wait_count[tid] == 0,
                $sformatf("%s thread %0d move wait canceled", label, tid));
            check(dut.search_eval_wait_count[tid] == 0,
                $sformatf("%s thread %0d eval wait canceled", label, tid));
            check(!dut.search_board_inflight[tid],
                $sformatf("%s thread %0d board in-flight canceled", label, tid));
            check(!dut.search_move_inflight[tid],
                $sformatf("%s thread %0d move in-flight canceled", label, tid));
            check(!dut.search_eval_inflight[tid],
                $sformatf("%s thread %0d eval in-flight canceled", label, tid));
            check(!dut.search_tt_lookup_inflight[tid],
                $sformatf("%s thread %0d TT lookup in-flight canceled", label, tid));
            check(!dut.search_tt_store_inflight[tid],
                $sformatf("%s thread %0d TT store in-flight canceled", label, tid));
            check(!dut.search_return_was_scout[tid],
                $sformatf("%s thread %0d PVS scout return canceled", label, tid));
            check(!dut.search_return_was_reduced[tid],
                $sformatf("%s thread %0d reduced return canceled", label, tid));
            check(!dut.search_pvs_research[tid],
                $sformatf("%s thread %0d PVS re-search canceled", label, tid));
            check(dut.search_thread_status[tid] == dut.SEARCH_THREAD_IDLE,
                $sformatf("%s thread %0d status idle after kill", label, tid));
        end
        check(nnue_metadata_clear, {label, " invalidates NNUE state metadata"});
        for (int idx = 0; idx < dut.SEARCH_BOARD_TAG_PIPE_LEN; idx++) begin
            check(!dut.search_board_tag_valid_pipe[idx],
                $sformatf("%s board tag pipe %0d canceled", label, idx));
        end
        for (int idx = 0; idx < dut.SEARCH_MOVE_TAG_PIPE_LEN; idx++) begin
            check(!dut.search_move_tag_valid_pipe[idx],
                $sformatf("%s move tag pipe %0d canceled", label, idx));
        end
    endtask : kill_active_search

    task automatic kill_search_before_root_init(input string label);
        automatic EngineControllerRequest request = zero_request();
        automatic EngineControllerRequest kill_request = zero_request();

        request.operation = ENGINE_CTRL_SEARCH_DEPTH;
        request.depth_limit = 8'd4;
        pulse_request(request, {label, " start"});
        for (int tid = 0; tid < THREAD_COUNT; tid++) begin
            check(is_null_move(dut.search_best_move[tid]),
                $sformatf("%s thread %0d best move cleared", label, tid));
            check(is_null_move(dut.search_ponder_move[tid]),
                $sformatf("%s thread %0d ponder move cleared", label, tid));
            check(dut.search_root_best_score[tid] == -dut.SEARCH_INF,
                $sformatf("%s thread %0d root score cleared", label, tid));
        end

        kill_request.operation = ENGINE_CTRL_KILL;
        pulse_request(kill_request, {label, " kill"});
        wait_response(label);
        check(resp.end_reason == ENGINE_END_KILLED, {label, " killed end reason"});
        check(is_null_move(resp.best_move), {label, " does not return a stale best move"});
        check(is_null_move(resp.ponder_move), {label, " does not return a stale ponder move"});
        check(resp.completed_depth == 8'd0, {label, " has no completed depth"});
    endtask : kill_search_before_root_init

    task automatic set_tile(input Tile tile, input Position pos, input string label);
        automatic EngineControllerRequest request = zero_request();
        automatic logic [3:0] tile_bits;

        request.operation = ENGINE_CTRL_BOARD_UPDATE;
        request.board_op = BOARD_SET_TILE_OP;
        request.move.to_pos = pos;
        tile_bits = (tile.piece_type == NULL_PIECE) ? 4'h0 : tile;
        request.board_wr_data = {3'b000, tile_bits};
        hold_request_until_ready(request, label);
        check(!resp.error, {label, " no error"});
    endtask : set_tile

    task automatic set_turn(input Color color, input string label);
        automatic EngineControllerRequest request = zero_request();

        request.operation = ENGINE_CTRL_BOARD_UPDATE;
        request.board_op = BOARD_SET_TURN_OP;
        request.board_wr_data = {6'b000000, color};
        hold_request_until_ready(request, label);
        check(!resp.error, {label, " no error"});
    endtask : set_turn

    task automatic set_castling_rights(input CastlingRights castling_rights, input string label);
        automatic EngineControllerRequest request = zero_request();

        request.operation = ENGINE_CTRL_BOARD_UPDATE;
        request.board_op = BOARD_SET_CASTLING_RIGHTS_OP;
        request.board_wr_data = {3'b000, castling_rights};
        hold_request_until_ready(request, label);
        check(!resp.error, {label, " no error"});
    endtask : set_castling_rights

    task automatic set_en_passant(input logic has_ep, input BoardFile ep_file, input string label);
        automatic EngineControllerRequest request = zero_request();

        request.operation = ENGINE_CTRL_BOARD_UPDATE;
        request.board_op = BOARD_SET_EN_PASSANT_OP;
        request.board_wr_data = {3'b000, ep_file, has_ep};
        hold_request_until_ready(request, label);
        check(!resp.error, {label, " no error"});
    endtask : set_en_passant

    task automatic set_halfmove_clock(input HalfmoveClock halfmove_clock, input string label);
        automatic EngineControllerRequest request = zero_request();

        request.operation = ENGINE_CTRL_BOARD_UPDATE;
        request.board_op = BOARD_SET_HALFMOVE_CLOCK_OP;
        request.board_wr_data = halfmove_clock;
        hold_request_until_ready(request, label);
        check(!resp.error, {label, " no error"});
    endtask : set_halfmove_clock

    // Position builders always follow New Game, so clear only occupied start
    // squares instead of issuing 64 mostly redundant board-update requests.
    task automatic clear_start_position(input string label);
        for (int pos = 0; pos < 16; pos++) begin
            set_tile(EMPTY_TILE, Position'(pos), $sformatf("%s clear square %0d", label, pos));
        end
        for (int pos = 48; pos < 64; pos++) begin
            set_tile(EMPTY_TILE, Position'(pos), $sformatf("%s clear square %0d", label, pos));
        end
        set_castling_rights(CastlingRights'(4'b0000), {label, " clear castling rights"});
    endtask : clear_start_position

    task automatic setup_kings_only();
        for (int pos = 0; pos < 16; pos++) begin
            if (pos != 4) begin
                set_tile(EMPTY_TILE, Position'(pos), $sformatf("clear square %0d", pos));
            end
        end
        for (int pos = 48; pos < 64; pos++) begin
            if (pos != 60) begin
                set_tile(EMPTY_TILE, Position'(pos), $sformatf("clear square %0d", pos));
            end
        end
        set_castling_rights(CastlingRights'(4'b0000), "clear castling rights for kings only");
    endtask : setup_kings_only

    task automatic setup_castling_perft_position();
        automatic CastlingRights castling_rights;

        castling_rights = CastlingRights'('0);
        castling_rights.white_kingside = 1'b1;
        clear_start_position("castling perft");
        set_tile(WHITE_KING, Position'(4), "castling perft white king e1");
        set_tile(WHITE_ROOK, Position'(7), "castling perft white rook h1");
        set_tile(BLACK_KING, Position'(56), "castling perft black king a8");
        set_castling_rights(castling_rights, "castling perft white kingside right");
        set_turn(WHITE, "castling perft white to move");
    endtask : setup_castling_perft_position

    task automatic setup_en_passant_perft_position();
        clear_start_position("en passant perft");
        set_tile(WHITE_KING, Position'(36), "en passant perft white king e5");
        set_tile(WHITE_PAWN, Position'(37), "en passant perft white pawn f5");
        set_tile(BLACK_PAWN, Position'(38), "en passant perft black pawn g5");
        set_tile(BLACK_KING, Position'(56), "en passant perft black king a8");
        set_en_passant(1'b1, BoardFile'(6), "en passant perft target g-file");
        set_turn(WHITE, "en passant perft white to move");
    endtask : setup_en_passant_perft_position

    task automatic setup_promotion_perft_position();
        clear_start_position("promotion perft");
        set_tile(WHITE_KING, Position'(4), "promotion perft white king e1");
        set_tile(WHITE_PAWN, Position'(48), "promotion perft white pawn a7");
        set_tile(BLACK_KING, Position'(60), "promotion perft black king e8");
        set_turn(WHITE, "promotion perft white to move");
    endtask : setup_promotion_perft_position

    task automatic setup_stalemate_position();
        clear_start_position("stalemate perft");
        set_tile(WHITE_KING, Position'(53), "stalemate white king f7");
        set_tile(WHITE_QUEEN, Position'(46), "stalemate white queen g6");
        set_tile(BLACK_KING, Position'(63), "stalemate black king h8");
        set_turn(BLACK, "stalemate black to move");
    endtask : setup_stalemate_position

    task automatic setup_checkmate_position();
        clear_start_position("checkmate perft");
        set_tile(WHITE_KING, Position'(45), "checkmate white king f6");
        set_tile(WHITE_QUEEN, Position'(54), "checkmate white queen g7");
        set_tile(BLACK_KING, Position'(63), "checkmate black king h8");
        set_turn(BLACK, "checkmate black to move");
    endtask : setup_checkmate_position

    task automatic setup_qsearch_quiet_evasion_position();
        clear_start_position("qsearch quiet evasion");
        set_tile(WHITE_KING, Position'(0), "qsearch quiet evasion white king a1");
        set_tile(WHITE_ROOK, Position'(7), "qsearch quiet evasion white rook h1");
        set_tile(BLACK_KING, Position'(63), "qsearch quiet evasion black king h8");
        set_turn(BLACK, "qsearch quiet evasion black to move");
    endtask : setup_qsearch_quiet_evasion_position

    task automatic setup_rook_takes_queen();
        setup_kings_only();
        set_tile(WHITE_ROOK, Position'(0), "place white rook a1");
        set_tile(BLACK_QUEEN, Position'(56), "place black queen a8");
        set_castling_rights(CastlingRights'(4'b0000), "clear castling rights");
        set_turn(WHITE, "white to move");
    endtask : setup_rook_takes_queen

    task automatic setup_black_rook_takes_queen();
        setup_kings_only();
        set_tile(BLACK_ROOK, Position'(56), "place black rook a8");
        set_tile(WHITE_QUEEN, Position'(0), "place white queen a1");
        set_castling_rights(CastlingRights'(4'b0000), "clear castling rights for black capture");
        set_turn(BLACK, "black to move");
    endtask : setup_black_rook_takes_queen

    task automatic setup_pinned_rook_position();
        clear_start_position("pinned-rook search");
        set_tile(WHITE_KING, Position'(4), "pinned-rook white king e1");
        set_tile(WHITE_ROOK, Position'(12), "pinned-rook white rook e2");
        set_tile(BLACK_ROOK, Position'(60), "pinned-rook black rook e8");
        set_tile(BLACK_KING, Position'(56), "pinned-rook black king a8");
        set_turn(WHITE, "pinned-rook white to move");
    endtask : setup_pinned_rook_position

    task automatic run_stalemate_search(input string label);
        automatic EngineControllerRequest request = zero_request();

        request.operation = ENGINE_CTRL_SEARCH_DEPTH;
        request.depth_limit = 8'd2;
        pulse_request(request, label);
        wait_response(label);
        check(!resp.error, {label, " no error"});
        check(resp.score == DRAW_EVAL_SCORE, {label, " draw score"});
        check(resp.best_move.from_pos == Position'(0) && resp.best_move.to_pos == Position'(0), {label, " no best move"});
        check(resp.completed_depth == 8'd2, {label, " completed requested depth"});
        check(resp.end_reason == ENGINE_END_DEPTH_LIMIT, {label, " end reason"});
    endtask : run_stalemate_search

    task automatic run_checkmate_search(input string label);
        automatic EngineControllerRequest request = zero_request();

        request.operation = ENGINE_CTRL_SEARCH_DEPTH;
        request.depth_limit = 8'd2;
        pulse_request(request, label);
        wait_response(label);
        check(!resp.error, {label, " no error"});
        check(resp.score <= -MATE_THRESHOLD, {label, " losing mate score"});
        check(resp.best_move.from_pos == Position'(0) && resp.best_move.to_pos == Position'(0), {label, " no best move"});
        check(resp.completed_depth == 8'd2, {label, " completed requested depth"});
        check(resp.end_reason == ENGINE_END_DEPTH_LIMIT, {label, " end reason"});
    endtask : run_checkmate_search

    task automatic run_qsearch_checkmate_test(input string label);
        automatic EngineControllerRequest request = zero_request();

        request.operation = ENGINE_CTRL_SEARCH_DEPTH;
        request.depth_limit = 8'd0;
        pulse_request(request, label);
        wait_response(label);
        check(!resp.error, {label, " no error"});
        check(resp.score <= -MATE_THRESHOLD, {label, " losing mate score"});
        check(is_null_move(resp.best_move), {label, " no best move"});
        check(resp.end_reason == ENGINE_END_DEPTH_LIMIT, {label, " end reason"});
    endtask : run_qsearch_checkmate_test

    task automatic run_qsearch_quiet_evasion_test(input string label);
        automatic EngineControllerRequest request = zero_request();

        request.operation = ENGINE_CTRL_SEARCH_DEPTH;
        request.depth_limit = 8'd0;
        pulse_request(request, label);
        wait_response(label);
        check(!resp.error, {label, " no error"});
        check(resp.score > -MATE_THRESHOLD, {label, " not checkmate"});
        check(resp.best_move.from_pos == Position'(63), {label, " evasion moves black king"});
        check(resp.best_move.to_pos == Position'(54) || resp.best_move.to_pos == Position'(62),
            {label, " quiet king evasion"});
        check(resp.end_reason == ENGINE_END_DEPTH_LIMIT, {label, " end reason"});
    endtask : run_qsearch_quiet_evasion_test

    task automatic run_qsearch_capture_test(input string label);
        automatic EngineControllerRequest request = zero_request();

        request.operation = ENGINE_CTRL_SEARCH_DEPTH;
        request.depth_limit = 8'd0;
        pulse_request(request, label);
        wait_response(label);
        check(!resp.error, {label, " no error"});
        check(resp.score > EvalScore'(0), {label, " capture improves score"});
        check(resp.best_move.from_pos == Position'(0), {label, " best move from rook"});
        check(resp.best_move.to_pos == Position'(56), {label, " best move captures queen"});
        check(resp.end_reason == ENGINE_END_DEPTH_LIMIT, {label, " end reason"});
    endtask : run_qsearch_capture_test

    task automatic run_black_qsearch_capture_test(input string label);
        automatic EngineControllerRequest request = zero_request();

        request.operation = ENGINE_CTRL_SEARCH_DEPTH;
        request.depth_limit = 8'd0;
        pulse_request(request, label);
        wait_response(label);
        check(!resp.error, {label, " no error"});
        check(resp.score > EvalScore'(0), {label, " capture improves score from black POV"});
        check(resp.best_move.from_pos == Position'(56), {label, " best move from black rook"});
        check(resp.best_move.to_pos == Position'(0), {label, " best move captures white queen"});
        check(resp.end_reason == ENGINE_END_DEPTH_LIMIT, {label, " end reason"});
    endtask : run_black_qsearch_capture_test

    task automatic run_halfmove_draw_search(input string label);
        automatic EngineControllerRequest request = zero_request();

        request.operation = ENGINE_CTRL_SEARCH_DEPTH;
        request.depth_limit = 8'd3;
        pulse_request(request, label);
        wait_response(label);
        check(!resp.error, {label, " no error"});
        check(resp.score == DRAW_EVAL_SCORE, {label, " draw score"});
        check(resp.nodes_count == NodeCountType'(0), {label, " no nodes searched"});
        check(resp.best_move.from_pos == Position'(0) && resp.best_move.to_pos == Position'(0), {label, " no best move needed"});
        check(resp.end_reason == ENGINE_END_DEPTH_LIMIT, {label, " end reason"});
    endtask : run_halfmove_draw_search

    task automatic repeat_knight_shuffle_once(input string label);
        apply_game_move(make_move(Position'(6), Position'(21), PROMO_QUEEN), {label, " g1f3"});
        apply_game_move(make_move(Position'(62), Position'(45), PROMO_QUEEN), {label, " g8f6"});
        apply_game_move(make_move(Position'(21), Position'(6), PROMO_QUEEN), {label, " f3g1"});
        apply_game_move(make_move(Position'(45), Position'(62), PROMO_QUEEN), {label, " f6g8"});
    endtask : repeat_knight_shuffle_once

    task automatic run_repetition_draw_search(input string label);
        automatic EngineControllerRequest request = zero_request();

        repetition_root_request_seen = 1'b0;
        request.operation = ENGINE_CTRL_SEARCH_DEPTH;
        request.depth_limit = 8'd1;
        pulse_request(request, label);
        wait_response(label);
        check(!resp.error, {label, " no error"});
        check(resp.score == DRAW_EVAL_SCORE, {label, " draw score"});
        check(resp.nodes_count == NodeCountType'(0), {label, " no nodes searched"});
        check(resp.best_move.from_pos == Position'(0) && resp.best_move.to_pos == Position'(0), {label, " no best move needed"});
        check(resp.end_reason == ENGINE_END_DEPTH_LIMIT, {label, " end reason"});
        check(repetition_root_request_seen, {label, " checks root repetition"});
    endtask : run_repetition_draw_search

    task automatic run_node_limit_search(input string label);
        automatic EngineControllerRequest request = zero_request();

        aspiration_window_seen = 1'b0;
        request.operation = ENGINE_CTRL_SEARCH_NODES;
        // Complete at least one iteration, then stop under a hard node budget
        // to exercise aspiration without relying on perft-like node accounting.
        request.node_limit = NodeCountType'(1000);
        pulse_request(request, label);
        wait_response(label);
        check(!resp.error, {label, " no error"});
        check(resp.nodes_count >= NodeCountType'(1000), {label, " reached node limit"});
        check(resp.completed_depth >= 8'd1, {label, " reports a completed iteration"});
        check(resp.end_reason == ENGINE_END_NODE_LIMIT, {label, " end reason"});
        check(aspiration_window_seen, {label, " used an aspiration window"});
    endtask : run_node_limit_search

    task automatic run_fixed_time_search(input string label);
        automatic EngineControllerRequest request = zero_request();

        request.operation = ENGINE_CTRL_SEARCH_FIXED_TIME;
        request.time_limit = TimeType'(0);
        pulse_request(request, label);
        wait_response(label);
        check(!resp.error, {label, " no error"});
        check(resp.completed_depth == 8'd0, {label, " no completed depth"});
        check(resp.end_reason == ENGINE_END_TIME_LIMIT, {label, " end reason"});
    endtask : run_fixed_time_search

    task automatic run_clock_budget_search(input string label);
        automatic EngineControllerRequest request = zero_request();

        request.operation = ENGINE_CTRL_SEARCH_ON_CLOCK;
        request.wtime = TimeType'(0);
        request.btime = TimeType'(1000);
        request.winc = TimeType'(0);
        request.binc = TimeType'(0);
        pulse_request(request, label);
        wait_response(label);
        check(!resp.error, {label, " no error"});
        check(resp.completed_depth == 8'd0, {label, " no completed depth"});
        check(resp.end_reason == ENGINE_END_TIME_LIMIT, {label, " end reason"});
    endtask : run_clock_budget_search

    initial begin
        reset_dut();

        check(dut.lmr_table_value_for_params(128, 256, 1, 1) == 8'd1,
            "LMR non-default half-ply offset rounds the complete curve once");
        check(dut.lmr_table_value_for_params(0, 256, 2, 2) == 8'd2,
            "LMR non-default denominator preserves Q8 curve scaling");
        check(dut.LMR_DEPTH_BUCKETS == dut.floor_log2_8(SEARCH_STACK_DEPTH - 1) + 1,
            "LMR generates only reachable depth buckets");
        check(dut.LMR_TABLE_MAX_VALUE == dut.lmr_table_value(dut.LMR_DEPTH_BUCKETS - 1, 7),
            "LMR table maximum comes from its largest reachable bucket");
        check((1 << dut.LMR_TABLE_VALUE_BITS) > dut.LMR_TABLE_MAX_VALUE,
            "LMR table value width represents the configured maximum");
        check(dut.floor_log2_8(8'd1) == 3'd0 && dut.floor_log2_8(8'd2) == 3'd1,
            "LMR move/depth bucket lower boundaries");
        check(dut.floor_log2_8(8'd3) == 3'd1 && dut.floor_log2_8(8'd4) == 3'd2,
            "LMR move/depth bucket upper boundaries");
        check(dut.floor_log2_8(8'd127) == 3'd6 && dut.floor_log2_8(8'd128) == 3'd7,
            "LMR 8-bit saturation bucket boundary");
        clock_budget_request = zero_request();
        clock_budget_request.wtime = TimeType'(180_000);
        clock_budget_request.btime = TimeType'(180_000);
        clock_budget_request.winc = TimeType'(2_000);
        clock_budget_request.binc = TimeType'(2_000);
        check(dut.clock_budget(clock_budget_request) == TimeType'(7_124),
            "3+2 clock budget uses the target increment and remaining-clock share");
        check(!dut.lmr_eligible(PlyIndex'(0), 8'd8, 8'd2, 1'b0), "LMR excludes root moves");
        check(!dut.lmr_eligible(PlyIndex'(1), 8'd2, 8'd2, 1'b0), "LMR excludes shallow moves");
        check(!dut.lmr_eligible(PlyIndex'(1), 8'd3, 8'd1, 1'b0), "LMR excludes the first two legal moves");
        check(dut.lmr_eligible(PlyIndex'(1), 8'd3, 8'd2, 1'b0), "LMR includes the third legal move");
        check(!dut.lmr_eligible(PlyIndex'(1), 8'd3, 8'd2, 1'b1), "LMR excludes full-depth recovery");
        check(dut.search_needs_research(1'b1, 1'b1, EvalScore'(20), EvalScore'(10), EvalScore'(20)),
            "LMR verifies a reduced beta cutoff at full depth");
        check(!dut.search_needs_research(1'b1, 1'b0, EvalScore'(20), EvalScore'(10), EvalScore'(20)),
            "ordinary PVS beta cutoff does not require full-depth recovery");
        force dut.search_stack_top[0].remaining_depth = 5'd6;
        check(dut.null_child_depth(ThreadID'(0)) == 5'd3,
            "null reduction is two plies below depth seven");
        force dut.search_stack_top[0].remaining_depth = 5'd7;
        check(dut.null_child_depth(ThreadID'(0)) == 5'd3,
            "null reduction is three plies from depth seven");
        release dut.search_stack_top[0].remaining_depth;
        force dut.search_stack_top[0].remaining_depth = 5'd3;
        force dut.search_stack_top[0].legal_move_count = 8'hff;
        check(dut.lmr_child_depth(ThreadID'(0)) <= 8'd2, "LMR clamps reduction to d-1 at saturated move count");
        release dut.search_stack_top[0].remaining_depth;
        release dut.search_stack_top[0].legal_move_count;
        for (int depth_bucket = 0; depth_bucket < dut.LMR_DEPTH_BUCKETS; depth_bucket++) begin
            for (int move_bucket = 1; move_bucket < 8; move_bucket++) begin
                check(dut.lmr_reduction(3'(depth_bucket), 3'(move_bucket))
                        >= dut.lmr_reduction(3'(depth_bucket), 3'(move_bucket - 1)),
                    $sformatf("LMR table move monotonic depth bucket %0d move bucket %0d", depth_bucket, move_bucket));
            end
        end
        for (int depth_bucket = 1; depth_bucket < dut.LMR_DEPTH_BUCKETS; depth_bucket++) begin
            for (int move_bucket = 0; move_bucket < 8; move_bucket++) begin
                check(dut.lmr_reduction(3'(depth_bucket), 3'(move_bucket))
                        >= dut.lmr_reduction(3'(depth_bucket - 1), 3'(move_bucket)),
                    $sformatf("LMR table depth monotonic depth bucket %0d move bucket %0d", depth_bucket, move_bucket));
            end
        end

        new_game();
        run_perft(8'd0, NodeCountType'(1), "startpos perft depth 0");
        run_perft(8'd1, NodeCountType'(20), "startpos perft depth 1");
        run_perft(8'd2, NodeCountType'(400), "startpos perft depth 2");
        run_search_depth(8'd2, "startpos search depth 2");
        check_search_stats("startpos search statistics");
        check(pvs_scout_seen, "startpos depth 2 used a PVS scout window");
        check(pvs_research_seen, "startpos depth 2 re-searched a PVS scout fail-high");
        check(aspiration_window_seen, "startpos depth 2 used an aspiration window");
        kill_search_before_root_init("early search kill");

        // Opposite-direction moves h2h4 and h5h3 must have distinct mask identities.
        new_game();
        apply_game_move(make_move(Position'(12), Position'(20), PROMO_QUEEN), "perft regression e2e3");
        apply_game_move(make_move(Position'(48), Position'(40), PROMO_QUEEN), "perft regression a7a6");
        apply_game_move(make_move(Position'(3), Position'(39), PROMO_QUEEN), "perft regression d1h5");
        apply_game_move(make_move(Position'(40), Position'(32), PROMO_QUEEN), "perft regression a6a5");
        run_perft(8'd1, NodeCountType'(44), "queen sortie perft depth 1");

        new_game();
        setup_kings_only();
        run_perft(8'd1, NodeCountType'(5), "kings-only perft depth 1");
        run_search_depth(8'd4, "kings-only LMR search depth 4");
        check(null_push_seen, "depth-4 scout search issued a null move");
        check(null_reverse_seen, "null child was reversed through board history");
        check(lmr_reduced_issue_seen, "LMR controller reduces an eligible third-or-later move");
        check(lmr_recovery_issue_seen, "LMR alpha-raising scout is issued again at full depth");
        check(lmr_reduced_tt_depth_seen, "LMR reduced child TT request uses reduced depth");
        check(lmr_full_tt_depth_seen, "LMR recovery TT request uses restored full depth");

        new_game();
        setup_pinned_rook_position();
        begin
            automatic Move ignored_move;
            automatic EvalScore ignored_score;
            automatic NodeCountType ignored_nodes;
            run_search_depth_record(8'd1, "pinned-rook illegal-candidate search",
                ignored_move, ignored_score, ignored_nodes);
        end
        // The generator unit test proves the pinned move is emitted. This
        // search completing proves board-update rejection does not stall it.

        new_game();
        setup_castling_perft_position();
        run_perft(8'd1, NodeCountType'(15), "castling perft depth 1");
        run_search_depth(8'd1, "castling NNUE delta search");

        new_game();
        setup_en_passant_perft_position();
        run_perft(8'd1, NodeCountType'(8), "en passant perft depth 1");
        run_search_depth(8'd1, "en passant NNUE delta search");

        new_game();
        setup_promotion_perft_position();
        run_perft(8'd1, NodeCountType'(9), "promotion perft depth 1");
        run_search_depth(8'd1, "promotion NNUE delta search");

        new_game();
        setup_stalemate_position();
        run_perft(8'd1, NodeCountType'(0), "stalemate perft depth 1");
        run_stalemate_search("stalemate search");

        new_game();
        setup_checkmate_position();
        run_perft(8'd1, NodeCountType'(0), "checkmate perft depth 1");
        run_checkmate_search("checkmate search");

        new_game();
        setup_checkmate_position();
        run_qsearch_checkmate_test("qsearch checkmate");

        new_game();
        setup_qsearch_quiet_evasion_position();
        run_qsearch_quiet_evasion_test("qsearch quiet check evasion");

        new_game();
        apply_game_move(make_move(Position'(12), Position'(28), PROMO_QUEEN), "make e2e4");
        run_perft(8'd1, NodeCountType'(20), "after e2e4 perft depth 1");

        new_game();
        kill_active_perft("kill active perft");
        new_game();
        kill_active_search("kill active search");
        run_perft_error(8'd32, "oversized perft depth");
        run_search_depth_error(8'd32, "oversized search depth");

        new_game();
        setup_rook_takes_queen();
        run_qsearch_capture_test("qsearch rook takes queen");

        new_game();
        setup_black_rook_takes_queen();
        run_black_qsearch_capture_test("black qsearch rook takes queen");

        new_game();
        setup_rook_takes_queen();
        set_halfmove_clock(HalfmoveClock'(100), "set 50-move draw halfmove clock");
        run_halfmove_draw_search("50-move draw search");

        new_game();
        repeat_knight_shuffle_once("first repetition cycle");
        repeat_knight_shuffle_once("second repetition cycle");
        run_repetition_draw_search("threefold root search");

        run_tt_child_validation_policy_test("TT child validation policy");
        run_tt_immediate_draw_rejection_test("TT immediate draw validation");
        run_tt_repeated_child_rejection_test("TT repeated child validation");
        run_tt_nonpositive_score_rejection_test("TT non-positive score validation");
        run_tt_illegal_move_rejection_test("TT illegal move validation");

        new_game();
        run_tt_reuse_test("startpos TT reuse");
        run_shallow_tt_move_ordering_test("shallow TT move ordering");

        new_game();
        run_scheduler_lifecycle_test("scheduler lifecycle search");

        new_game();
        run_node_limit_search("node-limited search");
        run_fixed_time_search("zero fixed-time search");
        run_clock_budget_search("zero clock-budget search");

        // A synthetic nonzero model proves the search score consumes the NNUE
        // result rather than merely exercising the update/output handshake.
        begin
            automatic Move baseline_move, nnue_move;
            automatic EvalScore baseline_score, nnue_score;
            automatic NodeCountType baseline_nodes, nnue_nodes;
            automatic int bucket = int'(nnue_output_bucket(PieceCount'(3)));
            for (int row = bucket * NNUE_OUTPUT_MAC_CYCLES;
                    row < (bucket + 1) * NNUE_OUTPUT_MAC_CYCLES; row++)
                dut.nnue_evaluator.output_weight_rows[row] = 0;
            dut.nnue_evaluator.output_bias[bucket] = 0;
            new_game();
            setup_kings_only();
            set_tile(WHITE_PAWN, Position'(8), "NNUE baseline white pawn a2");
            run_search_depth_record(8'd0, "NNUE baseline search",
                baseline_move, baseline_score, baseline_nodes);
            for (int row = 0; row < NNUE_FEATURE_COUNT; row++)
                dut.nnue_evaluator.feature_rom[row] = 0;
            dut.nnue_evaluator.feature_rom[8] = {NNUE_ROW_BYTES{8'h55}};
            for (int row = bucket * NNUE_OUTPUT_MAC_CYCLES;
                    row < (bucket + 1) * NNUE_OUTPUT_MAC_CYCLES; row++)
                dut.nnue_evaluator.output_weight_rows[row] = {NNUE_OUTPUT_MAC_LANES{3'h1}};
            for (int lane = 0; lane < NNUE_ACCUMULATOR_COUNT; lane++)
                dut.nnue_evaluator.accumulator_bias[lane] = 0;
            new_game();
            setup_kings_only();
            set_tile(WHITE_PAWN, Position'(8), "NNUE correction white pawn a2");
            run_search_depth_record(8'd0, "NNUE correction search",
                nnue_move, nnue_score, nnue_nodes);
            // Only White's direct a2-pawn feature is nonzero, so the ordered
            // concatenation contributes one activation in every White lane.
            check(nnue_score == baseline_score + EvalScore'(256),
                $sformatf("search adds NNUE correction: baseline=%0d corrected=%0d",
                    baseline_score, nnue_score));
        end
        check(dut.EVAL_WAIT_CYCLES == NNUE_OUTPUT_MAC_CYCLES + 1,
            "NNUE evaluation wait includes MAC and registered-result cycles");
        check(nnue_delta_seen, "NNUE child states apply physical move deltas");
        check(nnue_reverse_delta_seen,
            "NNUE restores parent state with an inverse stack delta");
        check(nnue_rebuild_seen, "NNUE rebuild path initializes root accumulators");
        check(nnue_pending_state_invalid,
            "pending NNUE child slots stay invalid until their tagged completion");
        check(nnue_root_initialization_seen && nnue_root_initialization_correct,
            "pre-search NNUE roots are flushed, valid, and identical for every thread");
        check(nnue_king_delta_seen && nnue_king_delta_correct,
            "king moves use direct incremental NNUE features");
        check(nnue_castle_delta_seen,
            "castling includes the rook in direct NNUE deltas");
        check(nnue_castle_request_count_correct,
            "each castling delta uses exactly four feature requests");
        check(nnue_castle_state_seen && nnue_en_passant_state_seen
                && nnue_promotion_state_seen && nnue_special_state_correct,
            "special-move deltas and inverses exactly match full NNUE rebuilds");
        check(nnue_null_state_seen && nnue_null_state_correct,
            "null children retain valid NNUE state without an update plan");
        check(!nnue_recovery_rebuild_seen,
            "ordinary evaluation never repairs an unexpectedly invalid accumulator");
        check(stats_reset_correct, "every new search resets all statistics");
        check(tt_lookup_depth_correct, "every TT lookup uses the node remaining depth");
        check(tt_store_depth_correct, "every TT store uses the node remaining depth");

        $display("Pass Count: %0d", pass_count);
        $display("Fail Count: %0d", fail_count);
        if (fail_count != 0) begin
            $fatal(1, "search controller testbench failed");
        end
        $finish;
    end

    initial begin
        #5_000_000;
        fail_count += 1;
        $error("[FAIL] tb_search_controller timeout");
        $display("Pass Count: %0d", pass_count);
        $display("Fail Count: %0d", fail_count);
        $fatal(1, "tb_search_controller timeout");
    end

    always_ff @(posedge clk) begin
        if (!rst_n) begin
            stats_reset_pending <= 1'b0;
        end else begin
            if (stats_reset_pending) begin
                stats_reset_correct &= dut.stat_tt_lookups == 40'd0;
                stats_reset_correct &= dut.stat_tt_hits == 40'd0;
                stats_reset_correct &= dut.stat_cache_lookups == 40'd0;
                stats_reset_correct &= dut.stat_cache_hits == 40'd0;
                for (int tid = 0; tid < THREAD_COUNT; tid++) begin
                    for (int phase = 0; phase < ENGINE_STAT_PHASE_COUNT_VALUE; phase++) begin
                        stats_reset_correct &= dut.stat_phase_cycles[tid][phase] == 40'd0;
                    end
                end
                stats_reset_pending <= 1'b0;
            end
            if (req_valid && req_ready
                    && (req.operation == ENGINE_CTRL_SEARCH_DEPTH
                        || req.operation == ENGINE_CTRL_SEARCH_FIXED_TIME
                        || req.operation == ENGINE_CTRL_SEARCH_ON_CLOCK
                        || req.operation == ENGINE_CTRL_SEARCH_NODES)) begin
                stats_reset_pending <= 1'b1;
            end
            if (dut.nnue_update_valid && dut.nnue_update_ready) begin
                if (dut.nnue_update_req.clear) begin
                    nnue_rebuild_seen = 1'b1;
                    if (dut.nnue_update_req.ply == PlyIndex'(0))
                        nnue_root_rebuild_count[dut.nnue_update_req.thread_id] += 1;
                end else if (dut.nnue_delta_busy
                        && dut.nnue_plan_kind[dut.nnue_delta_thread] == dut.NNUE_PLAN_DELTA)
                    nnue_delta_seen = 1'b1;
                if (dut.nnue_delta_busy
                        && dut.nnue_plan_kind[dut.nnue_delta_thread] == dut.NNUE_PLAN_DELTA
                        && dut.nnue_plan_mover[dut.nnue_delta_thread].piece_type == KING
                        && dut.nnue_plan_from[dut.nnue_delta_thread][2:0] == BoardFile'(4)
                        && (dut.nnue_plan_to[dut.nnue_delta_thread][2:0] == BoardFile'(2)
                            || dut.nnue_plan_to[dut.nnue_delta_thread][2:0] == BoardFile'(6)))
                    nnue_castle_request_count[dut.nnue_delta_thread] += 1;
            end
            if (dut.nnue_update_done_valid
                    && dut.nnue_plan_mover[dut.nnue_update_done_thread].piece_type == KING
                    && dut.nnue_plan_from[dut.nnue_update_done_thread][2:0] == BoardFile'(4)
                    && (dut.nnue_plan_to[dut.nnue_update_done_thread][2:0] == BoardFile'(2)
                        || dut.nnue_plan_to[dut.nnue_update_done_thread][2:0]
                            == BoardFile'(6))) begin
                nnue_castle_request_count_correct &=
                    nnue_castle_request_count[dut.nnue_update_done_thread] == 4;
                nnue_castle_request_count[dut.nnue_update_done_thread] = 0;
            end
            if (dut.nnue_update_done_valid) begin
                automatic ThreadID completed_thread = dut.nnue_update_done_thread;
                automatic logic is_castle =
                    dut.nnue_plan_mover[completed_thread].piece_type == KING
                    && dut.nnue_plan_from[completed_thread][2:0] == BoardFile'(4)
                    && (dut.nnue_plan_to[completed_thread][2:0] == BoardFile'(2)
                        || dut.nnue_plan_to[completed_thread][2:0] == BoardFile'(6));
                automatic logic is_en_passant =
                    dut.nnue_plan_mover[completed_thread].piece_type == PAWN
                    && dut.nnue_plan_capture_valid[completed_thread]
                    && dut.nnue_plan_capture_pos[completed_thread]
                        != dut.nnue_plan_to[completed_thread];
                automatic logic is_promotion =
                    dut.nnue_plan_mover[completed_thread].piece_type == PAWN
                    && dut.nnue_plan_placed[completed_thread].piece_type != PAWN;
                if (is_castle || is_en_passant || is_promotion) begin
                    automatic logic [
                        NNUE_STATE_VALUE_COUNT * NNUE_ACCUMULATOR_BITS-1:0]
                        expected = reference_nnue_state(
                            dut.search_board[completed_thread]);
                    nnue_castle_state_seen |= is_castle;
                    nnue_en_passant_state_seen |= is_en_passant;
                    nnue_promotion_state_seen |= is_promotion;
                    nnue_special_state_correct &=
                        dut.nnue_evaluator.accumulator_update_memory[
                            completed_thread] === expected;
                    nnue_special_state_correct &=
                        dut.nnue_evaluator.accumulator_eval_memory[
                            completed_thread] === expected;
                end
            end
            if (dut.state == dut.ST_SEARCH_ROOT_INIT
                    && dut.nnue_root_init_pos == Position'(0)
                    && dut.nnue_root_init_first)
                nnue_root_initialization_correct &= dut.nnue_update_idle;
            if (dut.state == dut.ST_SEARCH_RUN && dut.nnue_roots_initialized
                    && !nnue_root_initialization_seen) begin
                nnue_root_initialization_seen = 1'b1;
                for (int idx = 0; idx < THREAD_COUNT; idx++) begin
                    nnue_root_initialization_correct &=
                        dut.nnue_state_valid[idx];
                    nnue_root_initialization_correct &=
                        dut.nnue_evaluator.accumulator_update_memory[
                            idx
                        ] === dut.nnue_evaluator.accumulator_update_memory[0];
                    nnue_root_initialization_correct &=
                        dut.nnue_evaluator.accumulator_eval_memory[
                            idx
                        ] === dut.nnue_evaluator.accumulator_eval_memory[0];
                end
            end
            if (dut.state == dut.ST_SEARCH_RUN && dut.nnue_build_busy
                    && dut.nnue_update_valid && dut.nnue_update_ready
                    && dut.nnue_update_req.clear)
                nnue_recovery_rebuild_seen = 1'b1;
            for (int idx = 0; idx < THREAD_COUNT; idx++) begin
                if (dut.search_stack_top[idx].entered_by_null
                        && dut.search_thread_phase[idx] == dut.SEARCH_PHASE_READY) begin
                    nnue_null_state_seen = 1'b1;
                    nnue_null_state_correct &= dut.nnue_state_valid[idx]
                        && !dut.nnue_plan_pending[idx];
                end
                if (dut.nnue_plan_pending[idx])
                    nnue_pending_state_invalid &=
                        !dut.nnue_state_valid[idx];
                if (dut.nnue_plan_pending[idx] && dut.nnue_plan_reverse[idx])
                    nnue_reverse_delta_seen = 1'b1;
                if (dut.nnue_plan_pending[idx] && dut.nnue_plan_real_move[idx]
                        && dut.nnue_plan_mover[idx].piece_type == KING) begin
                    automatic logic is_castle =
                        dut.nnue_plan_from[idx][2:0] == BoardFile'(4)
                        && (dut.nnue_plan_to[idx][2:0] == BoardFile'(2)
                            || dut.nnue_plan_to[idx][2:0] == BoardFile'(6));
                    if (is_castle) begin
                        nnue_king_delta_correct &=
                            dut.nnue_plan_kind[idx] == dut.NNUE_PLAN_DELTA;
                    end else begin
                        nnue_king_delta_seen = 1'b1;
                        nnue_king_delta_correct &=
                            dut.nnue_plan_kind[idx] == dut.NNUE_PLAN_DELTA;
                    end
                    if (dut.nnue_plan_from[idx] == Position'(4)
                            && dut.nnue_plan_to[idx] == Position'(6)
                            && dut.nnue_plan_kind[idx] == dut.NNUE_PLAN_DELTA)
                        nnue_castle_delta_seen = 1'b1;
                end
                if (lmr_depth_check_pending[idx]) begin
                    check(8'(dut.search_pending_child_depth[idx]) == lmr_expected_child_depth[idx],
                        $sformatf("LMR registers reduced child depth expected=%0d actual=%0d",
                            lmr_expected_child_depth[idx],
                            8'(dut.search_pending_child_depth[idx])));
                    lmr_depth_check_pending[idx] = 1'b0;
                end
                if (lmr_recovery_check_pending[idx]) begin
                    check(8'(dut.search_pending_child_depth[idx]) == lmr_expected_child_depth[idx],
                        "LMR recovery restores full child depth without another reduction");
                    lmr_recovery_check_pending[idx] = 1'b0;
                end
                if (dut.search_thread_aspiration_active[0] && !aspiration_window_seen) begin
                    aspiration_window_seen = 1'b1;
                    check(dut.search_thread_root_beta[0] - dut.search_thread_root_alpha[0] == EvalScore'(30),
                        "aspiration window starts with the configured narrow delta");
                    check(dut.search_thread_root_alpha[0] == dut.search_completed_score - EvalScore'(15)
                            && dut.search_thread_root_beta[0] == dut.search_completed_score + EvalScore'(15),
                        "aspiration window is centered on the previous score");
                end
                if (dut.search_stack_top[idx].scout_search && !pvs_scout_seen) begin
                    pvs_scout_seen = 1'b1;
                    check(dut.search_stack_top[idx].beta == dut.search_stack_top[idx].alpha + EvalScore'(1),
                        "PVS scout window has unit width");
                end
                if (dut.search_pvs_research[idx]) begin
                    pvs_research_seen = 1'b1;
                end
                if (root_stack_capture_pending[idx]) begin
                    root_stack_seen[idx] = 1'b1;
                root_first_stack_move[idx] = dut.search_stack_top[idx].move;
                    root_stack_capture_pending[idx] = 1'b0;
                end
                if (dut.search_board_wait_count[idx] != 0) begin
                    thread_board_wait_seen[idx] = 1'b1;
                end
                if (dut.search_move_wait_count[idx] != 0) begin
                    thread_move_wait_seen[idx] = 1'b1;
                end
                if (dut.search_eval_wait_count[idx] != 0) begin
                    thread_eval_wait_seen[idx] = 1'b1;
                end
                if (dut.search_thread_phase[idx] == dut.SEARCH_PHASE_READY) begin
                    thread_ready_phase_seen[idx] = 1'b1;
                end
                if (dut.search_thread_phase[idx] == dut.SEARCH_PHASE_MOVE_WAIT) begin
                    thread_move_phase_seen[idx] = 1'b1;
                end
                if (dut.search_thread_phase[idx] == dut.SEARCH_PHASE_BOARD_WAIT) begin
                    thread_board_phase_seen[idx] = 1'b1;
                end
                if (dut.search_thread_phase[idx] == dut.SEARCH_PHASE_EVAL_WAIT) begin
                    thread_eval_phase_seen[idx] = 1'b1;
                end
                if (dut.search_thread_phase[idx] == dut.SEARCH_PHASE_STORE_PUBLISH) begin
                    thread_store_phase_seen[idx] = 1'b1;
                end
                if (dut.search_board_inflight[idx]) begin
                    thread_board_inflight_seen[idx] = 1'b1;
                    if (dut.search_dispatch.board == expected_next_thread(idx)) begin
                        thread_board_cursor_seen[idx] = 1'b1;
                    end
                end
                if (dut.search_move_inflight[idx]) begin
                    thread_move_inflight_seen[idx] = 1'b1;
                    if (dut.search_dispatch.move == expected_next_thread(idx)) begin
                        thread_move_cursor_seen[idx] = 1'b1;
                    end
                end
                if (dut.search_eval_inflight[idx]) begin
                    thread_eval_inflight_seen[idx] = 1'b1;
                    if (dut.search_dispatch.eval == expected_next_thread(idx)) begin
                        thread_eval_cursor_seen[idx] = 1'b1;
                    end
                end
                if (dut.search_tt_lookup_inflight[idx]) begin
                    thread_tt_lookup_inflight_seen[idx] = 1'b1;
                    if (dut.search_dispatch.tt_lookup == expected_next_thread(idx)) begin
                        thread_tt_lookup_cursor_seen[idx] = 1'b1;
                    end
                end
                if (dut.search_tt_store_inflight[idx]) begin
                    thread_tt_store_inflight_seen[idx] = 1'b1;
                end
                if (thread_tt_store_inflight_seen[idx]
                        && dut.search_dispatch.tt_store == expected_next_thread(idx)) begin
                    thread_tt_store_cursor_seen[idx] = 1'b1;
                end
            end
            begin
                automatic int move_inflight_count;
                automatic int active_pipeline_count;

                move_inflight_count = 0;
                active_pipeline_count = 0;
                for (int idx = 0; idx < THREAD_COUNT; idx++) begin
                    if (dut.search_move_inflight[idx]) move_inflight_count += 1;
                end
                if (move_inflight_count > 1) begin
                    multi_move_inflight_seen = 1'b1;
                end
                for (int idx = 0; idx < THREAD_COUNT; idx++) begin
                    if (dut.search_board_inflight[idx]) begin
                        active_pipeline_count += 1;
                        break;
                    end
                end
                for (int idx = 0; idx < THREAD_COUNT; idx++) begin
                    if (dut.search_move_inflight[idx]) begin
                        active_pipeline_count += 1;
                        break;
                    end
                end
                for (int idx = 0; idx < THREAD_COUNT; idx++) begin
                    if (dut.search_eval_inflight[idx]) begin
                        active_pipeline_count += 1;
                        break;
                    end
                end
                if (active_pipeline_count > 1) begin
                    pipeline_overlap_seen = 1'b1;
                end
            end
            if (dut.state == dut.ST_SEARCH_RUN) begin
                search_dispatch_state_seen = 1'b1;
                for (int idx = 0; idx < THREAD_COUNT; idx++) begin
                    if (dut.search_thread_phase[idx] == dut.SEARCH_PHASE_STORE_PUBLISH
                            && dut.search_tt_store_inflight[idx]) begin
                        store_wait_dispatch_seen = 1'b1;
                    end
                    if (dut.search_thread_phase[idx] == dut.SEARCH_PHASE_MOVE_WAIT
                            && dut.search_return_valid[idx]
                            && !dut.search_move_inflight[idx]) begin
                        return_pending_dispatch_seen = 1'b1;
                    end
                    if (dut.search_thread_phase[idx] == dut.SEARCH_PHASE_TT_WAIT
                            && dut.search_tt_response_pending[idx]
                            && !dut.search_tt_lookup_inflight[idx]) begin
                        tt_response_pending_dispatch_seen = 1'b1;
                    end
                end
            end
            if (dut.state == dut.ST_SEARCH_RUN) begin
                for (int idx = 0; idx < THREAD_COUNT; idx++) begin
                    if (dut.search_tt_response_pending[idx]
                            && dut.search_thread_phase[idx] == dut.SEARCH_PHASE_TT_WAIT) begin
                        thread_tt_response_cursor_seen[idx] = 1'b1;
                    end
                    if (dut.search_return_valid[idx]
                            && !dut.search_move_inflight[idx]
                            && dut.search_thread_phase[idx] == dut.SEARCH_PHASE_MOVE_WAIT) begin
                        thread_return_cursor_seen[idx] = 1'b1;
                    end
                end
            end
            if (dut.state == dut.ST_SEARCH_RUN
                    && dut.search_tt_store_issue_valid
                    && dut.tt_store_req_ready) begin
                store_wait_issue_seen = 1'b1;
            end
            if (int'(dut.search_active_thread_count) == THREAD_COUNT) begin
                active_thread_count_full_seen = 1'b1;
            end
            if (int'(dut.search_active_thread_count) > 0
                    && int'(dut.search_active_thread_count) < THREAD_COUNT) begin
                active_thread_count_decrement_seen = 1'b1;
            end
            if (dut.tt_lookup_req_valid && dut.tt_lookup_req_ready) begin
                tt_lookup_count += 1;
                tt_thread_seen[int'(dut.tt_lookup_req.thread_id)] = 1'b1;
                tt_lookup_depth_correct &= dut.tt_lookup_req.depth
                    == dut.search_stack_top[int'(dut.tt_lookup_req.thread_id)].remaining_depth;
                if (dut.search_stack_top[int'(dut.tt_lookup_req.thread_id)].count_move_on_return) begin
                    if (dut.search_stack_top[int'(dut.tt_lookup_req.thread_id)].remaining_depth
                            < dut.search_thread_target_depth[int'(dut.tt_lookup_req.thread_id)]
                                - 5'(dut.search_ply[int'(dut.tt_lookup_req.thread_id)])) begin
                        lmr_reduced_tt_depth_seen = 1'b1;
                    end
                end
                if (lmr_full_tt_pending[int'(dut.tt_lookup_req.thread_id)]) begin
                    lmr_full_tt_depth_seen = 1'b1;
                    lmr_full_tt_pending[int'(dut.tt_lookup_req.thread_id)] = 1'b0;
                end
            end
            if (dut.tt_lookup_resp_valid) begin
                tt_response_thread_seen[int'(dut.tt_lookup_resp.thread_id)] = 1'b1;
                if (dut.tt_lookup_resp.hit
                        && dut.tt_lookup_resp.depth < dut.search_remaining_depth(
                            dut.tt_lookup_resp.thread_id)
                        && !is_null_move(dut.tt_lookup_resp.best_move)) begin
                    shallow_tt_hit_seen = 1'b1;
                    shallow_tt_target_pending[int'(dut.tt_lookup_resp.thread_id)] = 1'b1;
                    shallow_tt_target_move[int'(dut.tt_lookup_resp.thread_id)] = dut.tt_lookup_resp.best_move;
                end
            end
            if (dut.repetition_req_valid
                    && dut.search_tt_validation_pending[int'(dut.repetition_req_thread)]) begin
                tt_validation_repetition_count += 1;
            end
            for (int idx = 0; idx < THREAD_COUNT; idx++) begin
                if (dut.search_tt_validation_passed[idx]) begin
                    tt_validation_pass_count += 1;
                end
            end
            if (dut.repetition_resp_valid
                    && dut.search_tt_validation_pending[int'(dut.repetition_resp_thread)]
                    && dut.repetition_resp_count != 2'd0) begin
                tt_validation_repeat_reject_count += 1;
            end
            if (dut.state == dut.ST_SEARCH_RUN && |dut.search_tt_response_mask) begin
                automatic ThreadID validation_tid = dut.search_select_thread(
                    dut.search_tt_response_mask,
                    dut.search_dispatch.tt_response
                );
                if (dut.search_tt_response[validation_tid].hit
                        && dut.search_tt_response[validation_tid].depth
                            >= dut.search_remaining_depth(validation_tid)
                        && dut.search_remaining_depth(validation_tid)
                            >= dut.TT_VALIDATE_MINIMUM_DEPTH
                        && dut.search_board[validation_tid].halfmove_clock
                            > HalfmoveClock'(dut.TT_VALIDATE_BYPASS_HALFMOVES)
                        && dut.search_tt_response[validation_tid].score <= DRAW_EVAL_SCORE
                        && !dut.search_tt_validation_passed[validation_tid]) begin
                    tt_validation_nonpositive_reject_count += 1;
                end
            end
            if (dut.move_cmd_resp_valid
                    && dut.search_tt_validation_pending[int'(dut.move_cmd_resp_thread)]
                    && !dut.move_cmd_resp_direct_valid) begin
                tt_validation_illegal_reject_count += 1;
            end
            if (dut.search_board_tag_valid_pipe[dut.SEARCH_BOARD_TAG_PIPE_LEN - 1]
                    && dut.search_tt_validation_pending[
                        int'(dut.search_board_tag_pipe[dut.SEARCH_BOARD_TAG_PIPE_LEN - 1])]
                    && dut.board_update_mover_in_check) begin
                tt_validation_illegal_reject_count += 1;
            end
            if (dut.move_cmd_valid && dut.move_cmd_ready
                    && dut.move_cmd == move_generator_defs::MOVE_GEN_VALIDATE_DIRECT
                    && shallow_tt_target_pending[int'(dut.move_cmd_thread)]
                    && dut.search_stack_top[int'(dut.move_cmd_thread)].has_tt_move
                    && dut.move_cmd_suppress_move == shallow_tt_target_move[int'(dut.move_cmd_thread)]) begin
                shallow_tt_target_seen = 1'b1;
                shallow_tt_target_pending[int'(dut.move_cmd_thread)] = 1'b0;
            end
            if (dut.tt_store_req_valid && dut.tt_store_req_ready) begin
                tt_store_count += 1;
                tt_store_depth_correct &= dut.tt_store_req.depth
                    == dut.search_stack_top[int'(dut.search_tt_store_issue_thread)].remaining_depth;
            end
            if (dut.search_board_issue_valid
                    && dut.search_thread_phase[int'(dut.search_board_issue_thread)] != dut.SEARCH_PHASE_REVERSE_WAIT) begin
                automatic int lmr_tid;
                lmr_tid = int'(dut.search_board_issue_thread);
                lmr_issue_legal_count[lmr_tid] = dut.search_stack_top[lmr_tid].legal_move_count;
                if (dut.search_pvs_research[lmr_tid]) begin
                    lmr_recovery_issue_seen = 1'b1;
                    lmr_full_tt_pending[lmr_tid] = 1'b1;
                    lmr_expected_child_depth[lmr_tid] = 8'(dut.search_stack_top[lmr_tid].remaining_depth - 1'b1);
                    lmr_recovery_check_pending[lmr_tid] = 1'b1;
                    check(dut.search_stack_top[lmr_tid].legal_move_count == lmr_issue_legal_count[lmr_tid],
                        "LMR recovery does not increment the legal move index at issue");
                end else if (dut.lmr_eligible(
                        dut.search_ply[lmr_tid],
                        dut.search_stack_top[lmr_tid].remaining_depth,
                        dut.search_stack_top[lmr_tid].legal_move_count,
                        dut.search_pvs_research[lmr_tid])) begin
                    lmr_reduced_issue_seen = 1'b1;
                    lmr_expected_child_depth[lmr_tid] = 8'(dut.lmr_child_depth(dut.search_board_issue_thread));
                    lmr_depth_check_pending[lmr_tid] = 1'b1;
                end
            end
            if (dut.search_board_tag_valid_pipe[dut.SEARCH_BOARD_TAG_PIPE_LEN - 1]
                    && dut.search_board_op_tag_pipe[dut.SEARCH_BOARD_TAG_PIPE_LEN - 1] != BOARD_REVERSE_MOVE_OP
                    && dut.board_update_mover_in_check) begin
                automatic int illegal_tid;
                illegal_tid = int'(dut.search_board_tag_pipe[dut.SEARCH_BOARD_TAG_PIPE_LEN - 1]);
                lmr_illegal_candidate_seen = 1'b1;
                check(dut.search_stack_top[illegal_tid].legal_move_count == lmr_issue_legal_count[illegal_tid],
                    "illegal pseudo-legal candidate does not advance m");
            end
            if (dut.repetition_req_valid) begin
                if (dut.repetition_req_ply == PlyIndex'(0)) repetition_root_request_seen = 1'b1;
                else repetition_child_request_seen = 1'b1;
            end
            if (dut.state == dut.ST_SEARCH_RUN) begin
                automatic bit all_active;

                all_active = 1'b1;
                for (int idx = 0; idx < THREAD_COUNT; idx++) begin
                    if (dut.search_thread_status[idx] != dut.SEARCH_THREAD_ACTIVE) begin
                        all_active = 1'b0;
                    end
                end
                if (all_active) begin
                    all_threads_root_active_seen = 1'b1;
                end
            end
            if (dut.state == dut.ST_SEARCH_RUN) begin
                if (dut.search_move_issue_valid) begin
                    thread_selected_active_seen[int'(dut.search_move_issue_thread)] = 1'b1;
                    thread_rr_cursor_seen[int'(dut.search_move_issue_thread)] = 1'b1;
                end
                if (dut.search_eval_issue_valid) begin
                    thread_selected_active_seen[int'(dut.search_eval_issue_thread)] = 1'b1;
                    thread_rr_cursor_seen[int'(dut.search_eval_issue_thread)] = 1'b1;
                end
                if (dut.search_tt_lookup_issue_valid && dut.tt_lookup_req_ready) begin
                    thread_selected_active_seen[int'(dut.search_tt_lookup_issue_thread)] = 1'b1;
                    thread_rr_cursor_seen[int'(dut.search_tt_lookup_issue_thread)] = 1'b1;
                end
            end
            if (dut.search_board_result_valid) begin
                thread_board_tag_seen[int'(dut.search_board_result_thread_id)] = 1'b1;
            end
            if (dut.search_move_result_valid) begin
                thread_move_tag_seen[int'(dut.search_move_result_thread_id)] = 1'b1;
            end
            if (dut.move_quiet_resp_valid) begin
                thread_move_tag_seen[int'(dut.move_quiet_resp_thread)] = 1'b1;
            end
            if (dut.search_eval_result_valid) begin
                thread_eval_tag_seen[int'(dut.search_eval_result_thread_id)] = 1'b1;
            end
            if (dut.state == dut.ST_SEARCH_RUN && dut.search_board_issue_valid) begin
                thread_move_handoff_seen[int'(dut.search_board_issue_thread)] = 1'b1;
                if (dut.board_update_op == BOARD_PUSH_NULL_OP) null_push_seen = 1'b1;
                if (dut.board_update_op == BOARD_REVERSE_MOVE_OP
                        && dut.search_stack_top[dut.search_board_issue_thread].entered_by_null)
                    null_reverse_seen = 1'b1;
            end
            if (dut.state == dut.ST_SEARCH_RUN) begin
                for (int idx = 0; idx < THREAD_COUNT; idx++) begin
                    if (dut.search_thread_phase[idx] == dut.SEARCH_PHASE_MOVE_WAIT
                            && dut.search_return_valid[idx]) begin
                        thread_eval_handoff_seen[idx] = 1'b1;
                    end
                end
            end
            if (dut.state == dut.ST_SEARCH_RUN
                    && dut.search_board_issue_valid
                    && dut.search_ply[dut.search_board_issue_thread] == PlyIndex'(0)) begin
                if (!root_push_seen[int'(dut.search_board_issue_thread)]) begin
                    root_push_seen[int'(dut.search_board_issue_thread)] = 1'b1;
                    root_first_move[int'(dut.search_board_issue_thread)] =
                        dut.move_board_bypass_valid
                            ? dut.move_board_bypass_move
                            : dut.search_pending_move[dut.search_board_issue_thread];
                end
            end
            if (dut.search_board_result_valid
                    && !root_stack_seen[int'(dut.search_board_result_thread_id)]
                    && !is_null_move(dut.search_stack_top[dut.search_board_result_thread_id].move)) begin
                if (!root_stack_seen[int'(dut.search_board_result_thread_id)]) begin
                    root_stack_seen[int'(dut.search_board_result_thread_id)] = 1'b1;
                    root_first_stack_move[int'(dut.search_board_result_thread_id)] = dut.search_stack_top[dut.search_board_result_thread_id].move;
                end
            end
        end
    end

endmodule : tb_search_controller
