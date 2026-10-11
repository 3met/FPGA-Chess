// Registered stop/pruning checks, eligibility masks, and shared-pipeline arbitration.
// Included in search_controller scope; this file is not a standalone compilation unit.

    // Budget comparators have their own register boundary instead of gating
    // every search-state update. A reached budget is observed one clock later.
    always_ff @(posedge clk) begin
        if (!rst_n || state != CTRL_SEARCH_RUN) begin
            search_node_stop_q <= 1'b0;
            search_time_stop_q <= 1'b0;
        end else begin
            search_node_stop_q <= active_req.operation == ENGINE_CTRL_SEARCH_NODES
                && search_nodes >= active_req.node_limit;
            search_time_stop_q <= (active_req.operation == ENGINE_CTRL_SEARCH_FIXED_TIME
                    || active_req.operation == ENGINE_CTRL_SEARCH_ON_CLOCK)
                && elapsed_ms >= search_hard_ms;
        end
    end

    // Classify the unchanged parent one stage before the board result arrives.
    // Only the child's check flag remains to be applied at commitment, keeping
    // move decoding and margin arithmetic off the child-state write path.
    always_ff @(posedge clk) begin
        if (!rst_n) begin
            parent_futility_eligible_q <= 1'b0;
            parent_futility_prunes_q <= 1'b0;
            parent_qdelta_prunes_q <= 1'b0;
        end else if (state == CTRL_SEARCH_RUN
                && search_board_tag_valid_pipe[SEARCH_BOARD_TAG_PIPE_LEN - 2]) begin
            automatic ThreadID thread_id =
                search_board_tag_pipe[SEARCH_BOARD_TAG_PIPE_LEN - 2];
            parent_futility_eligible_q <= futility_move_eligible(
                search_ply[thread_id], search_pending_child_depth[thread_id],
                search_board_in_check[thread_id], 1'b0,
                is_quiet_move(search_board[thread_id], search_pending_move[thread_id]),
                is_promotion_move(search_board[thread_id], search_pending_move[thread_id]),
                search_stack_top[thread_id].has_tt_move
                    && search_pending_move[thread_id] == search_stack_top[thread_id].tt_move,
                search_stack_top[thread_id].has_legal, search_pvs_research[thread_id]);
            parent_futility_prunes_q <= futility_prunes(
                search_stack_top[thread_id].static_eval,
                search_stack_top[thread_id].alpha, search_pending_child_depth[thread_id]);
            parent_qdelta_prunes_q <= search_in_qsearch(thread_id) && qdelta_move_prunes(
                search_board[thread_id], search_stack_top[thread_id].move,
                search_pending_move[thread_id], search_stack_top[thread_id].static_eval,
                search_stack_top[thread_id].alpha, search_board_in_check[thread_id], 1'b0);
        end
    end

    // Readiness acknowledges the selected follow-up but never selects its payload.
    assign move_followup_accepted =
            (move_followup_action == MOVE_FOLLOWUP_NOISY_CMD && move_cmd_ready)
            || (move_followup_action == MOVE_FOLLOWUP_POP_BAD && move_pop_ready)
            || (move_followup_uses_quiet && move_quiet_cmd_ready);

    assign setup_req_comb = new_game_setup_request(new_setup_index);

    // Classify ready work and choose a context for each shared pipeline.
    always_comb begin
        search_store_mask = '0;
        search_board_mask = '0;
        search_move_mask = '0;
        search_quiet_mask = '0;
        search_eval_mask = '0;
        search_tt_lookup_mask = '0;
        search_return_mask = '0;
        search_tt_response_mask = '0;
        search_null_mask = '0;
        search_terminal_mask = '0;
        search_terminal_no_move_mask = '0;
        for (int idx = 0; idx < SEARCH_THREAD_COUNT; idx++) begin
            automatic Move order_move = ordering_move_for_thread(ThreadID'(idx));
            automatic logic direct_init_needed;
            automatic logic null_init_needed = search_thread_null_ready(idx);
            // Decode command kind before thread selection so a wide move mux
            // and null-move comparison do not follow shared arbitration.
            search_direct_command[idx] = search_stack_top[idx].move_order_state == MOVE_ORDER_DIRECT
                && !is_null_move(order_move);
            direct_init_needed = search_thread_move_ready(idx) && search_direct_command[idx];
            search_node_init_request[idx]
                = !search_node_init_done[idx]
                    && (direct_init_needed || null_init_needed);
            search_store_mask[idx] = search_thread_store_pending(idx);
            search_board_mask[idx] = search_thread_board_pending(idx)
                || search_thread_reverse_pending(idx);
            // Only generation/direct commands share lane arbitration; bucket
            // pops use each thread's independent ready/valid channel.
            search_move_mask[idx] = search_thread_move_ready(idx)
                && !move_state_uses_pop(search_stack_top[idx].move_order_state)
                && !search_node_init_request[idx];
            search_quiet_mask[idx] = search_thread_quiet_ready(idx);
            search_eval_mask[idx] = search_thread_eval_ready(idx)
                && (!(nnue_delta_busy || nnue_plan_any)
                    || nnue_state_valid[idx]);
            search_tt_lookup_mask[idx] = search_thread_tt_lookup_ready(idx)
                && !tt_transport_pending[idx];
            search_return_mask[idx] = search_thread_return_pending(idx);
            search_tt_response_mask[idx] = search_thread_tt_response_pending(idx);
            search_null_mask[idx] = search_thread_null_ready(idx)
                && !search_node_init_request[idx];
            search_terminal_mask[idx] = search_thread_terminal_ready(idx);
            search_terminal_no_move_mask[idx] = search_terminal_mask[idx]
                && search_stack_top[idx].move_order_state == MOVE_ORDER_DONE
                && !(search_board[idx].halfmove_clock >= HalfmoveClock'(100)
                    && search_stack_top[idx].has_legal);
        end
        // Always consume a registered response. Keeping backend response
        // routing separate from score/window decisions breaks the bypass path
        // through TT classification into the board and move schedulers.
        search_tt_consume_valid = state == CTRL_SEARCH_RUN && |search_tt_response_mask;
        search_tt_consume_thread = search_select_thread(
            search_tt_response_mask, search_dispatch.tt_response);
        search_tt_consume_response = search_tt_response[search_tt_consume_thread];

        move_board_bypass_valid = state == CTRL_SEARCH_RUN
            && ((move_pop_resp_valid && move_pop_resp_found)
                || (move_cmd_resp_valid && move_cmd_resp_direct_valid));
        move_board_bypass_thread = move_pop_resp_valid && move_pop_resp_found
            ? move_pop_resp_thread : move_cmd_resp_thread;
        move_board_bypass_move = move_pop_resp_valid && move_pop_resp_found
            ? move_pop_resp_move : move_cmd_resp_direct_move;

        // A response is visible after its lane has returned idle. Prefer one
        // same-thread continuation over a newly selected request so move
        // ordering does not spend a READY scheduler cycle between operations.
        move_followup_action = MOVE_FOLLOWUP_NONE;
        move_followup_thread = ThreadID'(0);
        if (state == CTRL_SEARCH_RUN && move_cmd_resp_valid
                && !search_generation_inflight[move_cmd_resp_thread]
                && !move_cmd_resp_direct_valid) begin
            move_followup_thread = move_cmd_resp_thread;
            move_followup_action = MOVE_FOLLOWUP_NOISY_CMD;
        end else if (state == CTRL_SEARCH_RUN && move_pop_resp_valid
                && !move_pop_resp_found
                && !search_generation_inflight[move_pop_resp_thread]) begin
            move_followup_thread = move_pop_resp_thread;
            case (search_stack_top[move_pop_resp_thread].move_order_state)
                MOVE_ORDER_GOOD_NOISY:
                    if (!(search_in_qsearch(move_pop_resp_thread)
                            && !search_board_in_check[move_pop_resp_thread]))
                        move_followup_action = MOVE_FOLLOWUP_QUIET_CMD;
                MOVE_ORDER_QUIET, MOVE_ORDER_BAD_NOISY:
                    move_followup_action = MOVE_FOLLOWUP_POP_BAD;
                default: begin end
            endcase
        end
        move_followup_uses_move = move_followup_action == MOVE_FOLLOWUP_NOISY_CMD
            || move_followup_action == MOVE_FOLLOWUP_POP_BAD;
        move_followup_uses_quiet =
            move_followup_action == MOVE_FOLLOWUP_QUIET_CMD;
        search_null_issue_valid = (state == CTRL_SEARCH_RUN)
            && !move_board_bypass_valid
            && !(|search_board_mask)
            && |search_null_mask;
        search_board_issue_valid = (state == CTRL_SEARCH_RUN)
            && (move_board_bypass_valid
                || |search_board_mask
                || search_null_issue_valid);
        search_move_issue_valid = (state == CTRL_SEARCH_RUN)
            && !move_followup_uses_move
            && |search_move_mask;
        search_quiet_issue_valid = (state == CTRL_SEARCH_RUN)
            && !move_followup_uses_quiet
            && |search_quiet_mask;
        search_eval_issue_valid = (state == CTRL_SEARCH_RUN)
            && !nnue_build_busy
            && |search_eval_mask;
        search_tt_lookup_issue_valid = (state == CTRL_SEARCH_RUN)
            && |search_tt_lookup_mask;
        search_tt_store_issue_valid = (state == CTRL_SEARCH_RUN)
            && |search_store_mask;
        // Keep null eligibility out of the normal move payload mux. A null
        // board operation ignores move_in, but allowing its thread choice to
        // select that payload creates an unnecessary depth-to-board path.
        search_board_work_thread = search_select_thread(
            search_board_mask, search_dispatch.board);
        search_null_issue_thread = search_select_thread(
            search_null_mask, search_dispatch.board);
        search_board_issue_thread = move_board_bypass_valid
            ? move_board_bypass_thread
            : |search_board_mask
            ? search_board_work_thread : search_null_issue_thread;
        // Forward live pop metadata on immediate issue; pending registers update
        // on the same edge and still describe the previous candidate here.
        search_board_issue_bucket = move_board_bypass_valid
            ? (move_pop_resp_valid && move_pop_resp_found
                ? move_pop_resp_bucket : QUIET_MEDIUM_BUCKET)
            : search_pending_move_bucket[search_board_issue_thread];
        // Derive the operation kind from the selected source so this remains
        // correct if the null-request valid qualification is later refactored.
        search_board_issue_is_null = !move_board_bypass_valid
            && !(|search_board_mask)
            && search_null_issue_valid;
        search_move_issue_thread = search_select_thread(
            search_move_mask, search_dispatch.move);
        search_quiet_issue_thread = search_select_thread(
            search_quiet_mask, search_dispatch.quiet);
        search_eval_issue_thread = search_eval_issue_valid
            ? search_select_thread(search_eval_mask, search_dispatch.eval)
            : ThreadID'(0);
    end

    // Store selection must not depend on the bank-aware lookup choice.
    assign search_tt_store_issue_thread = search_select_thread(
        search_store_mask, search_dispatch.tt_store);

    // Favor probes in a different bank from the independently selected store.
    always_comb begin
        // Request payloads are sampled only when their valid signal is set, so
        // keep validity out of these wide thread-selected data paths.
        // Prefer a ready probe in the bank not needed by the staged store.
        tt_noncolliding_lookup_mask = '0;
        for (int tid = 0; tid < SEARCH_THREAD_COUNT; tid++)
            tt_noncolliding_lookup_mask[tid] = search_tt_lookup_mask[tid]
                && search_zobrist_key[tid][$bits(ZobristKey)-1] != tt_store_bank;
        search_tt_lookup_issue_thread = search_select_thread(
            tt_store_bank_valid && |tt_noncolliding_lookup_mask
                ? tt_noncolliding_lookup_mask : search_tt_lookup_mask, search_dispatch.tt_lookup);
    end
