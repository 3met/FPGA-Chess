// Directed search, TT, scheduler, cancellation, and terminal-result scenarios.
// Included in tb_search_controller scope.


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
        check(second_nodes <= first_nodes, {label, " second search did not search more nodes"});
        check(second_score == first_score, {label, " second search same score"});
        check(second_move == first_move, {label, " second search same best move"});
    endtask : run_tt_reuse_test

    // Install a controlled exact root entry without paying to search its depth.
    task automatic preload_root_tt(
        input Move best_move,
        input EvalScore score,
        input TTDepth depth
    );
        automatic tt_defs::TTStoreRequest publication = '0;
        automatic tt_defs::TTPhysicalEntry physical;
        automatic int index = int'(dut.tt_frontend.entry_index(dut.active_zobrist_key));
        publication.zobrist_key = dut.active_zobrist_key; publication.best_move = best_move;
        publication.score = score; publication.depth = depth; publication.bound_type = tt_defs::TT_BOUND_EXACT;
        publication.age = dut.tt_age;
        physical = dut.tt_frontend.make_way(publication);
        for (int word_index = 0; word_index < tt_defs::TT_WORDS_PER_WAY; word_index++)
            tt_memory.memory[index*tt_defs::TT_WORDS_PER_ENTRY+word_index] = physical[word_index*tt_defs::TT_WORD_BITS +: tt_defs::TT_WORD_BITS];
    endtask : preload_root_tt

    // A root hit may order the cached move but must not publish its score and
    // move without comparing the other legal root moves.
    task automatic run_root_tt_score_policy_test(input string label);
        automatic Move cached_move = make_move(Position'(12), Position'(28), PROMO_QUEEN);
        automatic Move best_move;
        automatic EvalScore score;
        automatic NodeCountType nodes;
        automatic PlyIndex saved_depth;

        new_game();
        saved_depth = PlyIndex'(dut.search_stack_top[0].remaining_depth);
        check(!dut.tt_score_cutoff_eligible(ThreadID'(0)),
            {label, " root score is cutoff-ineligible"});
        dut.search_ply[0] = PlyIndex'(1);
        dut.search_repetition_seen_before[0] = 1'b0;
        dut.search_board[0].halfmove_clock = 0;
        // These direct policy checks complete without a clock edge; restore the fixture afterward.
        dut.search_stack_top[0].remaining_depth = 5'd1;
        check(dut.tt_score_cutoff_eligible(ThreadID'(0)),
            {label, " child score remains cutoff-eligible"});
        dut.search_repetition_seen_before[0] = 1'b1;
        check(!dut.tt_score_cutoff_eligible(ThreadID'(0)),
            {label, " repeated child rejects TT score cutoffs"});
        dut.search_stack_top[0].remaining_depth = saved_depth;
        dut.search_ply[0] = PlyIndex'(0);
        dut.search_repetition_seen_before[0] = 1'b0;
        preload_root_tt(cached_move, EvalScore'(600), TTDepth'(9));
        run_search_depth_record(8'd1, {label, " root hit"},
            best_move, score, nodes);
        check(nodes != NodeCountType'(0), {label, " root hit searches legal children"});
        check(score != EvalScore'(600), {label, " root hit ignores cached score"});
    endtask : run_root_tt_score_policy_test

    // A retained TT hit must validate its real move before pruning can change
    // the node or overwrite the response context with a synthetic child probe.
    task automatic run_tt_validation_priority_test();
        new_game();
        for (int tid = 0; tid < THREAD_COUNT; tid++) begin
            automatic FullBoard saved_board = dut.search_board[tid];
            automatic SearchThreadPhase saved_phase = dut.search_thread_phase[tid];
            automatic PlyIndex saved_ply = dut.search_ply[tid];
            automatic logic saved_null_candidate = dut.search_null_candidate[tid];
            automatic logic saved_node_init_done = dut.search_node_init_done[tid];
            // Save the mutated fields without a simulator-dependent hierarchical type lookup.
            automatic logic saved_tt_checked = dut.search_stack_top[tid].tt_checked;
            automatic logic saved_has_tt_move = dut.search_stack_top[tid].has_tt_move;
            automatic Move saved_tt_move = dut.search_stack_top[tid].tt_move;
            automatic MoveOrderState saved_move_order_state = dut.search_stack_top[tid].move_order_state;
            automatic EvalScore saved_beta = dut.search_stack_top[tid].beta;
            automatic EvalScore saved_alpha = dut.search_stack_top[tid].alpha;
            automatic logic saved_unit_window = dut.search_stack_top[tid].unit_window;
            automatic logic saved_zero_window_node = dut.search_stack_top[tid].zero_window_node;
            automatic logic saved_rfp_checked = dut.search_stack_top[tid].rfp_checked;
            automatic logic saved_rfp_eligible = dut.search_stack_top[tid].rfp_eligible;
            automatic logic saved_null_beta_allowed = dut.search_stack_top[tid].null_beta_allowed;
            automatic logic saved_null_attempted = dut.search_stack_top[tid].null_attempted;
            automatic int saved_remaining_depth = int'(dut.search_stack_top[tid].remaining_depth);

            // No clock edge occurs during these scheduler policy checks.
            dut.search_thread_phase[tid] = SEARCH_PHASE_READY;
            dut.search_ply[tid] = PlyIndex'(1);
            dut.search_board[tid].halfmove_clock = HalfmoveClock'(0);
            dut.search_stack_top[tid].tt_checked = 1'b1;
            dut.search_stack_top[tid].has_tt_move = 1'b1;
            dut.search_stack_top[tid].tt_move = make_move(Position'(12), Position'(28), PROMO_QUEEN);
            dut.search_stack_top[tid].move_order_state = MOVE_ORDER_DIRECT;
            dut.search_stack_top[tid].beta = EvalScore'(100);
            dut.search_stack_top[tid].null_beta_allowed = dut.search_stack_top[tid].beta > dut.NULL_MIN_BETA;
            dut.search_stack_top[tid].alpha = EvalScore'(99);
            dut.search_stack_top[tid].unit_window = 1'b1;
            dut.search_stack_top[tid].zero_window_node = 1'b1;
            dut.search_stack_top[tid].rfp_checked = 1'b1;
            dut.search_stack_top[tid].null_attempted = 1'b0;
            dut.search_stack_top[tid].remaining_depth = dut.NULL_MINIMUM_DEPTH;
            dut.search_null_candidate[tid] = 1'b1;
            dut.search_node_init_done[tid] = 1'b1;
            dut.search_tt_validation_pending[tid] = 1'b0;
            check(dut.search_thread_null_ready(tid), "fixture permits a null probe before TT validation");
            dut.search_tt_validation_pending[tid] = 1'b1;
            check(!dut.search_thread_null_ready(tid) && dut.search_thread_move_ready(tid),
                "pending TT validation selects the real move before a null probe");

            dut.search_stack_top[tid].remaining_depth = dut.RFP_MAXIMUM_DEPTH;
            // A manually constructed probed node must include its cached entry policy.
            dut.search_stack_top[tid].rfp_eligible = dut.rfp_node_eligible(
                dut.search_stack_top[tid].remaining_depth, dut.search_stack_top[tid].zero_window_node,
                dut.search_board_in_check[tid], dut.search_stack_top[tid].beta);
            dut.search_stack_top[tid].rfp_checked = 1'b0;
            dut.search_tt_validation_pending[tid] = 1'b0;
            check(dut.search_thread_rfp_ready(tid) && dut.search_thread_eval_ready(tid),
                "fixture permits reverse futility evaluation before TT validation");
            dut.search_tt_validation_pending[tid] = 1'b1;
            check(!dut.search_thread_rfp_ready(tid) && !dut.search_thread_eval_ready(tid)
                    && dut.search_thread_move_ready(tid),
                "pending TT validation selects the real move before pruning evaluation");

            dut.search_tt_validation_pending[tid] = 1'b0;
            dut.search_board[tid] = saved_board;
            dut.search_thread_phase[tid] = saved_phase;
            dut.search_ply[tid] = saved_ply;
            dut.search_null_candidate[tid] = saved_null_candidate;
            dut.search_node_init_done[tid] = saved_node_init_done;
            dut.search_stack_top[tid].tt_checked = saved_tt_checked;
            dut.search_stack_top[tid].has_tt_move = saved_has_tt_move;
            dut.search_stack_top[tid].tt_move = saved_tt_move;
            dut.search_stack_top[tid].move_order_state = saved_move_order_state;
            dut.search_stack_top[tid].beta = saved_beta;
            dut.search_stack_top[tid].alpha = saved_alpha;
            dut.search_stack_top[tid].unit_window = saved_unit_window;
            dut.search_stack_top[tid].zero_window_node = saved_zero_window_node;
            dut.search_stack_top[tid].rfp_checked = saved_rfp_checked;
            dut.search_stack_top[tid].rfp_eligible = saved_rfp_eligible;
            dut.search_stack_top[tid].null_beta_allowed = saved_null_beta_allowed;
            dut.search_stack_top[tid].null_attempted = saved_null_attempted;
            dut.search_stack_top[tid].remaining_depth = saved_remaining_depth;
        end
    endtask : run_tt_validation_priority_test

    // Reject an impossible TT move through the real direct-validation lane and
    // require its same-cycle noisy follow-up to retain generation ownership.
    task automatic run_direct_reject_followup_test(input string label);
        automatic Move best_move;
        automatic EvalScore score;
        automatic NodeCountType nodes;

        new_game();
        direct_reject_followup_seen = 1'b0;
        direct_reject_followup_check_pending = 1'b0;
        preload_root_tt(
            make_move(Position'(12), Position'(36), PROMO_QUEEN),
            EvalScore'(0), TTDepth'(1));
        run_search_depth_record(8'd1, label, best_move, score, nodes);
        check(direct_reject_followup_seen,
            {label, " exercised rejected-direct noisy follow-up"});
    endtask : run_direct_reject_followup_test

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
        move_followup_seen = 1'b0;
        tt_response_consume_seen = 1'b0;
        tt_response_buffered_consume_seen = 1'b0;
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
        check(tt_response_consume_seen, {label, " consumed TT response in run scheduler"});
        check(tt_response_buffered_consume_seen,
            {label, " consumed a registered TT response"});
        check(thread_tt_response_cursor_seen[0], {label, " advanced TT response cursor"});
        check(all_threads_root_active_seen, {label, " initialized all threads active before root scheduling"});
        check(search_dispatch_state_seen, {label, " used concurrent search run state"});
        check(active_thread_count_full_seen, {label, " initialized active-thread count"});
        if (THREAD_COUNT > 1)
            check(active_thread_count_decrement_seen, {label, " decremented active-thread count"});
        check(store_wait_dispatch_seen, {label, " held pending TT store in run scheduler"});
        check(store_wait_issue_seen, {label, " issued pending TT store from store-wait phase"});
        check(return_pending_dispatch_seen, {label, " held pending child return in run scheduler"});
        check(move_followup_seen,
            {label, " chained a move-order operation on its response cycle"});
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
            check(dut.search_thread_phase[idx] == SEARCH_PHASE_DONE,
                $sformatf("%s thread %0d lifecycle done", label, idx));
            check(!dut.search_board_inflight[idx],
                $sformatf("%s thread %0d board in-flight cleared", label, idx));
            check(!dut.search_move_inflight[idx],
                $sformatf("%s thread %0d move in-flight cleared", label, idx));
            check(!dut.search_tt_lookup_inflight[idx],
                $sformatf("%s thread %0d TT lookup in-flight cleared", label, idx));
            check(dut.search_active_thread_count == 0,
                $sformatf("%s active-thread count cleared after thread %0d checks", label, idx));
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

    // Hold an accepted probe through Kill and reuse its thread on another board.
    task automatic kill_and_restart_with_pending_tt();
        automatic EngineControllerRequest request = zero_request();
        automatic int wait_cycles = 0;
        new_game();
        tt_memory_enabled = 1'b0;
        request.operation = ENGINE_CTRL_SEARCH_DEPTH; request.depth_limit = 1;
        pulse_request(request, "pending TT search");
        while (!dut.search_tt_lookup_inflight[0] && wait_cycles < 10000) begin
            do_clock(1); wait_cycles++;
        end
        check(dut.search_tt_lookup_inflight[0], "search has an accepted delayed probe");
        request.operation = ENGINE_CTRL_KILL;
        pulse_request(request, "pending TT kill"); wait_response("pending TT kill");
        apply_game_move(make_move(Position'(12), Position'(28), PROMO_QUEEN), "change board after kill");
        request.operation = ENGINE_CTRL_SEARCH_DEPTH; request.depth_limit = 1;
        pulse_request(request, "pending TT restart");
        wait_cycles = 0;
        while (!dut.search_thread_tt_lookup_ready(0) && wait_cycles < 10000) begin
            do_clock(1); wait_cycles++;
        end
        check(dut.search_thread_tt_lookup_ready(0), "restarted thread reaches a different position probe");
        do_clock(80);
        check(!dut.search_tt_lookup_inflight[0], "thread does not reuse an outstanding canceled probe");
        tt_memory_enabled = 1'b1;
        while (!dut.tt_lookup_resp_valid) do_clock(1);
        do_clock(1);
        check(!dut.search_tt_response_pending[0], "old probe response is discarded after restart");
        wait_response("pending TT restarted search");
        check(!resp.error && resp.completed_depth == 1, "search resumes after canceled probe drains");
    endtask

    task automatic kill_active_search(input string label);
        automatic EngineControllerRequest request = zero_request();
        automatic EngineControllerRequest kill_request = zero_request();
        automatic Move partial_best_move;
        automatic Move partial_ponder_move;
        automatic EvalScore partial_score;
        automatic logic [7:0] cached_depth;
        automatic logic nnue_metadata_clear = 1'b1;
        automatic int completion_wait_cycles = 0;

        request.operation = ENGINE_CTRL_SEARCH_DEPTH;
        request.depth_limit = 8'd4;
        pulse_request(request, {label, " start"});
        // Interrupt after a deeper iteration has an exact resolved root
        // candidate. Its move and score may be published without claiming that
        // the deeper iteration itself completed.
        while (!(dut.search_completed_depth != 0
                && dut.search_thread_phase[0] != SEARCH_PHASE_DONE
                && dut.search_root_has_completed_move[0]
                && dut.search_root_best_exact[0])
                && completion_wait_cycles < 200_000) begin
            do_clock(1);
            completion_wait_cycles += 1;
        end
        check(dut.search_completed_depth != 0, {label, " completed an iteration before kill"});
        check(dut.search_root_has_completed_move[0],
            {label, " resolved a root child in the interrupted deeper iteration"});
        check(dut.search_root_best_exact[0],
            {label, " partial deeper root candidate is exact"});
        partial_best_move = dut.search_best_move[0];
        partial_ponder_move = dut.search_ponder_move[0];
        partial_score = dut.search_root_best_score[0];
        cached_depth = dut.search_completed_depth;

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
        check(resp.best_move == partial_best_move, {label, " kill publishes exact partial best move"});
        check(resp.ponder_move.from_pos == partial_ponder_move.from_pos
                && resp.ponder_move.to_pos == partial_ponder_move.to_pos
                && (is_null_move(partial_ponder_move)
                    || resp.ponder_move.promo_piece == partial_ponder_move.promo_piece),
            {label, " kill publishes exact partial ponder move"});
        check(resp.score == partial_score, {label, " kill publishes exact partial score"});
        check(resp.completed_depth == cached_depth, {label, " kill keeps the atomic completed depth"});
        check(dut.nnue_update_idle && dut.nnue_eval_ready,
            {label, " flushes queued NNUE work"});
        for (int tid = 0; tid < THREAD_COUNT; tid++) begin
            nnue_metadata_clear &= !dut.nnue_plan_pending[tid];
            nnue_metadata_clear &= !dut.nnue_state_valid[tid];
            check(!dut.search_board_inflight[tid],
                $sformatf("%s thread %0d board in-flight canceled", label, tid));
            check(!dut.search_move_inflight[tid],
                $sformatf("%s thread %0d move in-flight canceled", label, tid));
            check(!dut.search_tt_lookup_inflight[tid],
                $sformatf("%s thread %0d TT lookup in-flight canceled", label, tid));
            check(!dut.search_return_was_scout[tid],
                $sformatf("%s thread %0d PVS scout return canceled", label, tid));
            check(!dut.search_return_was_reduced[tid],
                $sformatf("%s thread %0d reduced return canceled", label, tid));
            check(!dut.search_pvs_research[tid],
                $sformatf("%s thread %0d PVS re-search canceled", label, tid));
            check(dut.search_thread_phase[tid] == SEARCH_PHASE_IDLE,
                $sformatf("%s thread %0d phase idle after kill", label, tid));
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

    // Cancel after a real early quiet has entered its child while the parent
    // is still writing, then verify no ownership or read response survives.
    task automatic kill_early_generation();
        automatic EngineControllerRequest request = zero_request();
        automatic int cycles = 0;
        request.operation = ENGINE_CTRL_SEARCH_DEPTH;
        request.depth_limit = 8'd6;
        pulse_request(request, "start early generation kill");
        while (!(dut.search_generation_inflight[0]
                    && dut.search_ply[0] != dut.search_generation_ply[0])
                && cycles < 20000) begin
            do_clock();
            cycles++;
        end
        check(cycles < 20000, "kill reaches active parent generation and child preparation");
        request = zero_request();
        request.operation = ENGINE_CTRL_KILL;
        req = request;
        req_valid = 1'b1;
        #1;
        check(req_ready, "overlapped generation kill is accepted");
        do_clock();
        req_valid = 1'b0;
        req = zero_request();
        wait_response("overlapped generation kill");
        check(!resp.error && resp.end_reason == ENGINE_END_KILLED,
            "overlapped generation returns killed completion");
        for (int tid = 0; tid < THREAD_COUNT; tid++)
            check(!dut.search_generation_inflight[tid]
                    && !dut.search_move_inflight[tid], "kill clears generation and read ownership");
        do_clock(8);
        check(!dut.move_pop_resp_valid && !dut.move_cmd_resp_valid && !dut.move_quiet_resp_valid,
            "kill leaves no late move responses");
    endtask

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

    // Queen promotion stalemates here; a winning search must choose another piece.
    task automatic check_underpromotion_publication();
        automatic Move best_move;
        automatic EvalScore score;
        automatic NodeCountType nodes;
        new_game(); clear_start_position("underpromotion");
        set_tile(WHITE_KING, Position'(42), "underpromotion white king c6");
        set_tile(WHITE_PAWN, Position'(50), "underpromotion pawn c7");
        set_tile(BLACK_KING, Position'(48), "underpromotion black king a7");
        observe_underpromotion = 1; underpromotion_store_seen = 0;
        run_search_depth_record(3, "underpromotion search", best_move, score, nodes);
        observe_underpromotion = 0;
        check(best_move.from_pos == Position'(50) && best_move.to_pos == Position'(58)
            && best_move.promo_piece != PROMO_QUEEN && score > 0, "search avoids queen-promotion stalemate");
        check(underpromotion_store_seen
            && underpromotion_store.best_move.from_pos == underpromotion_store.best_move.to_pos
            && underpromotion_store.score == score && underpromotion_store.bound_type == TT_BOUND_EXACT,
            "underpromotion keeps TT score and bound while omitting the move");
    endtask

    // Require the exact six-ply losing mate after a complete search, including
    // a second search that reuses the table populated by the first one.
    task automatic run_fifty_move_mate_search(input string label);
        automatic EngineControllerRequest request = zero_request();
        request.operation = ENGINE_CTRL_SEARCH_DEPTH;
        // TT ordering and selective reductions can defer the six-ply mate beyond
        // nominal depth six; allow a full tactical horizon with the three-way table.
        request.depth_limit = 8'd10;
        pulse_request(request, label);
        wait_response(label, 2000000);
        $display("Mate regression %s: score=%0d depth=%0d move=%0d-%0d nodes=%0d",
            label, resp.score, resp.completed_depth, resp.best_move.from_pos,
            resp.best_move.to_pos, resp.nodes_count);
        check(!resp.error, {label, " no error"});
        check(resp.score == -MATE_SCORE + EvalScore'(6), {label, " mate in three for Black"});
        check(resp.best_move.from_pos == Position'(51)
                && (resp.best_move.to_pos == Position'(61)
                    || resp.best_move.to_pos == Position'(45)),
            {label, " White chooses a move that delays mate"});
        check(resp.end_reason == ENGINE_END_DEPTH_LIMIT, {label, " end reason"});
    endtask : run_fifty_move_mate_search

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
        check(resp.nodes_count <= NodeCountType'(1001),
            {label, " registered budget check allows at most one extra committed node"});
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
        request.remaining_time = TimeType'(0);
        request.increment = TimeType'(0);
        pulse_request(request, label);
        wait_response(label);
        check(!resp.error, {label, " no error"});
        check(resp.completed_depth == 8'd0, {label, " no completed depth"});
        check(resp.end_reason == ENGINE_END_TIME_LIMIT, {label, " end reason"});
    endtask : run_clock_budget_search
