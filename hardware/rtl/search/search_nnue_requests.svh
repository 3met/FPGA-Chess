// NNUE plan arbitration, serial board setup requests, and physical update formatting.
// Included in search_controller scope; arbitration adds no register boundary.

    // Start a selected or newly prepared plan without adding an issue-cycle bubble.
    task automatic start_nnue_plan(input ThreadID thread_id);
        nnue_delta_busy <= 1'b1;
        nnue_delta_thread <= thread_id;
        nnue_delta_step <= 3'd0;
        nnue_plan_rr_ptr <= search_thread_after(thread_id);
    endtask : start_nnue_plan

    // Keep NNUE scheduling separate from the engine's shared-pipeline selection.
    always_comb begin
        nnue_plan_any = 1'b0;
        for (int idx = 0; idx < SEARCH_THREAD_COUNT; idx++)
            nnue_plan_any |= nnue_plan_pending[idx];
        // Rotate child-plan priority and exclude the plan currently being
        // emitted so its final request can hand directly to another thread.
        nnue_plan_select_valid = 1'b0;
        nnue_plan_select_thread = ThreadID'(0);
        for (int offset = 0; offset < SEARCH_THREAD_COUNT; offset++) begin
            automatic int candidate = int'(nnue_plan_rr_ptr) + offset;
            if (candidate >= SEARCH_THREAD_COUNT)
                candidate -= SEARCH_THREAD_COUNT;
            if (!nnue_plan_select_valid
                    && nnue_plan_pending[candidate]
                    && !nnue_plan_inflight[candidate]
                    && (!nnue_delta_busy || ThreadID'(candidate) != nnue_delta_thread)) begin
                nnue_plan_select_valid = 1'b1;
                nnue_plan_select_thread = ThreadID'(candidate);
            end
        end
    end

    search_nnue_update_encoder nnue_update_encoder (
        .thread_id(nnue_delta_thread), .plan(nnue_plan[nnue_delta_thread]),
        .step(nnue_delta_step),
        .req_valid(nnue_delta_update_valid), .req(nnue_delta_update_req)
    );

    // A tile replacement subtracts its old feature and adds its new feature as
    // one transaction. Commit the existing board tile only after NNUE completion.
    assign nnue_setup_old_tile = search_board[nnue_root_init_thread].tiles[nnue_root_init_pos];
    assign nnue_setup_new_tile = active_board.tiles[nnue_root_init_pos];
    assign nnue_setup_same = nnue_setup_old_tile.piece_type == nnue_setup_new_tile.piece_type
        && (nnue_setup_old_tile.piece_type == NULL_PIECE
            || nnue_setup_old_tile.piece_color == nnue_setup_new_tile.piece_color);
    always_comb begin
        nnue_eval_valid = nnue_build_busy && nnue_eval_tag_count != 2;
        nnue_update_valid = nnue_delta_busy && nnue_delta_update_valid;
        nnue_update_req = nnue_delta_update_req;
        if (state == CTRL_SEARCH_ROOT_INIT) begin
            nnue_update_req = '0;
            nnue_update_req.thread_id = nnue_root_init_thread;
            nnue_update_req.ply = '0;
            nnue_update_req.apply = 1'b1;
            nnue_update_req.combine = 1'b1;
            nnue_update_req.add = nnue_setup_step == SETUP_ADD;
            nnue_update_req.complete = nnue_setup_step == SETUP_ADD
                || nnue_setup_new_tile.piece_type == NULL_PIECE;
            nnue_update_req.white_feature = nnue_feature_index(nnue_root_init_pos,
                nnue_setup_step == SETUP_ADD ? nnue_setup_new_tile : nnue_setup_old_tile, WHITE);
            nnue_update_req.black_feature = nnue_feature_index(nnue_root_init_pos,
                nnue_setup_step == SETUP_ADD ? nnue_setup_new_tile : nnue_setup_old_tile, BLACK);
            nnue_update_valid = !nnue_setup_same && (
                (nnue_setup_step == SETUP_REMOVE && nnue_setup_old_tile.piece_type != NULL_PIECE)
                || (nnue_setup_step == SETUP_ADD && nnue_setup_new_tile.piece_type != NULL_PIECE));
            if (nnue_setup_step == SETUP_COPY) begin
                nnue_update_valid = 1'b1;
                nnue_update_req.copy = 1'b1;
                nnue_update_req.combine = 1'b0;
                nnue_update_req.complete = 1'b1;
            end
        end
        nnue_update_req.source_slot = state == CTRL_SEARCH_ROOT_INIT
            ? nnue_slot[nnue_root_init_thread]
            : nnue_plan[nnue_update_req.thread_id].reverse
                ? NnueSlot'(nnue_update_req.ply + PlyIndex'(1))
                : NnueSlot'(nnue_update_req.ply - PlyIndex'(1));
        nnue_update_req.destination_slot = NnueSlot'(nnue_update_req.ply);
    end

    // The scan advances only after the board tile and accumulator agree.
    task automatic advance_nnue_setup();
        nnue_setup_step <= SETUP_REMOVE;
        if (nnue_root_init_pos != Position'(63)) begin
            nnue_root_init_pos <= nnue_root_init_pos + Position'(1);
        end else begin
            search_board[nnue_root_init_thread] <= active_board;
            search_board_in_check[nnue_root_init_thread] <= active_board_in_check;
            search_zobrist_key[nnue_root_init_thread] <= active_zobrist_key;
            search_pst_eval[nnue_root_init_thread] <= active_pst_eval;
            search_piece_count[nnue_root_init_thread] <= active_piece_count;
            nnue_cached_reverses[nnue_root_init_thread] <= '0;
            search_ply[nnue_root_init_thread] <= '0;
            nnue_state_valid[nnue_root_init_thread] <= 1'b1;
            if (int'(nnue_root_init_thread) == SEARCH_THREAD_COUNT-1) begin
                nnue_roots_initialized <= 1'b1;
                state <= kill_pending || reset_requested ? CTRL_SEARCH_DRAIN : nnue_setup_return;
                if (nnue_setup_return == CTRL_IDLE || nnue_setup_return == CTRL_DIRECT_DONE)
                    startup_active <= 1'b0;
            end else begin
                nnue_root_init_thread <= nnue_root_init_thread + ThreadID'(1);
                nnue_root_init_pos <= '0;
                nnue_setup_copy_pending <= nnue_slot[nnue_root_init_thread+ThreadID'(1)] != NnueSlot'(0);
                nnue_setup_step <= nnue_slot[nnue_root_init_thread+ThreadID'(1)] != NnueSlot'(0)
                    ? SETUP_COPY : SETUP_REMOVE;
            end
        end
    endtask
