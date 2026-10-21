// Construct board, move, TT, and timer requests from the scheduler's selected tags.
// Included in search_controller scope; readiness does not select request payloads.

    // Board operations use the selected context without reading pipeline readiness.
    always_comb begin
        board_update_op = BOARD_IDLE_OP;
        board_update_in = active_board;
        board_update_zobrist_in = active_zobrist_key;
        board_update_pst_in = active_pst_eval;
        board_update_piece_count_in = active_piece_count;
        board_update_move = active_req.move;
        board_update_set_data = active_req.board_wr_data;
        board_update_thread_id = (state == CTRL_SEARCH_RUN) ? search_board_issue_thread : ThreadID'(0);
        board_update_ply = PlyIndex'(0);

        // Command ownership is registered before the first operation. Select
        // wide payloads from that stable ownership, outside live admission and
        // perft response decoding; idle operations cannot publish the payload.
        if (is_search_operation(active_req.operation)) begin
            board_update_in = search_board[search_board_issue_thread];
            board_update_zobrist_in = search_zobrist_key[search_board_issue_thread];
            board_update_pst_in = search_pst_eval[search_board_issue_thread];
            board_update_piece_count_in = search_piece_count[search_board_issue_thread];
            board_update_ply = search_ply[search_board_issue_thread];
        end else if (active_req.operation == ENGINE_CTRL_PERFT) begin
            // Perft borrows context zero without owning a duplicate position.
            board_update_in = search_board[0];
            board_update_zobrist_in = search_zobrist_key[0];
            board_update_pst_in = search_pst_eval[0];
            board_update_piece_count_in = search_piece_count[0];
            board_update_ply = search_ply[0];
        end

        if (state == CTRL_BOARD_ISSUE) begin
            // New Game uses the same issue and writeback path as direct board updates.
            if (active_req.operation == ENGINE_CTRL_NEW_GAME) begin
                board_update_op = setup_req_comb.board_op;
                board_update_move = setup_req_comb.move;
                board_update_set_data = setup_req_comb.board_wr_data;
            end else begin
                board_update_op = active_req.board_op;
            end
        end else if (state == CTRL_PERFT_GEN_WAIT
                && move_pop_resp_valid && move_pop_resp_thread == ThreadID'(0)
                && move_pop_resp_found) begin
            board_update_op = BOARD_PUSH_MOVE_OP;
            board_update_move = move_pop_resp_move;
        end else if (state == CTRL_PERFT_PUSH_ISSUE || state == CTRL_PERFT_REVERSE_ISSUE) begin
            board_update_op = (state == CTRL_PERFT_REVERSE_ISSUE) ? BOARD_REVERSE_MOVE_OP : BOARD_PUSH_MOVE_OP;
            board_update_move = search_pending_move[0];
        end else if (state == CTRL_SEARCH_RUN) begin
            // Select wide context independently of admission. Only the narrow
            // operation needs validity; idle payloads cannot publish a result.
            board_update_op = !search_board_issue_valid ? BOARD_IDLE_OP
                : search_board_issue_is_null
                ? BOARD_PUSH_NULL_OP
                : !move_board_bypass_valid
                    && search_thread_phase[search_board_issue_thread] == SEARCH_PHASE_REVERSE_WAIT
                ? BOARD_REVERSE_MOVE_OP : BOARD_PUSH_MOVE_OP;
            board_update_move = move_board_bypass_valid
                ? move_board_bypass_move
                : |search_board_mask
                ? search_pending_move[search_board_work_thread] : NULL_MOVE;
        end

    end

    // Move-generation commands and perft bucket pops.
    always_comb begin
        move_cmd_valid = 1'b0;
        move_cmd = MOVE_GEN_GENERATE_NOISY;
        // Preselect the entire context before valid decoding so command readiness
        // does not receive an extra valid-controlled thread, ply, or board mux.
        move_cmd_thread = search_move_issue_thread;
        move_cmd_ply = search_ply[search_move_issue_thread];
        move_cmd_board = search_board[search_move_issue_thread];
        move_cmd_in_check = search_board_in_check[search_move_issue_thread];
        move_cmd_suppress_valid = 1'b0;
        move_cmd_suppress_move = NULL_MOVE;
        move_quiet_cmd_valid = 1'b0;
        move_quiet_cmd_thread = search_quiet_issue_thread;
        move_quiet_cmd_ply = search_ply[search_quiet_issue_thread];
        move_quiet_cmd_board = search_board[search_quiet_issue_thread];
        move_quiet_cmd_in_check = search_board_in_check[search_quiet_issue_thread];
        move_quiet_cmd_suppress_valid = 1'b0;
        move_quiet_cmd_suppress_move = NULL_MOVE;
        move_pop_valid = 1'b0;
        // Shared pop continuations select only a thread; each reader uses its
        // locally owned ply without a command-selection mux.
        move_pop_thread = search_move_issue_thread;
        if (state == CTRL_PERFT_GEN_ISSUE) begin
            move_cmd_thread = ThreadID'(0);
            move_cmd_ply = search_ply[0];
            move_cmd_board = search_board[0];
            move_cmd_in_check = search_board_in_check[0];
            move_pop_thread = ThreadID'(0);
            // Move-order states have distinct encodings.
            unique case (search_stack_top[0].move_order_state)
                MOVE_ORDER_GENERATE_NOISY: begin
                    move_cmd = MOVE_GEN_GENERATE_NOISY;
                    move_cmd_valid = 1'b1;
                end
                MOVE_ORDER_GOOD_NOISY: begin
                    move_pop_valid = 1'b1;
                end
                MOVE_ORDER_GENERATE_QUIET: begin
                    move_quiet_cmd_valid = 1'b1;
                    move_quiet_cmd_thread = ThreadID'(0);
                    move_quiet_cmd_ply = search_ply[0];
                    move_quiet_cmd_board = search_board[0];
                    move_quiet_cmd_in_check = search_board_in_check[0];
                end
                MOVE_ORDER_QUIET: begin
                    move_pop_valid = 1'b1;
                end
                MOVE_ORDER_BAD_NOISY, MOVE_ORDER_LOW_QUIET: begin
                    move_pop_valid = 1'b1;
                end
                default: begin end
            endcase
        end else if (search_move_issue_valid) begin
            automatic Move order_move = ordering_move_for_thread(search_move_issue_thread);
            move_cmd_thread = search_move_issue_thread;
            move_cmd_ply = search_ply[search_move_issue_thread];
            move_cmd_board = search_board[search_move_issue_thread];
            move_cmd_in_check = search_board_in_check[search_move_issue_thread];
            move_cmd_suppress_valid = search_stack_top[search_move_issue_thread].direct_attempted;
            move_cmd_suppress_move = search_stack_top[search_move_issue_thread].tt_move;
            move_cmd_valid = 1'b1;
            if (search_direct_command[search_move_issue_thread]) begin
                move_cmd = MOVE_GEN_VALIDATE_DIRECT;
                move_cmd_suppress_valid = 1'b1;
                move_cmd_suppress_move = order_move;
            end else begin
                move_cmd = MOVE_GEN_GENERATE_NOISY;
            end
        end

        if (state == CTRL_SEARCH_RUN && search_quiet_issue_valid) begin
            move_quiet_cmd_valid = 1'b1;
            move_quiet_cmd_thread = search_quiet_issue_thread;
            move_quiet_cmd_ply = search_ply[search_quiet_issue_thread];
            move_quiet_cmd_board = search_board[search_quiet_issue_thread];
            move_quiet_cmd_in_check = search_board_in_check[search_quiet_issue_thread];
            move_quiet_cmd_suppress_valid =
                search_stack_top[search_quiet_issue_thread].direct_attempted;
            move_quiet_cmd_suppress_move =
                search_stack_top[search_quiet_issue_thread].tt_move;
        end


    end

    // Publish one pending quiet-history update independently of pipeline dispatch.
    always_comb begin
        move_history_update_valid = 1'b0;
        move_history_update_thread = ThreadID'(0);
        move_history_update_color = WHITE;
        move_history_update_from = Position'(0);
        move_history_update_to = Position'(0);
        move_history_update_depth = PlyIndex'(0);
        move_history_update_failed0 = 12'd0;
        move_history_update_failed1 = 12'd0;
        move_history_update_failed2 = 12'd0;
        move_history_update_failed_count = 2'd0;
        for (int idx = 0; idx < SEARCH_THREAD_COUNT; idx++) begin
            if (!move_history_update_valid && history_update_pending[idx]) begin
                move_history_update_valid = 1'b1;
                move_history_update_thread = ThreadID'(idx);
                move_history_update_color = history_update_pending_color[idx];
                move_history_update_from = history_update_pending_from[idx];
                move_history_update_to = history_update_pending_to[idx];
                move_history_update_depth = history_update_pending_depth[idx];
                move_history_update_failed0 = history_update_pending_failed0[idx];
                move_history_update_failed1 = history_update_pending_failed1[idx];
                move_history_update_failed2 = history_update_pending_failed2[idx];
                move_history_update_failed_count = history_update_pending_failed_count[idx];
            end
        end

    end

    // TT probes use their selected lookup tag independently of store publication.
    always_comb begin
        tt_lookup_req_valid = search_tt_lookup_issue_valid;
        tt_lookup_req = TTLookupRequest'('0);
        tt_lookup_req.thread_id = (state == CTRL_SEARCH_RUN) ? search_tt_lookup_issue_thread : search_thread_id;
        tt_lookup_req.zobrist_key = search_zobrist_key[tt_lookup_req.thread_id];
        tt_lookup_req.depth = search_remaining_depth(tt_lookup_req.thread_id);
        tt_lookup_req.alpha = search_stack_top[tt_lookup_req.thread_id].alpha;
        tt_lookup_req.beta = search_stack_top[tt_lookup_req.thread_id].beta;
        tt_lookup_req.ply = search_ply[tt_lookup_req.thread_id];

    end

    // Decode each local store before arbitration selects its payload, keeping
    // scheduler selection out of bound comparison and promotion-tile lookup.
    always_comb begin
        TTStoreRequest local_stores[THREAD_COUNT];
        for (int tid = 0; tid < THREAD_COUNT; tid++) begin
            local_stores[tid] = TTStoreRequest'('0);
            local_stores[tid].zobrist_key = search_zobrist_key[tid];
            local_stores[tid].depth = search_remaining_depth(tid);
            local_stores[tid].score = search_return_score[tid];
            local_stores[tid].bound_type = tt_bound_for_score(
                search_return_score[tid], search_original_alpha(tid),
                search_stack_top[tid].beta);
            local_stores[tid].best_move = search_stack_top[tid].best_move;
            // Underpromotions cannot be represented by the external TT entry.
            if (is_promotion_move(search_board[tid], local_stores[tid].best_move)
                    && local_stores[tid].best_move.promo_piece != PROMO_QUEEN)
                local_stores[tid].best_move = NULL_MOVE;
            local_stores[tid].age = tt_age;
            local_stores[tid].ply = search_ply[tid];
        end
        tt_store_req_valid = search_tt_store_issue_valid;
        tt_store_req = local_stores[search_tt_store_issue_thread];
    end

    assign move_pop_ready = move_pop_ready_vec[move_pop_thread];

    // Independent bucket readers and move-storage initialization.
    always_comb begin
        // Each search thread can launch a bucket pop independently. The
        // shared controller consumes completed results one per cycle while
        // every reader retains its own result until selected here.
        for (int tid = 0; tid < SEARCH_THREAD_COUNT; tid++) begin
            automatic MoveOrderState order_state = search_stack_top[tid].move_order_state;
            move_bad_noisy_enable[tid] = 1'b0;
            move_node_init_valid[tid] = 1'b0;
            move_node_init_ply[tid] = PlyIndex'(0);
            if (state == CTRL_SEARCH_RUN && search_node_init_pending[tid]) begin
                move_node_init_valid[tid] = 1'b1;
                move_node_init_ply[tid] = search_ply[tid];
            end
            move_pop_valid_vec[tid] = state == CTRL_SEARCH_RUN
                && search_thread_move_ready(tid) && move_state_uses_pop(order_state);
            // Every pop addresses its own thread's current ply, including shared
            // perft; keep command selection out of this payload.
            move_pop_ply_vec[tid] = search_ply[tid];
            if (move_pop_valid && move_pop_thread == ThreadID'(tid)) begin
                move_pop_valid_vec[tid] = 1'b1;
            end
            move_pop_resp_ready_vec[tid] = move_pop_resp_valid
                && move_pop_response_thread == ThreadID'(tid);
        end
    end

    // Operation timers depend only on the controller lifecycle state.
    always_comb begin
        timer_rst = (state == CTRL_IDLE);
        timer_run = ((state == CTRL_PERFT_GEN_ISSUE)
            || (state == CTRL_PERFT_GEN_WAIT)
            || (state == CTRL_PERFT_PUSH_ISSUE)
            || (state == CTRL_PERFT_PUSH_WAIT)
            || (state == CTRL_PERFT_REVERSE_ISSUE)
            || (state == CTRL_PERFT_REVERSE_WAIT))
            || (state == CTRL_SEARCH_ITER_START)
            || (state == CTRL_SEARCH_ROOT_INIT)
            || (state == CTRL_SEARCH_RUN);
        time_management_cancel = state != CTRL_SEARCH_TIME_SETUP
            && state != CTRL_SEARCH_TIME_WAIT
            && state != CTRL_SEARCH_RUN;
    end
