// Reset, cancellation, response routing, command states, and search initialization.
// Included in search_controller scope; this file is not a standalone compilation unit.

    always_ff @(posedge clk) begin
        if (!rst_n) begin
            move_pop_response_rr <= ThreadID'(0);
            state <= CTRL_IDLE;
            active_req <= EngineControllerRequest'('0);
            resp_reg <= EngineControllerResponse'('0);
            resp_valid <= 1'b0;
            board_wait_count <= BoardWaitCount'(0);
            move_wait_count <= MoveWaitCount'(0);
            active_board <= FullBoard'('0);
            active_board_in_check <= 1'b0;
            active_zobrist_key <= ZobristKey'(0);
            active_pst_eval <= PstEvalPair'('0);
            active_piece_count <= PieceCount'(0);
            repetition_epoch <= '0;
            repetition_init_start <= 1'b0;
            repetition_history_reset <= 1'b0;
            repetition_history_write <= 1'b0;
            repetition_history_key <= '0;
            repetition_line_write_valid <= 1'b0;
            repetition_line_write_thread <= '0;
            repetition_line_write_ply <= '0;
            repetition_line_write_key <= '0;
            repetition_req_valid <= 1'b0;
            repetition_req_thread <= '0;
            repetition_req_ply <= '0;
            repetition_req_start_ply <= '0;
            repetition_req_key <= '0;
            new_setup_index <= 7'd0;
            search_nodes <= NodeCountType'(0);
            search_max_depth <= SearchDepth'(0);
            search_completed_depth <= SearchDepth'(0);
            search_completed_best_move <= NULL_MOVE;
            search_root_fallback_move <= NULL_MOVE;
            search_completed_ponder_move <= NULL_MOVE;
            search_completed_score <= EvalScore'(0);
            search_thread_id <= ThreadID'(0);
            search_dispatch <= '0;
`ifndef SYNTHESIS
            search_board_result_thread_id <= ThreadID'(0);
            search_move_result_thread_id <= ThreadID'(0);
            search_eval_result_thread_id <= ThreadID'(0);
            search_board_result_valid <= 1'b0;
            search_move_result_valid <= 1'b0;
            search_eval_result_valid <= 1'b0;
`endif
            search_active_thread_count <= ThreadCount'(0);
            search_base_ms <= SearchTimeBase'(0);
            search_soft_ms <= TimeType'(0);
            search_next_depth_ms <= TimeType'(0);
            search_hard_ms <= TimeType'(0);
            time_setup_start <= 1'b0;
            time_adaptive_start <= 1'b0;
            pending_soft_factor <= 4'(SOFT_FACTOR_DEFAULT);
            pending_single_legal_move <= 1'b0;
            previous_depth_best_move <= NULL_MOVE;
            best_move_stable_depths <= 8'd0;
            previous_depth_score <= EvalScore'(0);
            total_root_nodes <= NodeCountType'(0);
            current_best_move_root_nodes <= NodeCountType'(0);
            current_root_move_start_nodes <= NodeCountType'(0);
            tt_age <= TTAge'(0);
            terminal_result_valid_pipe <= 1'b0;
            terminal_result_thread_pipe <= ThreadID'(0);
            terminal_result_ply_pipe <= PlyIndex'(0);
            terminal_result_score_pipe <= EvalScore'(0);
            nnue_build_busy <= 1'b0;
            nnue_build_draining <= 1'b0;
            nnue_build_first <= 1'b0;
            nnue_build_wait_updates <= 1'b0;
            nnue_build_pos <= Position'(0);
            nnue_build_thread <= ThreadID'(0);
            nnue_roots_initialized <= 1'b0;
            nnue_root_init_draining <= 1'b0;
            nnue_root_init_first <= 1'b0;
            nnue_root_init_thread <= ThreadID'(0);
            nnue_root_init_pos <= Position'(0);
            nnue_eval_tag_read_ptr <= 1'b0;
            nnue_eval_tag_write_ptr <= 1'b0;
            nnue_eval_tag_count <= 2'd0;
            nnue_delta_busy <= 1'b0;
            nnue_delta_draining <= 1'b0;
            nnue_delta_replay <= 1'b0;
            nnue_delta_first <= 1'b0;
            nnue_delta_thread <= ThreadID'(0);
            nnue_plan_rr_ptr <= ThreadID'(0);
            nnue_delta_step <= 3'd0;
            nnue_delta_pos <= Position'(0);
`ifdef FPGA_CHESS_PROFILE
            profile_terminal_event <= 1'b0;
            profile_terminal_kind <= 2'd0;
            profile_rfp_cutoff_event <= 1'b0;
            profile_futility_prune_event <= 1'b0;
            profile_qdelta_prune_event <= 1'b0;
            profile_beta_cutoff_event <= 1'b0;
            profile_beta_cutoff_thread <= ThreadID'(0);
            profile_beta_cutoff_ply <= PlyIndex'(0);
            profile_beta_cutoff_rank <= 8'd0;
            profile_beta_cutoff_move <= NULL_MOVE;
`endif
            for (int tid = 0; tid < SEARCH_THREAD_COUNT; tid++) begin
                search_best_move[tid] <= NULL_MOVE;
                search_ponder_move[tid] <= NULL_MOVE;
                search_root_best_score[tid] <= -MAX_EVAL_SCORE;
                search_root_has_completed_move[tid] <= 1'b0;
                search_root_best_exact[tid] <= 1'b0;
                search_thread_phase[tid] <= SEARCH_PHASE_IDLE;
                search_thread_nodes[tid] <= NodeCountType'(0);
                search_thread_target_depth[tid] <= SearchDepth'(0);
                search_thread_root_alpha[tid] <= -MAX_EVAL_SCORE;
                search_thread_root_beta[tid] <= MAX_EVAL_SCORE;
                search_thread_aspiration_delta[tid] <= aspiration_initial_delta(tid);
                search_thread_aspiration_active[tid] <= 1'b0;
                search_thread_iteration_best_move[tid] <= NULL_MOVE;
                search_thread_iteration_ponder_move[tid] <= NULL_MOVE;
                search_thread_iteration_score[tid] <= EvalScore'(0);
