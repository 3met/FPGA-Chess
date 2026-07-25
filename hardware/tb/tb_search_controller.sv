`timescale 1ns/1ns

import general_chess_defs::*;
import board_update_pipeline_defs::*;
import engine_defs::*;
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

    function automatic EngineControllerRequest zero_request();
        automatic EngineControllerRequest request;

        request = EngineControllerRequest'('0);
        request.operation = ENGINE_CTRL_IDLE;
        request.direct_board_op = BOARD_IDLE_OP;
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

    task automatic drive_request_no_ready_check(input EngineControllerRequest request);
        req = request;
        req_valid = 1'b1;
        do_clock(1);
        req_valid = 1'b0;
        req = zero_request();
    endtask : drive_request_no_ready_check

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

        request.operation = ENGINE_CTRL_NEW_GAME;
        hold_request_until_ready(request, "new game");
        check(!resp.error, "new game response has no error");
    endtask : new_game

    task automatic make_direct_move(input Move move, input string label);
        automatic EngineControllerRequest request = zero_request();

        request.operation = ENGINE_CTRL_DIRECT_BOARD;
        request.direct_board_op = BOARD_COMMIT_MOVE_OP;
        request.move = move;
        hold_request_until_ready(request, label);
        check(!resp.error, {label, " response has no error"});
    endtask : make_direct_move

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
        check(resp.nodes_count > NodeCountType'(20), {label, " searches below root"});
        check(resp.completed_depth == depth, {label, " completed requested depth"});
        check(resp.end_reason == ENGINE_END_DEPTH_LIMIT, {label, " end reason"});
        check(!(resp.best_move.from_pos == Position'(0) && resp.best_move.to_pos == Position'(0)), {label, " best move is non-null"});
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
        check(first_nodes > NodeCountType'(20), {label, " first search visited tree"});

        tt_lookup_count = 0;
        tt_store_count = 0;
        run_search_depth_record(8'd1, {label, " second search"}, second_move, second_score, second_nodes);
        check(tt_lookup_count > 0, {label, " second search issued TT lookup"});
        check(tt_lookup_count >= first_lookup_count, {label, " second search issued repeated TT lookups"});
        check(second_nodes < first_nodes, {label, " second search searched fewer nodes"});
        check(second_score == first_score, {label, " second search same score"});
        check(second_move == first_move, {label, " second search same best move"});
    endtask : run_tt_reuse_test

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
        end
    endtask : clear_root_push_seen

    task automatic run_thread_id_usage_test(input string label);
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
            check(!(dut.search_thread_completed_best_move[idx].from_pos == Position'(0)
                    && dut.search_thread_completed_best_move[idx].to_pos == Position'(0)),
                $sformatf("%s thread %0d completed best move non-null found %0d->%0d",
                    label,
                    idx,
                    dut.search_thread_completed_best_move[idx].from_pos,
                    dut.search_thread_completed_best_move[idx].to_pos));
        end
    endtask : run_thread_id_usage_test

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

        request.operation = ENGINE_CTRL_SEARCH_DEPTH;
        request.depth_limit = 8'd4;
        pulse_request(request, {label, " start"});
        do_clock(80);

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
        for (int tid = 0; tid < THREAD_COUNT; tid++) begin
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
        for (int idx = 0; idx < dut.SEARCH_BOARD_TAG_PIPE_LEN; idx++) begin
            check(!dut.search_board_tag_valid_pipe[idx],
                $sformatf("%s board tag pipe %0d canceled", label, idx));
        end
        for (int idx = 0; idx < dut.SEARCH_MOVE_TAG_PIPE_LEN; idx++) begin
            check(!dut.search_move_tag_valid_pipe[idx],
                $sformatf("%s move tag pipe %0d canceled", label, idx));
        end
        for (int idx = 0; idx < dut.SEARCH_EVAL_TAG_PIPE_LEN; idx++) begin
            check(!dut.search_eval_tag_valid_pipe[idx],
                $sformatf("%s eval tag pipe %0d canceled", label, idx));
        end
    endtask : kill_active_search

    task automatic set_tile(input Tile tile, input Position pos, input string label);
        automatic EngineControllerRequest request = zero_request();
        automatic logic [3:0] tile_bits;

        request.operation = ENGINE_CTRL_DIRECT_BOARD;
        request.direct_board_op = BOARD_SET_TILE_OP;
        request.move.to_pos = pos;
        tile_bits = (tile.piece_type == NULL_PIECE) ? 4'h0 : tile;
        request.board_wr_data = {3'b000, tile_bits};
        hold_request_until_ready(request, label);
        check(!resp.error, {label, " no error"});
    endtask : set_tile

    task automatic set_turn(input Color color, input string label);
        automatic EngineControllerRequest request = zero_request();

        request.operation = ENGINE_CTRL_DIRECT_BOARD;
        request.direct_board_op = BOARD_SET_TURN_OP;
        request.board_wr_data = {6'b000000, color};
        hold_request_until_ready(request, label);
        check(!resp.error, {label, " no error"});
    endtask : set_turn

    task automatic set_castle_perms(input CastlePerms castle_perms, input string label);
        automatic EngineControllerRequest request = zero_request();

        request.operation = ENGINE_CTRL_DIRECT_BOARD;
        request.direct_board_op = BOARD_SET_CASTLE_PERMS_OP;
        request.board_wr_data = {3'b000, castle_perms};
        hold_request_until_ready(request, label);
        check(!resp.error, {label, " no error"});
    endtask : set_castle_perms

    task automatic set_en_passant(input logic has_ep, input BoardFile ep_file, input string label);
        automatic EngineControllerRequest request = zero_request();

        request.operation = ENGINE_CTRL_DIRECT_BOARD;
        request.direct_board_op = BOARD_SET_EN_PASSANT_OP;
        request.board_wr_data = {3'b000, ep_file, has_ep};
        hold_request_until_ready(request, label);
        check(!resp.error, {label, " no error"});
    endtask : set_en_passant

    task automatic set_halfmove_clock(input HalfmoveClock halfmove_clock, input string label);
        automatic EngineControllerRequest request = zero_request();

        request.operation = ENGINE_CTRL_DIRECT_BOARD;
        request.direct_board_op = BOARD_SET_HALFMOVE_CLOCK_OP;
        request.board_wr_data = halfmove_clock;
        hold_request_until_ready(request, label);
        check(!resp.error, {label, " no error"});
    endtask : set_halfmove_clock

    task automatic clear_board(input string label);
        for (int pos = 0; pos < 64; pos++) begin
            set_tile(EMPTY_TILE, Position'(pos), $sformatf("%s clear square %0d", label, pos));
        end
        set_castle_perms(CastlePerms'(4'b0000), {label, " clear castle perms"});
        set_en_passant(1'b0, BoardFile'(0), {label, " clear en passant"});
        set_halfmove_clock(HalfmoveClock'(0), {label, " clear halfmove clock"});
    endtask : clear_board

    task automatic setup_kings_only();
        for (int pos = 0; pos < 64; pos++) begin
            if (pos != 4 && pos != 60) begin
                set_tile(EMPTY_TILE, Position'(pos), $sformatf("clear square %0d", pos));
            end
        end
        set_castle_perms(CastlePerms'(4'b0000), "clear castle perms for kings only");
        set_en_passant(1'b0, BoardFile'(0), "clear en passant for kings only");
    endtask : setup_kings_only

    task automatic setup_castling_perft_position();
        automatic CastlePerms castle_perms;

        castle_perms = CastlePerms'('0);
        castle_perms.white_kingside = 1'b1;
        clear_board("castling perft");
        set_tile(WHITE_KING, Position'(4), "castling perft white king e1");
        set_tile(WHITE_ROOK, Position'(7), "castling perft white rook h1");
        set_tile(BLACK_KING, Position'(56), "castling perft black king a8");
        set_castle_perms(castle_perms, "castling perft white kingside right");
        set_turn(WHITE, "castling perft white to move");
    endtask : setup_castling_perft_position

    task automatic setup_en_passant_perft_position();
        clear_board("en passant perft");
        set_tile(WHITE_KING, Position'(36), "en passant perft white king e5");
        set_tile(WHITE_PAWN, Position'(37), "en passant perft white pawn f5");
        set_tile(BLACK_PAWN, Position'(38), "en passant perft black pawn g5");
        set_tile(BLACK_KING, Position'(56), "en passant perft black king a8");
        set_en_passant(1'b1, BoardFile'(6), "en passant perft target g-file");
        set_turn(WHITE, "en passant perft white to move");
    endtask : setup_en_passant_perft_position

    task automatic setup_promotion_perft_position();
        clear_board("promotion perft");
        set_tile(WHITE_KING, Position'(4), "promotion perft white king e1");
        set_tile(WHITE_PAWN, Position'(48), "promotion perft white pawn a7");
        set_tile(BLACK_KING, Position'(60), "promotion perft black king e8");
        set_turn(WHITE, "promotion perft white to move");
    endtask : setup_promotion_perft_position

    task automatic setup_stalemate_position();
        clear_board("stalemate perft");
        set_tile(WHITE_KING, Position'(53), "stalemate white king f7");
        set_tile(WHITE_QUEEN, Position'(46), "stalemate white queen g6");
        set_tile(BLACK_KING, Position'(63), "stalemate black king h8");
        set_turn(BLACK, "stalemate black to move");
    endtask : setup_stalemate_position

    task automatic setup_checkmate_position();
        clear_board("checkmate perft");
        set_tile(WHITE_KING, Position'(45), "checkmate white king f6");
        set_tile(WHITE_QUEEN, Position'(54), "checkmate white queen g7");
        set_tile(BLACK_KING, Position'(63), "checkmate black king h8");
        set_turn(BLACK, "checkmate black to move");
    endtask : setup_checkmate_position

    task automatic setup_rook_takes_queen();
        setup_kings_only();
        set_tile(WHITE_ROOK, Position'(0), "place white rook a1");
        set_tile(BLACK_QUEEN, Position'(56), "place black queen a8");
        set_castle_perms(CastlePerms'(4'b0000), "clear castle perms");
        set_turn(WHITE, "white to move");
    endtask : setup_rook_takes_queen

    task automatic setup_black_rook_takes_queen();
        setup_kings_only();
        set_tile(BLACK_ROOK, Position'(56), "place black rook a8");
        set_tile(WHITE_QUEEN, Position'(0), "place white queen a1");
        set_castle_perms(CastlePerms'(4'b0000), "clear castle perms for black capture");
        set_turn(BLACK, "black to move");
    endtask : setup_black_rook_takes_queen

    task automatic setup_pinned_rook_position();
        clear_board("pinned-rook search");
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
        make_direct_move(make_move(Position'(6), Position'(21), PROMO_QUEEN), {label, " g1f3"});
        make_direct_move(make_move(Position'(62), Position'(45), PROMO_QUEEN), {label, " g8f6"});
        make_direct_move(make_move(Position'(21), Position'(6), PROMO_QUEEN), {label, " f3g1"});
        make_direct_move(make_move(Position'(45), Position'(62), PROMO_QUEEN), {label, " f6g8"});
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

        request.operation = ENGINE_CTRL_SEARCH_NODES;
        request.node_limit = NodeCountType'(1);
        pulse_request(request, label);
        wait_response(label);
        check(!resp.error, {label, " no error"});
        check(resp.nodes_count >= NodeCountType'(1), {label, " reached node limit"});
        check(resp.completed_depth == 8'd0, {label, " no partial iteration depth reported complete"});
        check(resp.end_reason == ENGINE_END_NODE_LIMIT, {label, " end reason"});
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

        check(dut.lmr_table_value(0, 0) == 8'd1, "LMR default constant rounds 0.75 to one ply");
        check(dut.lmr_table_value(1, 1) == 8'd1, "LMR Q8 division and rounding at bucket 1/1");
        check(dut.lmr_table_value(2, 2) == 8'd2, "LMR Q8 division and rounding at bucket 2/2");
        check(dut.lmr_table_value_for_params(128, 256, 1, 1) == 8'd1,
            "LMR non-default half-ply offset rounds the complete curve once");
        check(dut.lmr_table_value_for_params(0, 256, 2, 2) == 8'd2,
            "LMR non-default denominator preserves Q8 curve scaling");
        check(dut.LMR_DEPTH_BUCKETS == 5, "LMR generates only reachable default depth buckets");
        check(dut.LMR_TABLE_MAX_VALUE == 8'd6, "LMR default table maximum is six plies");
        check(dut.LMR_TABLE_VALUE_BITS == 3, "LMR default table values require three significant bits");
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
        check(dut.lmr_eligible(PlyIndex'(1), 8'd3, 8'd2, 1'b0),
            "LMR all-moves policy includes captures and promotions");
        check(dut.lmr_eligible(PlyIndex'(1), 8'd3, 8'd2, 1'b0),
            "LMR all-moves policy includes checks and evasions");
        check(!dut.lmr_eligible(PlyIndex'(1), 8'd3, 8'd2, 1'b1), "LMR excludes full-depth recovery");
        check(dut.search_needs_research(1'b1, 1'b1, EvalScore'(20), EvalScore'(10), EvalScore'(20)),
            "LMR verifies a reduced beta cutoff at full depth");
        check(!dut.search_needs_research(1'b1, 1'b0, EvalScore'(20), EvalScore'(10), EvalScore'(20)),
            "ordinary PVS beta cutoff does not require full-depth recovery");
        force dut.search_stack_top[0].remaining_depth = 5'd3;
        force dut.search_stack_top[0].legal_move_count = 8'hff;
        check(dut.lmr_child_depth(ThreadID'(0)) <= 8'd2, "LMR clamps reduction to d-1 at saturated move count");
        release dut.search_stack_top[0].remaining_depth;
        release dut.search_stack_top[0].legal_move_count;
        for (int depth_bucket = 0; depth_bucket < dut.LMR_DEPTH_BUCKETS; depth_bucket++) begin
            for (int move_bucket = 1; move_bucket < 8; move_bucket++) begin
                check(dut.LMR_TABLE[depth_bucket][move_bucket] >= dut.LMR_TABLE[depth_bucket][move_bucket - 1],
                    $sformatf("LMR table move monotonic depth bucket %0d move bucket %0d", depth_bucket, move_bucket));
            end
        end
        for (int depth_bucket = 1; depth_bucket < dut.LMR_DEPTH_BUCKETS; depth_bucket++) begin
            for (int move_bucket = 0; move_bucket < 8; move_bucket++) begin
                check(dut.LMR_TABLE[depth_bucket][move_bucket] >= dut.LMR_TABLE[depth_bucket - 1][move_bucket],
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

        // Opposite-direction moves h2h4 and h5h3 must have distinct mask identities.
        new_game();
        make_direct_move(make_move(Position'(12), Position'(20), PROMO_QUEEN), "perft regression e2e3");
        make_direct_move(make_move(Position'(48), Position'(40), PROMO_QUEEN), "perft regression a7a6");
        make_direct_move(make_move(Position'(3), Position'(39), PROMO_QUEEN), "perft regression d1h5");
        make_direct_move(make_move(Position'(40), Position'(32), PROMO_QUEEN), "perft regression a6a5");
        run_perft(8'd1, NodeCountType'(44), "queen sortie perft depth 1");

        new_game();
        setup_kings_only();
        run_perft(8'd1, NodeCountType'(5), "kings-only perft depth 1");
        run_search_depth(8'd4, "kings-only LMR search depth 4");
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

        new_game();
        setup_en_passant_perft_position();
        run_perft(8'd1, NodeCountType'(8), "en passant perft depth 1");

        new_game();
        setup_promotion_perft_position();
        run_perft(8'd1, NodeCountType'(9), "promotion perft depth 1");

        new_game();
        setup_stalemate_position();
        run_perft(8'd1, NodeCountType'(0), "stalemate perft depth 1");
        run_stalemate_search("stalemate search");

        new_game();
        setup_checkmate_position();
        run_perft(8'd1, NodeCountType'(0), "checkmate perft depth 1");
        run_checkmate_search("checkmate search");

        new_game();
        make_direct_move(make_move(Position'(12), Position'(28), PROMO_QUEEN), "make e2e4");
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

        new_game();
        run_tt_reuse_test("startpos TT reuse");
        run_shallow_tt_move_ordering_test("shallow TT move ordering");

        new_game();
        run_thread_id_usage_test("thread ID scheduled search");

        new_game();
        run_node_limit_search("node-limited search");
        run_fixed_time_search("zero fixed-time search");
        run_clock_budget_search("zero clock-budget search");

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
                check(dut.stat_tt_lookups == 40'd0, "new search resets TT lookup statistics");
                check(dut.stat_tt_hits == 40'd0, "new search resets TT hit statistics");
                check(dut.stat_cache_lookups == 40'd0, "new search resets cache lookup statistics");
                check(dut.stat_cache_hits == 40'd0, "new search resets cache hit statistics");
                for (int tid = 0; tid < THREAD_COUNT; tid++) begin
                    for (int phase = 0; phase < ENGINE_STAT_PHASE_COUNT_VALUE; phase++) begin
                        check(dut.stat_phase_cycles[tid][phase] == 40'd0,
                            "new search resets phase statistics");
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
            for (int idx = 0; idx < THREAD_COUNT; idx++) begin
                if (lmr_depth_check_pending[idx]) begin
                    check(8'(dut.search_pending_child_depth[idx]) == lmr_expected_child_depth[idx],
                        "LMR registers the expected reduced child depth before board completion");
                    lmr_depth_check_pending[idx] = 1'b0;
                end
                if (lmr_recovery_check_pending[idx]) begin
                    check(8'(dut.search_pending_child_depth[idx]) == lmr_expected_child_depth[idx],
                        "LMR recovery restores full child depth without another reduction");
                    lmr_recovery_check_pending[idx] = 1'b0;
                end
                if (dut.search_aspiration_active && !aspiration_window_seen) begin
                    aspiration_window_seen = 1'b1;
                    check(dut.search_root_beta - dut.search_root_alpha == EvalScore'(1024),
                        "aspiration window is eight pawns wide");
                    check(dut.search_root_alpha == dut.search_completed_score - EvalScore'(512)
                            && dut.search_root_beta == dut.search_completed_score + EvalScore'(512),
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
                    if (dut.search_board_dispatch_cursor == expected_next_thread(idx)) begin
                        thread_board_cursor_seen[idx] = 1'b1;
                    end
                end
                if (dut.search_move_inflight[idx]) begin
                    thread_move_inflight_seen[idx] = 1'b1;
                    if (dut.search_move_dispatch_cursor == expected_next_thread(idx)) begin
                        thread_move_cursor_seen[idx] = 1'b1;
                    end
                end
                if (dut.search_eval_inflight[idx]) begin
                    thread_eval_inflight_seen[idx] = 1'b1;
                    if (dut.search_eval_dispatch_cursor == expected_next_thread(idx)) begin
                        thread_eval_cursor_seen[idx] = 1'b1;
                    end
                end
                if (dut.search_tt_lookup_inflight[idx]) begin
                    thread_tt_lookup_inflight_seen[idx] = 1'b1;
                    if (dut.search_tt_lookup_dispatch_cursor == expected_next_thread(idx)) begin
                        thread_tt_lookup_cursor_seen[idx] = 1'b1;
                    end
                end
                if (dut.search_tt_store_inflight[idx]) begin
                    thread_tt_store_inflight_seen[idx] = 1'b1;
                end
                if (thread_tt_store_inflight_seen[idx]
                        && dut.search_tt_store_dispatch_cursor == expected_next_thread(idx)) begin
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
                check(dut.tt_lookup_req.depth == dut.search_stack_top[int'(dut.tt_lookup_req.thread_id)].remaining_depth,
                    "TT lookup uses the node actual remaining depth");
                if (dut.search_stack_top[int'(dut.tt_lookup_req.thread_id)].count_move_on_return) begin
                    if (dut.search_stack_top[int'(dut.tt_lookup_req.thread_id)].remaining_depth
                            < dut.search_target_depth - 5'(dut.search_ply[int'(dut.tt_lookup_req.thread_id)])) begin
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
                check(dut.tt_store_req.depth == dut.search_stack_top[int'(dut.search_tt_store_issue_thread)].remaining_depth,
                    "TT store uses the node actual remaining depth");
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
            if (dut.search_board_result_valid
                    && dut.search_board_op_tag_pipe[dut.SEARCH_BOARD_TAG_PIPE_LEN - 1] != BOARD_REVERSE_MOVE_OP
                    && dut.board_update_mover_in_check) begin
                automatic int illegal_tid;
                illegal_tid = int'(dut.search_board_result_thread_id);
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
            if (dut.search_eval_result_valid) begin
                thread_eval_tag_seen[int'(dut.search_eval_result_thread_id)] = 1'b1;
            end
            if (dut.state == dut.ST_SEARCH_RUN && dut.search_board_issue_valid) begin
                thread_move_handoff_seen[int'(dut.search_board_issue_thread)] = 1'b1;
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
