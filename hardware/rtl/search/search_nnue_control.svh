// NNUE move progress, evaluation tags, plan handoff, and completion routing.
// Included in CTRL_SEARCH_RUN and CTRL_SEARCH_DRAIN so controller update precedence is preserved.

                    if (nnue_eval_enqueued) begin
                        nnue_eval_tag[nnue_eval_tag_write_ptr].thread_id <= nnue_build_thread;
                        nnue_eval_tag[nnue_eval_tag_write_ptr].ply
                            <= search_ply[nnue_build_thread];
                        nnue_eval_tag_write_ptr <= !nnue_eval_tag_write_ptr;
                        nnue_build_busy <= 1'b0;
                    end
                    if (nnue_eval_dequeued)
                        nnue_eval_tag_read_ptr <= !nnue_eval_tag_read_ptr;
                    // Enqueue-only and dequeue-only are disjoint; default holds the count.
                    unique case ({nnue_eval_enqueued, nnue_eval_dequeued})
                        2'b10: nnue_eval_tag_count <= nnue_eval_tag_count + 2'd1;
                        2'b01: nnue_eval_tag_count <= nnue_eval_tag_count - 2'd1;
                        default: nnue_eval_tag_count <= nnue_eval_tag_count;
                    endcase

                    if (!nnue_delta_busy && !nnue_build_busy
                            && nnue_plan_select_valid) begin
                        start_nnue_plan(nnue_plan_select_thread);
                    end

                    if (nnue_delta_busy && nnue_delta_update_valid && nnue_update_ready) begin
                        if (nnue_delta_update_req.complete) begin
                            nnue_plan_inflight[nnue_delta_thread] <= 1'b1;
                            if (nnue_plan_select_valid)
                                start_nnue_plan(nnue_plan_select_thread);
                            else nnue_delta_busy <= 1'b0;
                        end else nnue_delta_step <= nnue_delta_step + 3'd1;
                    end

                    if (nnue_update_done_valid) begin
                        automatic ThreadID completed_thread = nnue_update_done_thread;
                        automatic PlyIndex completed_ply = nnue_update_done_ply;
                        automatic logic repetition_completes_now =
                            repetition_resp_valid
                            && repetition_resp_epoch == repetition_epoch
                            && repetition_resp_thread == completed_thread
                            && search_repetition_pending[completed_thread];
                        automatic logic repetition_is_draw =
                            repetition_completes_now
                                ? repetition_resp_is_draw
                                : search_repetition_draw[completed_thread];
`ifndef SYNTHESIS
                        assert (nnue_plan_pending[completed_thread]
                                && nnue_plan_inflight[completed_thread]
                                && nnue_plan[completed_thread].child_ply == completed_ply)
                            else $fatal(1, "NNUE update completion tag does not own a child plan");
`endif
                        if (nnue_plan[completed_thread].reverse)
                            nnue_cached_reverses[completed_thread] <= '0;
                        else if (nnue_cached_reverses[completed_thread] != NnueSlot'(NNUE_CACHE_ENTRIES-1))
                            nnue_cached_reverses[completed_thread] <= nnue_cached_reverses[completed_thread] + NnueSlot'(1);
                        nnue_state_valid[completed_thread] <= 1'b1;
                        nnue_plan_pending[completed_thread] <= 1'b0;
                        nnue_plan_inflight[completed_thread] <= 1'b0;
                        if (nnue_plan[completed_thread].reverse) begin
                            search_thread_phase[completed_thread] <= SEARCH_PHASE_MOVE_WAIT;
                        end else if (nnue_plan[completed_thread].real_move) begin
                            if (search_repetition_done[completed_thread]
                                    || repetition_completes_now) begin
                                if (repetition_is_draw) begin
                                    search_return_score[completed_thread]
                                        <= DRAW_EVAL_SCORE;
                                    search_return_valid[completed_thread] <= 1'b1;
                                    search_thread_phase[completed_thread]
                                        <= SEARCH_PHASE_REVERSE_WAIT;
                                end else begin
                                    search_thread_phase[completed_thread]
                                        <= SEARCH_PHASE_READY;
                                end
                            end
                        end else begin
                            search_thread_phase[completed_thread] <= SEARCH_PHASE_READY;
                        end
                    end