`ifndef SYNTHESIS
                search_thread_completed_depth[tid] <= 8'd0;
                search_thread_completed_best_move[tid] <= NULL_MOVE;
`endif
                search_board_inflight[tid] <= 1'b0;
                search_move_inflight[tid] <= 1'b0;
                search_tt_lookup_inflight[tid] <= 1'b0;
                search_tt_response_pending[tid] <= 1'b0;
                search_null_candidate[tid] <= 1'b0;
                search_repetition_pending[tid] <= 1'b0;
                search_repetition_done[tid] <= 1'b0;
                search_repetition_draw[tid] <= 1'b0;
                search_repetition_seen_before[tid] <= 1'b0;
                search_tt_validation_pending[tid] <= 1'b0;
                search_tt_validation_passed[tid] <= 1'b0;
                search_tt_validation_forced[tid] <= 1'b0;
                search_tt_history_required[tid] <= 1'b0;
                search_tt_response[tid] <= TTLookupResponse'('0);
                search_pending_move[tid] <= NULL_MOVE;
                search_pending_move_bucket[tid] <= QUIET_MEDIUM_BUCKET;
                search_board[tid] <= FullBoard'('0);
                search_board_in_check[tid] <= 1'b0;
                search_zobrist_key[tid] <= ZobristKey'(0);
                search_pst_eval[tid] <= PstEvalPair'('0);
                search_piece_count[tid] <= PieceCount'(0);
                search_ply[tid] <= PlyIndex'(0);
                search_return_score[tid] <= EvalScore'(0);
                search_return_valid[tid] <= 1'b0;
                search_return_was_scout[tid] <= 1'b0;
                search_return_was_reduced[tid] <= 1'b0;
                search_return_was_null[tid] <= 1'b0;
                search_pvs_research[tid] <= 1'b0;
                search_eval_is_stand_pat[tid] <= 1'b0;
                search_eval_is_rfp[tid] <= 1'b0;
                search_eval_is_futility[tid] <= 1'b0;
                search_futility_eval_pending[tid] <= 1'b0;
                search_node_init_pending[tid] <= 1'b0;
                search_node_init_done[tid] <= 1'b0;
                nnue_plan_pending[tid] <= 1'b0;
                nnue_plan_inflight[tid] <= 1'b0;
                nnue_plan[tid].kind <= NNUE_PLAN_REBUILD;
                nnue_plan[tid].child_ply <= PlyIndex'(0);
                nnue_plan[tid].capture_valid <= 1'b0;
                nnue_plan[tid].real_move <= 1'b0;
                nnue_plan[tid].reverse <= 1'b0;
                nnue_state_valid[tid] <= 1'b0;
                search_stack_top[tid] <= empty_search_stack_entry();
                search_return_move[tid] <= NULL_MOVE;
                search_return_ponder_move[tid] <= NULL_MOVE;
                history_update_pending[tid] <= 1'b0;
                history_update_pending_color[tid] <= WHITE;
                history_update_pending_from[tid] <= Position'(0);
                history_update_pending_to[tid] <= Position'(0);
                history_update_pending_depth[tid] <= PlyIndex'(0);
                history_update_pending_failed0[tid] <= 12'd0;
                history_update_pending_failed1[tid] <= 12'd0;
                history_update_pending_failed2[tid] <= 12'd0;
                history_update_pending_failed_count[tid] <= 2'd0;
            end
            for (int idx = 0; idx < SEARCH_BOARD_TAG_PIPE_LEN; idx++) begin
                search_board_tag_pipe[idx] <= ThreadID'(0);
                search_board_op_tag_pipe[idx] <= BOARD_IDLE_OP;
                search_board_ply_tag_pipe[idx] <= PlyIndex'(0);
                search_board_tag_valid_pipe[idx] <= 1'b0;
            end
            for (int idx = 0; idx < SEARCH_MOVE_TAG_PIPE_LEN; idx++) begin
                search_move_tag_pipe[idx] <= ThreadID'(0);
                search_move_tag_valid_pipe[idx] <= 1'b0;
                search_move_in_check_pipe[idx] <= 1'b0;
            end
        end else begin
            if (move_pop_resp_valid)
                move_pop_response_rr <= search_thread_after(move_pop_resp_thread);
            resp_valid <= 1'b0;
            time_setup_start <= 1'b0;
            time_adaptive_start <= 1'b0;
            repetition_init_start <= 1'b0;
            repetition_history_reset <= 1'b0;
            repetition_history_write <= 1'b0;
            repetition_line_write_valid <= 1'b0;
            repetition_req_valid <= 1'b0;
            search_board_result_valid <= 1'b0;
            search_move_result_valid <= 1'b0;
            search_eval_result_valid <= 1'b0;
            terminal_result_valid_pipe <= 1'b0;
