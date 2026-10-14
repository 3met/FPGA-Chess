// Handshake, state-ownership, NNUE reference, and bounded-completion monitors.
// Included in tb_search_controller scope.


    // Rebuild the two-perspective accumulator directly from a board so special
    // move deltas can be checked against their complete positional state.
    function automatic logic [
        NNUE_STATE_VALUE_COUNT * NNUE_ACCUMULATOR_BITS-1:0]
        reference_nnue_state(input FullBoard board);
        automatic logic [
            NNUE_STATE_VALUE_COUNT * NNUE_ACCUMULATOR_BITS-1:0] expected = '0;

        for (int perspective = 0; perspective < 2; perspective++) begin
            for (int lane = 0; lane < NNUE_ACCUMULATOR_COUNT; lane++) begin
                automatic NnueAccumulator sum = NnueAccumulator'({{
                    (NNUE_ACCUMULATOR_BITS-NNUE_ACCUMULATOR_BIAS_BITS){1'b0}},
                    dut.nnue_evaluator.accumulator_bias[lane][
                        NNUE_ACCUMULATOR_BIAS_BITS-1:0]});
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
    // Observe actual handshakes: no forced responses or bypassed generators.
    always @(posedge clk) begin
        // Check the prior pop's metadata after its pending register has updated.
        for (int tid = 0; tid < THREAD_COUNT; tid++) begin
            if (rst_n && lmr_bucket_check_pending[tid]) begin
                assert (dut.search_pending_move_bucket[tid] == lmr_expected_bucket[tid])
                    else $fatal(1, "LMR pending move lost its bucket tag");
            end
            lmr_bucket_check_pending[tid] = 1'b0;
        end
        if (rst_n && dut.state == CTRL_SEARCH_RUN && !dut.search_stop_requested()
                && dut.move_pop_resp_valid && dut.move_pop_resp_found) begin
            lmr_bucket_check_pending[dut.move_pop_resp_thread] = 1'b1;
            lmr_expected_bucket[dut.move_pop_resp_thread] = dut.move_pop_resp_bucket;
            if (dut.search_board_issue_valid && dut.move_board_bypass_valid) begin
                assert (dut.search_board_issue_bucket == dut.move_pop_resp_bucket)
                    else $fatal(1, "LMR immediate board issue used a stale bucket tag");
            end
        end
        if (direct_reject_followup_check_pending) begin
            check(dut.search_generation_inflight[direct_reject_followup_thread],
                "direct rejection preserves noisy generation tracking");
            check(dut.search_generation_ply[direct_reject_followup_thread]
                    == direct_reject_followup_ply,
                "direct rejection preserves noisy generation ply");
            check(dut.move_generator.live_active[0]
                    && dut.move_generator.live_thread[0] == direct_reject_followup_thread
                    && dut.move_generator.live_ply[0] == direct_reject_followup_ply,
                "direct rejection follow-up matches the actual noisy generator");
            direct_reject_followup_check_pending = 1'b0;
        end
        if (rst_n && dut.state == CTRL_SEARCH_RUN) begin
            for (int lane = 0; lane < 2; lane++) begin
                if (dut.move_generator.live_active[lane]) begin
                    assert (dut.search_generation_inflight[
                            dut.move_generator.live_thread[lane]])
                        else $fatal(1, "live generator lacks controller ownership");
                    assert (dut.search_generation_ply[
                            dut.move_generator.live_thread[lane]]
                            == dut.move_generator.live_ply[lane])
                        else $fatal(1, "live generator/controller ply mismatch");
                end
            end
            if (dut.move_cmd_resp_valid && !dut.move_cmd_resp_direct_valid
                    && dut.move_cmd_valid && dut.move_cmd_ready
                    && dut.move_cmd == move_generator_defs::MOVE_GEN_GENERATE_NOISY
                    && dut.move_cmd_thread == dut.move_cmd_resp_thread) begin
                direct_reject_followup_seen = 1'b1;
                direct_reject_followup_check_pending = 1'b1;
                direct_reject_followup_thread = dut.move_cmd_thread;
                direct_reject_followup_ply = dut.move_cmd_ply;
            end
            if (dut.move_cmd_valid && dut.move_cmd_ready
                    && dut.move_cmd == move_generator_defs::MOVE_GEN_GENERATE_NOISY)
                last_read_bucket[dut.move_cmd_thread][dut.move_cmd_ply] = move_generator_defs::GOOD_NOISY_HIGH_BUCKET;
            if (dut.move_quiet_cmd_valid && dut.move_quiet_cmd_ready) begin
                assert (dut.move_generator.reader.cache_state[dut.move_quiet_cmd_thread].phase
                        == move_generator_defs::MOVE_MEMORY_WAIT_QUIET)
                    else $fatal(1, "quiet generation began before good noisy exhaustion");
            end
            if (dut.move_pop_resp_valid && dut.move_pop_resp_found) begin
                assert (dut.move_pop_resp_bucket <= last_read_bucket[dut.move_pop_resp_thread][dut.move_pop_resp_ply])
                    else $fatal(1, "search returned to a higher bucket after serving a lower one");
                last_read_bucket[dut.move_pop_resp_thread][dut.move_pop_resp_ply] = dut.move_pop_resp_bucket;
            end
            if (dut.move_pop_resp_valid && dut.move_pop_resp_found)
                for (int lane = 0; lane < 2; lane++) begin
                    if (dut.move_generator.live_active[lane]
                            && dut.move_generator.live_thread[lane] == dut.move_pop_resp_thread
                            && dut.move_generator.live_ply[lane] == dut.move_pop_resp_ply) begin
                        assert ((lane == 0 && dut.move_pop_resp_bucket == move_generator_defs::GOOD_NOISY_HIGH_BUCKET)
                                || (lane == 1 && dut.move_pop_resp_bucket == move_generator_defs::QUIET_HIGHEST_BUCKET))
                            else $fatal(1, "early search read escaped the highest unfinished bucket");
                        if (lane == 0) early_noisy_reads++;
                        else early_quiet_reads++;
                    end
                end
            for (int tid = 0; tid < THREAD_COUNT; tid++) begin
                if (dut.move_generator.reader.pointer_load_issue[tid]) repaired_parents++;
                if (dut.search_generation_inflight[tid]
                        && dut.search_ply[tid] != dut.search_generation_ply[tid]) begin
                    assert (dut.search_ply[tid] == dut.search_generation_ply[tid] + PlyIndex'(1))
                        else $fatal(1, "descended past unfinished parent storage");
                    assert (!(dut.move_cmd_valid && dut.move_cmd_ready && dut.move_cmd_thread == ThreadID'(tid))
                        && !(dut.move_quiet_cmd_valid && dut.move_quiet_cmd_ready
                            && dut.move_quiet_cmd_thread == ThreadID'(tid)))
                        else $fatal(1, "child allocated storage before parent completion");
                    early_child_preparations++;
                    if ((dut.search_tt_lookup_issue_valid && dut.tt_lookup_req_ready
                                && dut.search_tt_lookup_issue_thread == ThreadID'(tid))
                            || (dut.search_eval_issue_valid && dut.search_eval_issue_thread == ThreadID'(tid)))
                        early_child_search_requests++;
                end
            end
        end
    end

    initial begin
        // Full mating regressions have a separate budget from shallow checks.
        #(MATE_ONLY ? 80_000_000 : 5_000_000);
        fail_count += 1;
        $error("[FAIL] tb_search_controller timeout");
        $display("Pass Count: %0d", pass_count);
        $display("Fail Count: %0d", fail_count);
        $fatal(1, "tb_search_controller timeout");
    end

    always @(posedge clk) begin
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
                        && dut.nnue_plan[dut.nnue_delta_thread].kind == NNUE_PLAN_DELTA)
                    nnue_delta_seen = 1'b1;
                if (dut.nnue_delta_busy
                        && dut.nnue_plan[dut.nnue_delta_thread].kind == NNUE_PLAN_DELTA
                        && dut.nnue_plan[dut.nnue_delta_thread].mover.piece_type == KING
                        && dut.nnue_plan[dut.nnue_delta_thread].from_pos[2:0] == BoardFile'(4)
                        && (dut.nnue_plan[dut.nnue_delta_thread].to_pos[2:0] == BoardFile'(2)
                            || dut.nnue_plan[dut.nnue_delta_thread].to_pos[2:0] == BoardFile'(6)))
                    nnue_castle_request_count[dut.nnue_delta_thread] += 1;
            end
            if (dut.nnue_update_done_valid
                    && dut.nnue_plan[dut.nnue_update_done_thread].mover.piece_type == KING
                    && dut.nnue_plan[dut.nnue_update_done_thread].from_pos[2:0] == BoardFile'(4)
                    && (dut.nnue_plan[dut.nnue_update_done_thread].to_pos[2:0] == BoardFile'(2)
                        || dut.nnue_plan[dut.nnue_update_done_thread].to_pos[2:0]
                            == BoardFile'(6))) begin
                nnue_castle_request_count_correct &=
                    nnue_castle_request_count[dut.nnue_update_done_thread] == 4;
                nnue_castle_request_count[dut.nnue_update_done_thread] = 0;
            end
            if (dut.nnue_update_done_valid) begin
                automatic ThreadID completed_thread = dut.nnue_update_done_thread;
                automatic logic is_castle =
                    dut.nnue_plan[completed_thread].mover.piece_type == KING
                    && dut.nnue_plan[completed_thread].from_pos[2:0] == BoardFile'(4)
                    && (dut.nnue_plan[completed_thread].to_pos[2:0] == BoardFile'(2)
                        || dut.nnue_plan[completed_thread].to_pos[2:0] == BoardFile'(6));
                automatic logic is_en_passant =
                    dut.nnue_plan[completed_thread].mover.piece_type == PAWN
                    && dut.nnue_plan[completed_thread].capture_valid
                    && dut.nnue_plan[completed_thread].capture_pos
                        != dut.nnue_plan[completed_thread].to_pos;
                automatic logic is_promotion =
                    dut.nnue_plan[completed_thread].mover.piece_type == PAWN
                    && dut.nnue_plan[completed_thread].placed.piece_type != PAWN;
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
                end
            end
            if (dut.state == CTRL_SEARCH_ROOT_INIT
                    && dut.nnue_root_init_pos == Position'(0)
                    && dut.nnue_root_init_first)
                nnue_root_initialization_correct &= dut.nnue_update_idle;
            if (dut.state == CTRL_SEARCH_RUN && dut.nnue_roots_initialized
                    && !nnue_root_initialization_seen) begin
                nnue_root_initialization_seen = 1'b1;
                for (int idx = 0; idx < THREAD_COUNT; idx++) begin
                    nnue_root_initialization_correct &=
                        dut.nnue_state_valid[idx];
                    nnue_root_initialization_correct &=
                        dut.nnue_evaluator.accumulator_update_memory[
                            idx
                        ] === dut.nnue_evaluator.accumulator_update_memory[0];
                end
            end
            if (dut.state == CTRL_SEARCH_RUN && dut.nnue_build_busy
                    && dut.nnue_update_valid && dut.nnue_update_ready
                    && dut.nnue_update_req.clear)
                nnue_recovery_rebuild_seen = 1'b1;
            for (int idx = 0; idx < THREAD_COUNT; idx++) begin
                if (dut.search_stack_top[idx].entered_by_null
                        && dut.search_thread_phase[idx] == SEARCH_PHASE_READY) begin
                    nnue_null_state_seen = 1'b1;
                    nnue_null_state_correct &= dut.nnue_state_valid[idx]
                        && !dut.nnue_plan_pending[idx];
                end
                if (dut.nnue_plan_pending[idx])
                    nnue_pending_state_invalid &=
                        !dut.nnue_state_valid[idx];
                if (dut.nnue_plan_pending[idx] && dut.nnue_plan[idx].reverse)
                    nnue_reverse_delta_seen = 1'b1;
                if (dut.nnue_plan_pending[idx] && dut.nnue_plan[idx].real_move
                        && dut.nnue_plan[idx].mover.piece_type == KING) begin
                    automatic logic is_castle =
                        dut.nnue_plan[idx].from_pos[2:0] == BoardFile'(4)
                        && (dut.nnue_plan[idx].to_pos[2:0] == BoardFile'(2)
                            || dut.nnue_plan[idx].to_pos[2:0] == BoardFile'(6));
                    if (is_castle) begin
                        nnue_king_delta_correct &=
                            dut.nnue_plan[idx].kind == NNUE_PLAN_DELTA;
                    end else begin
                        nnue_king_delta_seen = 1'b1;
                        nnue_king_delta_correct &=
                            dut.nnue_plan[idx].kind == NNUE_PLAN_DELTA;
                    end
                    if (dut.nnue_plan[idx].from_pos == Position'(4)
                            && dut.nnue_plan[idx].to_pos == Position'(6)
                            && dut.nnue_plan[idx].kind == NNUE_PLAN_DELTA)
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
                if (dut.search_eval_issue_valid
                        && dut.search_eval_issue_thread == ThreadID'(idx)
                        && dut.search_thread_rfp_ready(idx)) begin
                    rfp_eval_seen = 1'b1;
                end
                if (root_stack_capture_pending[idx]) begin
                    root_stack_seen[idx] = 1'b1;
                root_first_stack_move[idx] = dut.search_stack_top[idx].move;
                    root_stack_capture_pending[idx] = 1'b0;
                end
                if (dut.search_thread_phase[idx] == SEARCH_PHASE_READY) begin
                    thread_ready_phase_seen[idx] = 1'b1;
                end
                if (dut.search_thread_phase[idx] == SEARCH_PHASE_MOVE_WAIT) begin
                    thread_move_phase_seen[idx] = 1'b1;
                end
                if (dut.search_thread_phase[idx] == SEARCH_PHASE_BOARD_WAIT) begin
                    thread_board_phase_seen[idx] = 1'b1;
                end
                if (dut.search_thread_phase[idx] == SEARCH_PHASE_EVAL_WAIT) begin
                    thread_eval_phase_seen[idx] = 1'b1;
                end
                if (dut.search_thread_phase[idx] == SEARCH_PHASE_STORE_PUBLISH) begin
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
                if (dut.search_thread_phase[idx] == SEARCH_PHASE_EVAL_WAIT) begin
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
                if (dut.search_thread_phase[idx] == SEARCH_PHASE_STORE_PUBLISH) begin
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
                    if (dut.search_thread_phase[idx] == SEARCH_PHASE_EVAL_WAIT) begin
                        active_pipeline_count += 1;
                        break;
                    end
                end
                if (active_pipeline_count > 1) begin
                    pipeline_overlap_seen = 1'b1;
                end
            end
            if (dut.state == CTRL_SEARCH_RUN) begin
                search_dispatch_state_seen = 1'b1;
                for (int idx = 0; idx < THREAD_COUNT; idx++) begin
                    if (dut.search_thread_phase[idx] == SEARCH_PHASE_STORE_PUBLISH) begin
                        store_wait_dispatch_seen = 1'b1;
                    end
                    if (dut.search_thread_phase[idx] == SEARCH_PHASE_MOVE_WAIT
                            && dut.search_return_valid[idx]
                            && !dut.search_move_inflight[idx]) begin
                        return_pending_dispatch_seen = 1'b1;
                    end
                end
            end
            if (dut.state == CTRL_SEARCH_RUN && dut.search_tt_consume_valid) begin
                tt_response_consume_seen = 1'b1;
                if (dut.search_tt_response_pending[dut.search_tt_consume_thread])
                    tt_response_buffered_consume_seen = 1'b1;
                thread_tt_response_cursor_seen[int'(dut.search_tt_consume_thread)] = 1'b1;
            end
            if (dut.state == CTRL_SEARCH_RUN && dut.move_followup_accepted)
                move_followup_seen = 1'b1;
            if (dut.state == CTRL_SEARCH_RUN) begin
                for (int idx = 0; idx < THREAD_COUNT; idx++) begin
                    if (dut.search_return_valid[idx]
                            && !dut.search_move_inflight[idx]
                            && dut.search_thread_phase[idx] == SEARCH_PHASE_MOVE_WAIT) begin
                        thread_return_cursor_seen[idx] = 1'b1;
                    end
                end
            end
            if (dut.state == CTRL_SEARCH_RUN
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
            if (dut.state == CTRL_SEARCH_RUN && dut.search_tt_consume_valid) begin
                automatic ThreadID validation_tid = dut.search_tt_consume_thread;
                automatic TTLookupResponse validation_resp =
                    dut.search_tt_consume_response;
                if (validation_resp.hit
                        && validation_resp.depth >= dut.search_remaining_depth(validation_tid)
                        && dut.search_remaining_depth(validation_tid)
                            >= dut.TT_VALIDATE_MINIMUM_DEPTH
                        && dut.search_board[validation_tid].halfmove_clock
                            > HalfmoveClock'(dut.TT_VALIDATE_BYPASS_HALFMOVES)
                        && validation_resp.score <= DRAW_EVAL_SCORE
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
                if (observe_underpromotion && dut.search_tt_store_issue_thread == ThreadID'(0)
                        && dut.tt_store_req.depth == TTDepth'(3)
                        && dut.tt_store_req.zobrist_key == dut.active_zobrist_key) begin
                    underpromotion_store_seen = 1;
                    underpromotion_store = dut.tt_store_req;
                end
                tt_store_depth_correct &= dut.tt_store_req.depth
                    == dut.search_stack_top[int'(dut.search_tt_store_issue_thread)].remaining_depth;
            end
            // Null children use their own reduction and must not be checked
            // against the real-move LMR depth calculation.
            if (dut.search_board_issue_valid && !dut.search_board_issue_is_null
                    && dut.search_thread_phase[int'(dut.search_board_issue_thread)] != SEARCH_PHASE_REVERSE_WAIT) begin
                automatic int lmr_tid;
                lmr_tid = int'(dut.search_board_issue_thread);
                lmr_issue_legal_count[lmr_tid] = dut.search_stack_top[lmr_tid].legal_move_count;
                if (dut.search_pvs_research[lmr_tid]) begin
                    lmr_recovery_issue_seen = 1'b1;
                    lmr_full_tt_pending[lmr_tid] = 1'b1;
                    lmr_expected_child_depth[lmr_tid] = 8'(dut.search_stack_top[lmr_tid].remaining_depth - 1'b1);
                    lmr_recovery_check_pending[lmr_tid] = 1'b1;
                end else if (dut.lmr_eligible(
                        dut.search_ply[lmr_tid],
                        dut.search_stack_top[lmr_tid].remaining_depth,
                        dut.search_stack_top[lmr_tid].legal_move_count,
                        dut.search_pvs_research[lmr_tid])) begin
                    lmr_reduced_issue_seen = 1'b1;
                    lmr_expected_child_depth[lmr_tid] = 8'(dut.lmr_child_depth(dut.search_board_issue_thread, dut.search_board_issue_bucket));
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
            if (dut.state == CTRL_SEARCH_RUN) begin
                automatic bit all_active;

                all_active = 1'b1;
                for (int idx = 0; idx < THREAD_COUNT; idx++) begin
                    if (dut.search_thread_phase[idx] == SEARCH_PHASE_IDLE
                            || dut.search_thread_phase[idx] == SEARCH_PHASE_DONE) begin
                        all_active = 1'b0;
                    end
                end
                if (all_active) begin
                    all_threads_root_active_seen = 1'b1;
                end
            end
            if (dut.state == CTRL_SEARCH_RUN) begin
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
            if (dut.state == CTRL_SEARCH_RUN && dut.search_board_issue_valid) begin
                automatic int issue_tid = int'(dut.search_board_issue_thread);
                thread_move_handoff_seen[int'(dut.search_board_issue_thread)] = 1'b1;
                if (dut.board_update_op == BOARD_PUSH_MOVE_OP
                        || dut.board_update_op == BOARD_PUSH_NULL_OP)
                    check(dut.search_node_init_done[issue_tid],
                        "move memory is initialized before descent");
                if (dut.board_update_op == BOARD_PUSH_NULL_OP) null_push_seen = 1'b1;
                if (dut.board_update_op == BOARD_REVERSE_MOVE_OP
                        && dut.search_stack_top[dut.search_board_issue_thread].entered_by_null)
                    null_reverse_seen = 1'b1;
            end
            if (dut.state == CTRL_SEARCH_RUN) begin
                for (int idx = 0; idx < THREAD_COUNT; idx++) begin
                    if (dut.search_thread_phase[idx] == SEARCH_PHASE_MOVE_WAIT
                            && dut.search_return_valid[idx]) begin
                        thread_eval_handoff_seen[idx] = 1'b1;
                    end
                end
            end
            if (dut.state == CTRL_SEARCH_RUN
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

    // Cached entry-time policy tests remain valid through parent restoration.
    always @(negedge clk) begin
        for (int tid = 0; tid < THREAD_COUNT; tid++) begin
            if (rst_n && dut.state == CTRL_SEARCH_RUN) begin
                // Cached policy bits must match the fixed node bounds after its TT probe.
                if (dut.search_stack_top[tid].tt_checked) begin
                    check(dut.search_stack_top[tid].rfp_eligible == dut.rfp_node_eligible(
                            dut.search_stack_top[tid].remaining_depth,
                            dut.search_stack_top[tid].zero_window_node,
                            dut.search_board_in_check[tid], dut.search_stack_top[tid].beta),
                        "cached RFP eligibility matches the node entry window");
                    check(dut.search_stack_top[tid].null_beta_allowed
                            == (dut.search_stack_top[tid].beta > dut.NULL_MIN_BETA),
                        "cached null-move bound eligibility matches the node beta");
                end
            end
        end
    end
