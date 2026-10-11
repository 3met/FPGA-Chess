// Independent iterative-deepening passes, aspiration retries, and primary time decisions.
// Included in CTRL_SEARCH_RUN so helper threads and stop decisions keep their ordering.

                    // Clock-search iteration decisions are deliberately staged.
                    // Only registered timing values may control root-state reloads.
                    if (search_thread_phase[0] == SEARCH_PHASE_TIME_SCALE) begin
                        time_adaptive_start <= 1'b1;
                        search_thread_phase[0] <= SEARCH_PHASE_TIME_SCALE_WAIT;
                    end else if (search_thread_phase[0] == SEARCH_PHASE_TIME_SCALE_WAIT) begin
                        if (time_management_done) begin
                            search_soft_ms <= allocated_soft_ms;
                            search_next_depth_ms <= allocated_next_depth_ms;
                            search_thread_phase[0] <= SEARCH_PHASE_TIME_CHECK;
                        end
                    end else if (search_thread_phase[0] == SEARCH_PHASE_TIME_CHECK) begin
                        if (elapsed_ms >= search_next_depth_ms) begin
                            resp_reg <= EngineControllerResponse'('0);
                            resp_reg.best_move <= search_completed_best_move;
                            resp_reg.ponder_move <= search_completed_ponder_move;
                            resp_reg.score <= search_completed_score;
                            resp_reg.nodes_count <= search_nodes;
                            resp_reg.completed_depth <= search_completed_depth;
                            resp_reg.end_reason <= ENGINE_END_TIME_LIMIT;
                            state <= CTRL_FLUSH_RESPOND;
                        end else begin
                            search_thread_target_depth[0]
                                <= search_thread_target_depth[0] + SearchDepth'(1);
                            search_thread_root_alpha[0] <= aspiration_lower_bound(
                                search_thread_iteration_score[0], aspiration_initial_delta(0));
                            search_thread_root_beta[0] <= aspiration_upper_bound(
                                search_thread_iteration_score[0], aspiration_initial_delta(0));
                            search_thread_aspiration_delta[0] <= aspiration_initial_delta(0);
                            search_thread_aspiration_active[0] <= 1'b1;
                            restart_search_thread(0, 1'b0, aspiration_initial_delta(0));
                            active_count_next += ThreadCount'(1);
                        end
                    end

                    // Each Lazy SMP context owns its iterative-deepening loop.
                    // A completed helper immediately retries a failed aspiration
                    // pass or starts its next depth without waiting for peers.
                    for (int tid = 0; tid < SEARCH_THREAD_COUNT; tid++) begin
                        if (search_thread_phase[tid] == SEARCH_PHASE_DONE) begin
                            automatic logic aspiration_failed;
                            automatic logic primary_thread;
                            automatic logic depth_finished;
                            automatic logic [7:0] completed_stable_depths;
                            automatic logic [3:0] completed_soft_factor;
                            automatic AspirationDelta next_aspiration_delta;

                            aspiration_failed = search_thread_aspiration_active[tid]
                                && (search_thread_iteration_score[tid] <= search_thread_root_alpha[tid]
                                    || search_thread_iteration_score[tid] >= search_thread_root_beta[tid]);
                            primary_thread = tid == 0;
                            depth_finished = search_thread_target_depth[tid] >= search_max_depth;
                            completed_stable_depths = best_move_stable_depths;
                            completed_soft_factor = pending_soft_factor;
                            if (primary_thread && !aspiration_failed) begin
                                completed_stable_depths = (search_thread_iteration_best_move[tid]
                                        == previous_depth_best_move)
                                    ? best_move_stable_depths + 8'd1 : 8'd1;
                                completed_soft_factor = adaptive_soft_factor(
                                    search_thread_iteration_best_move[tid],
                                    search_thread_iteration_score[tid],
                                    completed_stable_depths,
                                    total_root_nodes,
                                    current_best_move_root_nodes
                                );
                            end
                            next_aspiration_delta = aspiration_failed
                                ? aspiration_next_delta(search_thread_aspiration_delta[tid])
                                : aspiration_initial_delta(tid);

                            if (aspiration_failed) begin
                                // Retry the same depth with a wider window centered on
                                // the fail-soft value returned by the previous pass.
                                search_thread_root_alpha[tid] <= aspiration_lower_bound(
                                    search_thread_iteration_score[tid], next_aspiration_delta);
                                search_thread_root_beta[tid] <= aspiration_upper_bound(
                                    search_thread_iteration_score[tid], next_aspiration_delta);
                                search_thread_aspiration_delta[tid] <= next_aspiration_delta;
                            end else begin
`ifndef SYNTHESIS
                                search_thread_completed_depth[tid] <= 8'(search_thread_target_depth[tid]);
`endif
                                if (primary_thread) begin
                                    search_completed_depth <= search_thread_target_depth[tid];
                                    search_completed_best_move <= search_thread_iteration_best_move[tid];
                                    search_completed_ponder_move <= search_thread_iteration_ponder_move[tid];
                                    search_completed_score <= search_thread_iteration_score[tid];
                                    previous_depth_best_move <= search_thread_iteration_best_move[tid];
                                    best_move_stable_depths <= completed_stable_depths;
                                    previous_depth_score <= search_thread_iteration_score[tid];
                                    pending_soft_factor <= completed_soft_factor;
                                    pending_single_legal_move
                                        <= search_stack_top[tid].legal_move_count == 8'd1;
                                end
                                if (!depth_finished && primary_thread
                                        && active_req.operation == ENGINE_CTRL_SEARCH_ON_CLOCK) begin
                                    search_thread_phase[tid] <= SEARCH_PHASE_TIME_SCALE;
                                end else if (!depth_finished) begin
                                    search_thread_target_depth[tid] <= search_thread_target_depth[tid] + SearchDepth'(1);
                                    search_thread_root_alpha[tid]
                                        <= aspiration_lower_bound(search_thread_iteration_score[tid], aspiration_initial_delta(tid));
                                    search_thread_root_beta[tid]
                                        <= aspiration_upper_bound(search_thread_iteration_score[tid], aspiration_initial_delta(tid));
                                    search_thread_aspiration_delta[tid] <= aspiration_initial_delta(tid);
                                    search_thread_aspiration_active[tid] <= 1'b1;
                                end
                            end

                            if (primary_thread && !aspiration_failed && depth_finished) begin
                                resp_reg <= EngineControllerResponse'('0);
                                resp_reg.best_move <= search_thread_iteration_best_move[tid];
                                resp_reg.ponder_move <= search_thread_iteration_ponder_move[tid];
                                resp_reg.score <= search_thread_iteration_score[tid];
                                resp_reg.nodes_count <= search_nodes;
                                resp_reg.completed_depth <= search_thread_target_depth[tid];
                                resp_reg.end_reason <= ENGINE_END_DEPTH_LIMIT;
                                state <= CTRL_FLUSH_RESPOND;
                            end else if ((!depth_finished || aspiration_failed)
                                    && !(primary_thread && !aspiration_failed
                                        && active_req.operation == ENGINE_CTRL_SEARCH_ON_CLOCK)) begin
                                restart_search_thread(tid, aspiration_failed, next_aspiration_delta);
                                active_count_next += ThreadCount'(1);
                            end
                        end
                    end

                    for (int idx = SEARCH_BOARD_TAG_PIPE_LEN - 1; idx > 0; idx--) begin
                        search_board_tag_pipe[idx] <= search_board_tag_pipe[idx - 1];
                        search_board_op_tag_pipe[idx] <= search_board_op_tag_pipe[idx - 1];
                        search_board_ply_tag_pipe[idx] <= search_board_ply_tag_pipe[idx - 1];
                        search_board_tag_valid_pipe[idx] <= search_board_tag_valid_pipe[idx - 1];
                    end
                    search_board_tag_pipe[0] <= search_board_issue_thread;
                    search_board_op_tag_pipe[0] <= board_update_op;
                    search_board_ply_tag_pipe[0] <= board_update_ply;
                    search_board_tag_valid_pipe[0] <= search_board_issue_valid;
                    for (int idx = 0; idx < SEARCH_MOVE_TAG_PIPE_LEN; idx++) begin
                        search_move_tag_valid_pipe[idx] <= 1'b0;
                    end