`ifdef FPGA_CHESS_PROFILE
            profile_terminal_event <= 1'b0;
            profile_rfp_cutoff_event <= 1'b0;
            profile_futility_prune_event <= 1'b0;
            profile_qdelta_prune_event <= 1'b0;
            profile_beta_cutoff_event <= 1'b0;
`endif
            if (state != CTRL_SEARCH_RUN) begin
                nnue_build_busy <= 1'b0;
                nnue_build_draining <= 1'b0;
                nnue_build_first <= 1'b0;
                nnue_build_wait_updates <= 1'b0;
                nnue_eval_tag_read_ptr <= 1'b0;
                nnue_eval_tag_write_ptr <= 1'b0;
                nnue_eval_tag_count <= 2'd0;
                nnue_delta_busy <= 1'b0;
                nnue_delta_draining <= 1'b0;
                nnue_delta_replay <= 1'b0;
            end

            if (move_history_update_valid && move_history_update_ready) begin
                automatic logic cleared_history_update;

                cleared_history_update = 1'b0;
                for (int tid = 0; tid < SEARCH_THREAD_COUNT; tid++) begin
                    if (!cleared_history_update && history_update_pending[tid]) begin
                        history_update_pending[tid] <= 1'b0;
                        cleared_history_update = 1'b1;
                    end
                end
            end

            // A Kill or New Game can retire a search while an external-memory
            // response is still returning. Accept only the response belonging
            // to this thread's currently outstanding lookup.
            if (tt_lookup_resp_valid
                    && search_tt_lookup_inflight[tt_lookup_resp.thread_id]
                    && search_thread_phase[tt_lookup_resp.thread_id] == SEARCH_PHASE_TT_WAIT) begin
                search_tt_response[tt_lookup_resp.thread_id] <= tt_lookup_resp;
                search_tt_response_pending[tt_lookup_resp.thread_id] <= 1'b1;
                search_tt_lookup_inflight[tt_lookup_resp.thread_id] <= 1'b0;
            end

            if (repetition_resp_valid && repetition_resp_epoch == repetition_epoch
                    && search_repetition_pending[repetition_resp_thread]) begin
                automatic logic nnue_completes_now = nnue_update_done_valid
                    && nnue_update_done_thread == repetition_resp_thread;
                search_repetition_pending[repetition_resp_thread] <= 1'b0;
                search_repetition_done[repetition_resp_thread] <= 1'b1;
                search_repetition_draw[repetition_resp_thread] <= repetition_resp_is_draw;
                if (search_tt_validation_pending[repetition_resp_thread]) begin
                    search_tt_validation_pending[repetition_resp_thread] <= 1'b0;
                    if (repetition_resp_count != 2'd0) begin
                        // Any prior occurrence gives this child a different
                        // draw context from the cached search. Reject its score,
                        // then run it through ordinary move search so immediate
                        // and short forced repetitions remain selectable.
                        search_stack_top[repetition_resp_thread].move_order_state
                            <= MOVE_ORDER_DIRECT;
                        search_stack_top[repetition_resp_thread].direct_attempted <= 1'b0;
                        search_tt_validation_forced[repetition_resp_thread] <= 1'b1;
                        search_thread_phase[repetition_resp_thread] <= SEARCH_PHASE_READY;
                    end else begin
                        // Replay the retained TT response now that its move has
                        // passed pseudo-legality, king-safety, and repetition.
                        search_tt_validation_passed[repetition_resp_thread] <= 1'b1;
                        search_tt_response_pending[repetition_resp_thread] <= 1'b1;
                        search_thread_phase[repetition_resp_thread] <= SEARCH_PHASE_TT_WAIT;
                    end
                end else begin
                    // A real node with one prior occurrence can have a
                    // different value from the same board in another history.
                    search_repetition_seen_before[repetition_resp_thread]
                        <= repetition_resp_count != 2'd0;
                    if (!nnue_plan_pending[repetition_resp_thread] || nnue_completes_now) begin
                        if (repetition_resp_is_draw) begin
                            search_return_score[repetition_resp_thread] <= DRAW_EVAL_SCORE;
                            search_return_valid[repetition_resp_thread] <= 1'b1;
                            search_thread_phase[repetition_resp_thread]
                                <= SEARCH_PHASE_REVERSE_WAIT;
                        end else begin
                            search_thread_phase[repetition_resp_thread] <= SEARCH_PHASE_READY;
                        end
                    end
                end
            end

            if (req_valid && req.operation == ENGINE_CTRL_KILL && state != CTRL_IDLE) begin
                repetition_epoch <= repetition_epoch + 1'b1;
                terminal_result_valid_pipe <= 1'b0;
                resp_reg <= stopped_search_response(
                    is_search_operation(active_req.operation), 1'b1, ENGINE_END_KILLED);
                for (int tid = 0; tid < SEARCH_THREAD_COUNT; tid++) begin
                    search_board_inflight[tid] <= 1'b0;
                    search_move_inflight[tid] <= 1'b0;
                    search_tt_lookup_inflight[tid] <= 1'b0;
                    search_tt_response_pending[tid] <= 1'b0;
                    search_repetition_pending[tid] <= 1'b0;
                    search_repetition_done[tid] <= 1'b0;
                    search_repetition_draw[tid] <= 1'b0;
                    search_repetition_seen_before[tid] <= 1'b0;
                    search_tt_validation_pending[tid] <= 1'b0;
                    search_tt_validation_passed[tid] <= 1'b0;
                    search_tt_validation_forced[tid] <= 1'b0;
                    search_root_has_completed_move[tid] <= 1'b0;
                    search_root_best_exact[tid] <= 1'b0;
                    search_return_was_scout[tid] <= 1'b0;
                    search_return_was_reduced[tid] <= 1'b0;
                    search_return_was_null[tid] <= 1'b0;
                    search_pvs_research[tid] <= 1'b0;
                    history_update_pending[tid] <= 1'b0;
                    nnue_plan_pending[tid] <= 1'b0;
                    nnue_plan_inflight[tid] <= 1'b0;
                    nnue_state_valid[tid] <= 1'b0;
                    search_thread_phase[tid] <= SEARCH_PHASE_IDLE;
                end
                for (int idx = 0; idx < SEARCH_BOARD_TAG_PIPE_LEN; idx++) begin
                    search_board_tag_pipe[idx] <= ThreadID'(0);
                    search_board_op_tag_pipe[idx] <= BOARD_IDLE_OP;
                    search_board_ply_tag_pipe[idx] <= PlyIndex'(0);
                    search_board_tag_valid_pipe[idx] <= 1'b0;
                end
                for (int idx = 0; idx < SEARCH_MOVE_TAG_PIPE_LEN; idx++) begin
                    search_move_tag_pipe[idx] <= ThreadID'(0);
                    search_move_tag_valid_pipe[idx] <= 1'b0;
                    search_move_in_check_pipe[idx] <= 1'b0;
                end
                state <= CTRL_FLUSH_RESPOND;
            end else begin
            // FSM state encodings are mutually exclusive; default retains recovery/idle behavior.
            unique case (state)
                CTRL_IDLE: begin
                    if (req_valid) begin
                        active_req <= req;
                        // Controller operation encodings are disjoint, including grouped search operations.
                        unique case (req.operation)
                            ENGINE_CTRL_BOARD_UPDATE: begin
                                if (req.board_op == BOARD_REVERSE_MOVE_OP) begin
                                    resp_reg <= EngineControllerResponse'('0);
                                    resp_reg.error <= 1'b1;
                                    resp_reg.end_reason <= ENGINE_END_ERROR;
                                    state <= CTRL_DIRECT_DONE;
                                end else begin
                                    state <= CTRL_BOARD_ISSUE;
                                end
                            end

                            ENGINE_CTRL_NEW_GAME: begin
                                repetition_epoch <= repetition_epoch + 1'b1;
                                search_best_move[search_thread_id] <= NULL_MOVE;
                                search_nodes <= NodeCountType'(0);
                                search_dispatch <= '0;
                                search_active_thread_count <= ThreadCount'(0);
                                for (int tid = 0; tid < SEARCH_THREAD_COUNT; tid++) begin
                                    search_thread_nodes[tid] <= NodeCountType'(0);
                                    search_thread_phase[tid] <= SEARCH_PHASE_IDLE;
                                    search_board_inflight[tid] <= 1'b0;
                                    search_move_inflight[tid] <= 1'b0;
                                    search_tt_lookup_inflight[tid] <= 1'b0;
                                    search_tt_response_pending[tid] <= 1'b0;
                                    search_repetition_pending[tid] <= 1'b0;
                                    search_repetition_done[tid] <= 1'b0;
                                    search_repetition_draw[tid] <= 1'b0;
                                    search_repetition_seen_before[tid] <= 1'b0;
                                    search_tt_validation_pending[tid] <= 1'b0;
                                    search_tt_validation_passed[tid] <= 1'b0;
                                    search_tt_validation_forced[tid] <= 1'b0;
                                    history_update_pending[tid] <= 1'b0;
                                    nnue_plan_pending[tid] <= 1'b0;
                                    nnue_plan_inflight[tid] <= 1'b0;
                                    nnue_plan[tid].kind <= NNUE_PLAN_REBUILD;
                                    nnue_plan[tid].child_ply <= PlyIndex'(0);
                                    nnue_plan[tid].capture_valid <= 1'b0;
                                    nnue_plan[tid].real_move <= 1'b0;
                                    nnue_plan[tid].reverse <= 1'b0;
                                    nnue_state_valid[tid] <= 1'b0;
                                end
                                for (int idx = 0; idx < SEARCH_BOARD_TAG_PIPE_LEN; idx++) begin
                                    search_board_tag_pipe[idx] <= ThreadID'(0);
                                    search_board_op_tag_pipe[idx] <= BOARD_IDLE_OP;
                                    search_board_ply_tag_pipe[idx] <= PlyIndex'(0);
                                    search_board_tag_valid_pipe[idx] <= 1'b0;
                                end
                                for (int idx = 0; idx < SEARCH_MOVE_TAG_PIPE_LEN; idx++) begin
                                    search_move_tag_pipe[idx] <= ThreadID'(0);
                                    search_move_tag_valid_pipe[idx] <= 1'b0;
                                    search_move_in_check_pipe[idx] <= 1'b0;
                                end
                                tt_age <= TTAge'(0);
                                state <= CTRL_NEW_CLEAR_START;
                            end

                            ENGINE_CTRL_PERFT: begin
                                if (req.depth_limit >= 8'(SEARCH_STACK_DEPTH)) begin
                                    resp_reg <= EngineControllerResponse'('0);
                                    resp_reg.error <= 1'b1;
                                    resp_reg.end_reason <= ENGINE_END_ERROR;
                                    state <= CTRL_RESPOND;
                                end else begin
                                    // Perft borrows the idle first search context and leaves the game board intact.
                                    search_board[0] <= active_board;
                                    search_board_in_check[0] <= active_board_in_check;
                                    search_zobrist_key[0] <= active_zobrist_key;
                                    search_pst_eval[0] <= active_pst_eval;
                                    search_piece_count[0] <= active_piece_count;
                                    search_pending_move[0] <= NULL_MOVE;
                                    search_stack_top[0] <= empty_search_stack_entry();
                                    search_stack_top[0].move_order_state <= MOVE_ORDER_GENERATE_NOISY;
                                    search_ply[0] <= PlyIndex'(0);
                                    search_nodes <= (req.depth_limit == 8'd0) ? NodeCountType'(1) : NodeCountType'(0);
                                    if (req.depth_limit == 8'd0) begin
                                        resp_reg <= EngineControllerResponse'('0);
                                        resp_reg.nodes_count <= NodeCountType'(1);
                                        resp_reg.completed_depth <= 8'd0;
                                        resp_reg.end_reason <= ENGINE_END_DEPTH_LIMIT;
                                        state <= CTRL_RESPOND;
                                    end else begin
                                        state <= CTRL_PERFT_GEN_ISSUE;
                                    end
                                end
                            end

                            ENGINE_CTRL_SEARCH_DEPTH,
                            ENGINE_CTRL_SEARCH_FIXED_TIME,
                            ENGINE_CTRL_SEARCH_ON_CLOCK,
                            ENGINE_CTRL_SEARCH_NODES: begin
                                if (requested_search_depth(req) >= 8'(SEARCH_STACK_DEPTH)) begin
                                    resp_reg <= EngineControllerResponse'('0);
                                    resp_reg.error <= 1'b1;
                                    resp_reg.end_reason <= ENGINE_END_ERROR;
                                    state <= CTRL_RESPOND;
                                end else begin
                                    search_ply[search_thread_id] <= PlyIndex'(0);
                                    search_max_depth <= SearchDepth'(requested_search_depth(req));
                                    search_completed_depth <= SearchDepth'(0);
                                    search_completed_best_move <= NULL_MOVE;
                                    search_root_fallback_move <= NULL_MOVE;
                                    search_completed_ponder_move <= NULL_MOVE;
                                    search_completed_score <= EvalScore'(0);
                                    search_thread_id <= ThreadID'(0);
                                    search_dispatch <= '0;
                                    search_active_thread_count <= ThreadCount'(0);
                                    search_nodes <= NodeCountType'(0);
                                    nnue_roots_initialized <= 1'b0;
                                    search_pending_move[search_thread_id] <= NULL_MOVE;
                                    search_return_score[search_thread_id] <= EvalScore'(0);
                                    search_return_valid[search_thread_id] <= 1'b0;
                                    search_return_was_scout[search_thread_id] <= 1'b0;
                                    search_return_was_reduced[search_thread_id] <= 1'b0;
                                    search_return_was_null[search_thread_id] <= 1'b0;
                                    search_pvs_research[search_thread_id] <= 1'b0;
                                    search_eval_is_stand_pat[search_thread_id] <= 1'b0;
                                    search_eval_is_rfp[search_thread_id] <= 1'b0;
                                    search_eval_is_futility[search_thread_id] <= 1'b0;
                                    search_futility_eval_pending[search_thread_id] <= 1'b0;
                                    tt_age <= tt_age + TTAge'(1);
                                    pending_soft_factor <= 4'(SOFT_FACTOR_DEFAULT);
                                    pending_single_legal_move <= 1'b0;
                                    previous_depth_best_move <= NULL_MOVE;
                                    best_move_stable_depths <= 8'd0;
                                    previous_depth_score <= EvalScore'(0);
                                    total_root_nodes <= NodeCountType'(0);
                                    current_best_move_root_nodes <= NodeCountType'(0);
                                    current_root_move_start_nodes <= NodeCountType'(0);
                                    for (int tid = 0; tid < SEARCH_THREAD_COUNT; tid++) begin
                                        search_best_move[tid] <= NULL_MOVE;
                                        search_ponder_move[tid] <= NULL_MOVE;
                                        search_root_best_score[tid] <= -MAX_EVAL_SCORE;
                                        search_root_has_completed_move[tid] <= 1'b0;
                                        search_root_best_exact[tid] <= 1'b0;
                                        search_thread_nodes[tid] <= NodeCountType'(0);
                                        search_thread_phase[tid] <= SEARCH_PHASE_IDLE;
                                        search_thread_target_depth[tid]
                                            <= (requested_search_depth(req) == SearchDepth'(0))
                                                ? SearchDepth'(0) : SearchDepth'(1);
                                        search_thread_root_alpha[tid] <= -MAX_EVAL_SCORE;
                                        search_thread_root_beta[tid] <= MAX_EVAL_SCORE;
                                        search_thread_aspiration_delta[tid] <= aspiration_initial_delta(tid);
                                        search_thread_aspiration_active[tid] <= 1'b0;
                                        search_thread_iteration_best_move[tid] <= NULL_MOVE;
                                        search_thread_iteration_ponder_move[tid] <= NULL_MOVE;
                                        search_thread_iteration_score[tid] <= EvalScore'(0);
`ifndef SYNTHESIS
                                        search_thread_completed_depth[tid] <= 8'd0;
                                        search_thread_completed_best_move[tid] <= NULL_MOVE;
`endif
                                        search_board_inflight[tid] <= 1'b0;
                                        search_move_inflight[tid] <= 1'b0;
                                        search_tt_lookup_inflight[tid] <= 1'b0;
                                        search_tt_response_pending[tid] <= 1'b0;
                                        search_repetition_pending[tid] <= 1'b0;
                                        search_repetition_done[tid] <= 1'b0;
                                        search_repetition_draw[tid] <= 1'b0;
                                        search_repetition_seen_before[tid] <= 1'b0;
                                        search_tt_validation_pending[tid] <= 1'b0;
                                        search_tt_validation_passed[tid] <= 1'b0;
                                        search_tt_validation_forced[tid] <= 1'b0;
                                        search_return_was_scout[tid] <= 1'b0;
                                        search_return_was_reduced[tid] <= 1'b0;
                                        search_return_was_null[tid] <= 1'b0;
                                        search_pvs_research[tid] <= 1'b0;
                                        search_return_ponder_move[tid] <= NULL_MOVE;
                                        nnue_plan_pending[tid] <= 1'b0;
                                        nnue_plan_inflight[tid] <= 1'b0;
                                        nnue_state_valid[tid] <= 1'b0;
                                    end
                                    for (int idx = 0; idx < SEARCH_BOARD_TAG_PIPE_LEN; idx++) begin
                                        search_board_tag_pipe[idx] <= ThreadID'(0);
                                        search_board_op_tag_pipe[idx] <= BOARD_IDLE_OP;
                                        search_board_ply_tag_pipe[idx] <= PlyIndex'(0);
                                        search_board_tag_valid_pipe[idx] <= 1'b0;
                                    end
                                    for (int idx = 0; idx < SEARCH_MOVE_TAG_PIPE_LEN; idx++) begin
                                        search_move_tag_pipe[idx] <= ThreadID'(0);
                                        search_move_tag_valid_pipe[idx] <= 1'b0;
                                        search_move_in_check_pipe[idx] <= 1'b0;
                                    end
                                    repetition_epoch <= repetition_epoch + 1'b1;
                                    // Time arithmetic starts from the registered request so the
                                    // command handshake cannot feed the timing-register muxes.
                                    state <= CTRL_SEARCH_TIME_SETUP;
                                end
                            end

                            ENGINE_CTRL_KILL: begin
                                repetition_epoch <= repetition_epoch + 1'b1;
                                resp_reg <= EngineControllerResponse'('0);
                                resp_reg.end_reason <= ENGINE_END_KILLED;
                                search_dispatch <= '0;
                                search_active_thread_count <= ThreadCount'(0);
                                for (int tid = 0; tid < SEARCH_THREAD_COUNT; tid++) begin
                                    search_board_inflight[tid] <= 1'b0;
                                    search_move_inflight[tid] <= 1'b0;
                                    search_tt_lookup_inflight[tid] <= 1'b0;
                                    search_tt_response_pending[tid] <= 1'b0;
                                    search_thread_phase[tid] <= SEARCH_PHASE_IDLE;
                                end
                                for (int idx = 0; idx < SEARCH_BOARD_TAG_PIPE_LEN; idx++) begin
                                    search_board_tag_pipe[idx] <= ThreadID'(0);
                                    search_board_op_tag_pipe[idx] <= BOARD_IDLE_OP;
                                    search_board_ply_tag_pipe[idx] <= PlyIndex'(0);
                                    search_board_tag_valid_pipe[idx] <= 1'b0;
                                end
                                for (int idx = 0; idx < SEARCH_MOVE_TAG_PIPE_LEN; idx++) begin
                                    search_move_tag_pipe[idx] <= ThreadID'(0);
                                    search_move_tag_valid_pipe[idx] <= 1'b0;
                                    search_move_in_check_pipe[idx] <= 1'b0;
                                end
                                state <= CTRL_FLUSH_RESPOND;
                            end

                            default: begin
                                resp_reg <= EngineControllerResponse'('0);
                                resp_reg.error <= 1'b1;
                                resp_reg.end_reason <= ENGINE_END_ERROR;
                                state <= CTRL_RESPOND;
                            end
                        endcase
                    end
                end

                CTRL_BOARD_ISSUE: begin
                    board_wait_count <= BoardWaitCount'(BOARD_UPDATE_PIPELINE_STAGE_CNT - 1);
                    state <= CTRL_BOARD_WAIT;
                end

                CTRL_BOARD_WAIT: begin
                    if (board_wait_count == BoardWaitCount'(0)) begin
                        active_board <= board_update_out;
                        active_board_in_check <= board_update_side_in_check;
                        active_zobrist_key <= board_update_zobrist_out;
                        active_pst_eval <= board_update_pst_out;
                        active_piece_count <= board_update_piece_count_out;
                        // Setup advances only after the shared pipeline result is committed.
                        if (active_req.operation == ENGINE_CTRL_NEW_GAME) begin
                            if (new_setup_index == 7'd67) begin
                                repetition_history_reset <= 1'b1;
                                repetition_history_key <= board_update_zobrist_out;
                                resp_reg <= EngineControllerResponse'('0);
                                state <= CTRL_DIRECT_DONE;
                            end else begin
                                new_setup_index <= new_setup_index + 7'd1;
                                state <= CTRL_BOARD_ISSUE;
                            end
                        end else begin
                            if (active_req.board_op == BOARD_COMMIT_MOVE_OP) begin
                                if (committed_move_is_irreversible(active_board, board_update_out, active_req.move)) begin
                                    repetition_history_reset <= 1'b1;
                                    repetition_history_key <= board_update_zobrist_out;
                                end else begin
                                    repetition_history_write <= 1'b1;
                                    repetition_history_key <= board_update_zobrist_out;
                                end
                            end else if (is_setup_op(active_req.board_op)) begin
                                repetition_history_reset <= 1'b1;
                                repetition_history_key <= board_update_zobrist_out;
                            end
                            resp_reg <= EngineControllerResponse'('0);
                            state <= CTRL_DIRECT_DONE;
                        end
                    end else begin
                        board_wait_count <= board_wait_count - BoardWaitCount'(1);
                    end
                end

                CTRL_DIRECT_DONE: begin
                    resp_valid <= 1'b1;
                    state <= CTRL_IDLE;
                end

                CTRL_NEW_CLEAR_START: begin
                    state <= CTRL_NEW_CLEAR_WAIT;
                end

                CTRL_NEW_CLEAR_WAIT: begin
                    if (!tt_clear_busy && !move_init_busy) begin
                        new_setup_index <= 7'd0;
                        state <= CTRL_BOARD_ISSUE;
                    end
                end

                CTRL_PERFT_GEN_ISSUE: begin
                    if (search_stack_top[0].move_order_state == MOVE_ORDER_DONE) begin
                        if (search_ply[0] == PlyIndex'(0)) begin
                            resp_reg <= EngineControllerResponse'('0);
                            resp_reg.nodes_count <= search_nodes;
                            resp_reg.completed_depth <= active_req.depth_limit;
                            resp_reg.end_reason <= ENGINE_END_DEPTH_LIMIT;
                            state <= CTRL_RESPOND;
                        end else begin
                            state <= CTRL_PERFT_REVERSE_ISSUE;
                        end
                    end else if ((move_cmd_valid && move_cmd_ready)
                            || (move_quiet_cmd_valid && move_quiet_cmd_ready)
                            || (move_pop_valid && move_pop_ready)) begin
                        state <= CTRL_PERFT_GEN_WAIT;
                    end
                end

                CTRL_PERFT_GEN_WAIT: begin
                    if (move_cmd_resp_valid && move_cmd_resp_thread == ThreadID'(0)) begin
                        search_stack_top[0].move_order_state <= MOVE_ORDER_GOOD_NOISY;
                        state <= CTRL_PERFT_GEN_ISSUE;
                    end else if (move_quiet_resp_valid
                            && move_quiet_resp_thread == ThreadID'(0)) begin
                        search_stack_top[0].move_order_state <= MOVE_ORDER_QUIET;
                        state <= CTRL_PERFT_GEN_ISSUE;
                    end else if (move_pop_resp_valid && move_pop_resp_thread == ThreadID'(0)) begin
                        if (move_pop_resp_found) begin
                            search_pending_move[0] <= move_pop_resp_move;
                            board_wait_count <= BoardWaitCount'(BOARD_UPDATE_PIPELINE_STAGE_CNT - 1);
                            state <= CTRL_PERFT_PUSH_WAIT;
                        end else begin
                            // Move-order state comparisons select distinct enum values.
                            unique case (1'b1)
                                (search_stack_top[0].move_order_state == MOVE_ORDER_GOOD_NOISY):
                                    search_stack_top[0].move_order_state <= MOVE_ORDER_GENERATE_QUIET;
                                (search_stack_top[0].move_order_state == MOVE_ORDER_QUIET):
                                    search_stack_top[0].move_order_state <= MOVE_ORDER_BAD_NOISY;
                                (search_stack_top[0].move_order_state == MOVE_ORDER_BAD_NOISY):
                                    search_stack_top[0].move_order_state <= MOVE_ORDER_LOW_QUIET;
                                default:
                                    search_stack_top[0].move_order_state <= MOVE_ORDER_DONE;
                            endcase
                            state <= CTRL_PERFT_GEN_ISSUE;
                        end
                    end
                end

                CTRL_PERFT_PUSH_ISSUE: begin
                    board_wait_count <= BoardWaitCount'(BOARD_UPDATE_PIPELINE_STAGE_CNT - 1);
                    state <= CTRL_PERFT_PUSH_WAIT;
                end

                CTRL_PERFT_PUSH_WAIT: begin
                    if (board_wait_count == BoardWaitCount'(0)) begin
                        if (board_update_mover_in_check) begin
                            state <= CTRL_PERFT_GEN_ISSUE;
                        end else if (int'(search_ply[0]) + 1 >= int'(active_req.depth_limit)) begin
                            search_nodes <= search_nodes + NodeCountType'(1);
                            state <= CTRL_PERFT_GEN_ISSUE;
                        end else begin
                            search_board[0] <= board_update_out;
                            search_board_in_check[0] <= board_update_side_in_check;
                            search_zobrist_key[0] <= board_update_zobrist_out;
                            search_pst_eval[0] <= board_update_pst_out;
                            search_piece_count[0] <= board_update_piece_count_out;
                            search_stack_top[0] <= empty_search_stack_entry();
                            search_stack_top[0].move_order_state <= MOVE_ORDER_GENERATE_NOISY;
                            search_ply[0] <= search_ply[0] + PlyIndex'(1);
                            state <= CTRL_PERFT_GEN_ISSUE;
                        end
                    end else begin
                        board_wait_count <= board_wait_count - BoardWaitCount'(1);
                    end
                end

                CTRL_PERFT_REVERSE_ISSUE: begin
                    board_wait_count <= BoardWaitCount'(BOARD_UPDATE_PIPELINE_STAGE_CNT - 1);
                    state <= CTRL_PERFT_REVERSE_WAIT;
                end

                CTRL_PERFT_REVERSE_WAIT: begin
                    if (board_wait_count == BoardWaitCount'(0)) begin
                        search_board[0] <= board_update_out;
                        search_board_in_check[0] <= board_update_side_in_check;
                        search_zobrist_key[0] <= board_update_zobrist_out;
                        search_pst_eval[0] <= board_update_pst_out;
                        search_piece_count[0] <= board_update_piece_count_out;
                        search_stack_top[0] <= search_stack_parent_q[0];
                        search_ply[0] <= search_ply[0] - PlyIndex'(1);
                        state <= CTRL_PERFT_GEN_ISSUE;
                    end else begin
                        board_wait_count <= board_wait_count - BoardWaitCount'(1);
                    end
                end

                // Time policy arithmetic is owned by the dedicated control-plane module.
                CTRL_SEARCH_TIME_SETUP: begin
                    time_setup_start <= 1'b1;
                    state <= CTRL_SEARCH_TIME_WAIT;
                end

                CTRL_SEARCH_TIME_WAIT: begin
                    if (time_management_done) begin
                        search_base_ms <= allocated_base_ms;
                        search_soft_ms <= allocated_soft_ms;
                        search_next_depth_ms <= allocated_next_depth_ms;
                        search_hard_ms <= allocated_hard_ms;
                        repetition_init_start <= 1'b1;
                        state <= CTRL_REPETITION_INIT;
                    end
                end

                CTRL_REPETITION_INIT: begin
                    if (repetition_init_failed) begin
                        resp_reg <= EngineControllerResponse'('0);
                        resp_reg.error <= 1'b1;
                        resp_reg.end_reason <= ENGINE_END_ERROR;
                        state <= CTRL_RESPOND;
                    // A repeated search starts from INIT_READY; wait for the
                    // one-cycle start pulse to be consumed before accepting done.
                    end else if (repetition_init_done && !repetition_init_start) begin
                        repetition_req_valid <= 1'b1;
                        repetition_req_thread <= ThreadID'(0);
                        repetition_req_ply <= PlyIndex'(0);
                        repetition_req_start_ply <= PlyIndex'(0);
                        repetition_req_key <= active_zobrist_key;
                        state <= CTRL_REPETITION_ROOT_WAIT;
                    end
                end

                CTRL_REPETITION_ROOT_WAIT: begin
                    if (repetition_resp_valid && repetition_resp_epoch == repetition_epoch) begin
                        if (repetition_resp_is_draw) begin
                            resp_reg <= EngineControllerResponse'('0);
                            resp_reg.score <= DRAW_EVAL_SCORE;
                            resp_reg.best_move <= NULL_MOVE;
                            resp_reg.end_reason <= ENGINE_END_DEPTH_LIMIT;
                            state <= CTRL_RESPOND;
                        end else begin
                            state <= CTRL_SEARCH_ITER_START;
                        end
                    end
                end

                CTRL_SEARCH_ITER_START: begin
                    for (int tid = 0; tid < SEARCH_THREAD_COUNT; tid++) begin
                        search_thread_phase[tid] <= SEARCH_PHASE_READY;
                        search_board[tid] <= active_board;
                        search_board_in_check[tid] <= active_board_in_check;
                        search_zobrist_key[tid] <= active_zobrist_key;
                        search_pst_eval[tid] <= active_pst_eval;
                        search_piece_count[tid] <= active_piece_count;
                        search_ply[tid] <= PlyIndex'(0);
                        search_repetition_seen_before[tid] <= 1'b0;
                        search_best_move[tid] <= NULL_MOVE;
                        search_ponder_move[tid] <= NULL_MOVE;
                        search_root_best_score[tid] <= -MAX_EVAL_SCORE;
                        search_root_has_completed_move[tid] <= 1'b0;
                        search_root_best_exact[tid] <= 1'b0;
                        search_pending_move[tid] <= NULL_MOVE;
                        search_pending_move_bucket[tid] <= QUIET_MEDIUM_BUCKET;
                        search_return_score[tid] <= EvalScore'(0);
                        search_return_valid[tid] <= 1'b0;
                        search_return_was_scout[tid] <= 1'b0;
                        search_return_was_reduced[tid] <= 1'b0;
                        search_return_was_null[tid] <= 1'b0;
                        search_pvs_research[tid] <= 1'b0;
                        search_return_ponder_move[tid] <= NULL_MOVE;
                        search_eval_is_stand_pat[tid] <= 1'b0;
                        search_eval_is_rfp[tid] <= 1'b0;
                        search_eval_is_futility[tid] <= 1'b0;
                        search_futility_eval_pending[tid] <= 1'b0;
                        search_node_init_pending[tid] <= 1'b0;
                        search_node_init_done[tid] <= 1'b0;
                        search_stack_top[tid] <= empty_search_stack_entry();
                        search_tt_validation_pending[tid] <= 1'b0;
                        search_tt_validation_passed[tid] <= 1'b0;
                        search_tt_validation_forced[tid] <= 1'b0;
                        search_stack_top[tid].remaining_depth <= search_thread_target_depth[tid];
                        search_stack_top[tid].alpha <= search_thread_root_alpha[tid];
                        search_stack_top[tid].beta <= search_thread_root_beta[tid];
                        search_stack_top[tid].stand_pat_done <= active_board_in_check;
                        search_stack_top[tid].node_in_check <= active_board_in_check;
                        search_stack_top[tid].unit_window
                            <= search_thread_root_beta[tid]
                                == score_successor(search_thread_root_alpha[tid]);
                        search_stack_top[tid].zero_window_node
                            <= search_thread_root_beta[tid]
                                == score_successor(search_thread_root_alpha[tid]);
                        search_return_move[tid] <= NULL_MOVE;
                    end
                    total_root_nodes <= NodeCountType'(0);
                    current_best_move_root_nodes <= NodeCountType'(0);
                    current_root_move_start_nodes <= NodeCountType'(0);
                    search_thread_id <= ThreadID'(0);
                    search_dispatch <= '0;
                    search_active_thread_count <= ThreadCount'(SEARCH_THREAD_COUNT);
                    if (!nnue_roots_initialized) begin
                        nnue_root_init_thread <= ThreadID'(0);
                        nnue_root_init_pos <= Position'(0);
                        nnue_root_init_first <= 1'b1;
                        nnue_root_init_draining <= 1'b0;
                        state <= CTRL_SEARCH_ROOT_INIT;
                    end else begin
                        state <= CTRL_SEARCH_RUN;
                    end
                end

                CTRL_SEARCH_ROOT_INIT: begin
                    automatic Tile root_tile =
                        search_board[nnue_root_init_thread].tiles[nnue_root_init_pos];
                    if (!nnue_root_init_draining) begin
                        if (root_tile.piece_type == NULL_PIECE
                                || (nnue_update_valid && nnue_update_ready)) begin
                            if (root_tile.piece_type != NULL_PIECE)
                                nnue_root_init_first <= 1'b0;
                            if (nnue_root_init_pos == Position'(63))
                                nnue_root_init_draining <= 1'b1;
                            else
                                nnue_root_init_pos <= nnue_root_init_pos + Position'(1);
                        end
                    end else if (nnue_update_idle) begin
                        nnue_state_valid[nnue_root_init_thread] <= 1'b1;
                        if (int'(nnue_root_init_thread) == SEARCH_THREAD_COUNT - 1) begin
                            nnue_roots_initialized <= 1'b1;
                            nnue_root_init_draining <= 1'b0;
                            state <= CTRL_SEARCH_RUN;
                        end else begin
                            nnue_root_init_thread <= nnue_root_init_thread + ThreadID'(1);
                            nnue_root_init_pos <= Position'(0);
                            nnue_root_init_first <= 1'b1;
                            nnue_root_init_draining <= 1'b0;
                        end
                    end
                end

                `include "hardware/rtl/search/search_run.svh"

                CTRL_RESPOND: begin
                    resp_valid <= 1'b1;
                    state <= CTRL_IDLE;
                end

                CTRL_FLUSH_RESPOND: begin
                    resp_valid <= 1'b1;
                    state <= CTRL_IDLE;
                end

                default: begin
                    resp_reg <= EngineControllerResponse'('0);
                    resp_reg.error <= 1'b1;
                    resp_reg.end_reason <= ENGINE_END_ERROR;
                    state <= CTRL_RESPOND;
                end
            endcase
            end
        end
    end
