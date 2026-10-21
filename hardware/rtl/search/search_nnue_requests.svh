// NNUE plan arbitration, board replay requests, and physical update formatting.
// Included in search_controller scope; arbitration adds no register boundary.

    // Start a selected or newly prepared plan without adding an issue-cycle bubble.
    task automatic start_nnue_plan(input ThreadID thread_id, input logic rebuild);
        nnue_delta_busy <= 1'b1;
        nnue_delta_draining <= 1'b0;
        nnue_delta_replay <= rebuild;
        nnue_delta_first <= 1'b1;
        nnue_delta_thread <= thread_id;
        nnue_delta_step <= 3'd0;
        nnue_delta_pos <= Position'(0);
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

    // Replay payloads share one tile read. Occupancy remains local so a blocked
    // rebuild can still skip empty squares while another producer owns the port.
    always_comb begin
        for (int tid = 0; tid < SEARCH_THREAD_COUNT; tid++)
            for (int square = 0; square < 64; square++)
                nnue_empty_squares[tid][square]
                    = search_board[tid].tiles[square].piece_type == NULL_PIECE;
    end
    assign nnue_root_square_empty
        = nnue_empty_squares[nnue_root_init_thread][nnue_root_init_pos];
    assign nnue_build_square_empty
        = nnue_empty_squares[nnue_build_thread][nnue_build_pos];
    assign nnue_delta_square_empty
        = nnue_empty_squares[nnue_delta_thread][nnue_delta_pos];
    always_comb begin
        nnue_replay_thread = nnue_root_init_thread;
        nnue_replay_pos = nnue_root_init_pos;
        if (nnue_build_busy && !nnue_build_draining) begin
            nnue_replay_thread = nnue_build_thread;
            nnue_replay_pos = nnue_build_pos;
        end else if (nnue_delta_busy) begin
            nnue_replay_thread = nnue_delta_thread;
            nnue_replay_pos = nnue_delta_pos;
        end
        nnue_replay_tile = search_board[nnue_replay_thread].tiles[nnue_replay_pos];
    end

    search_nnue_update_encoder nnue_update_encoder (
        .thread_id(nnue_delta_thread),
        .plan(nnue_plan[nnue_delta_thread]),
        .step(nnue_delta_step),
        .draining(nnue_delta_draining),
        .first(nnue_delta_first),
        .replay_pos(nnue_delta_pos),
        .replay_tile(nnue_replay_tile),
        .req_valid(nnue_delta_update_valid),
        .req(nnue_delta_update_req)
    );

    // Root/build replay owns updates until draining, when a child plan may proceed.
    always_comb begin
        nnue_update_valid = 1'b0;
        nnue_update_req = NnueUpdateRequest'('0);
        nnue_eval_valid = nnue_build_busy && nnue_build_draining
            && nnue_eval_tag_count != 2
            && (!nnue_build_wait_updates || nnue_update_idle);
        // Payload is unused when invalid; only source ownership selects it.
        // Empty-square detection controls valid without gating ROM addresses.
        if (state == CTRL_SEARCH_ROOT_INIT && !nnue_root_init_draining) begin
            nnue_update_valid = !nnue_root_square_empty;
            nnue_update_req.thread_id = nnue_root_init_thread;
            nnue_update_req.ply = PlyIndex'(0);
            nnue_update_req.white_feature = nnue_feature_index(
                nnue_replay_pos, nnue_replay_tile, WHITE);
            nnue_update_req.black_feature = nnue_feature_index(
                nnue_replay_pos, nnue_replay_tile, BLACK);
            nnue_update_req.apply = 1'b1;
            nnue_update_req.add = 1'b1;
            nnue_update_req.clear = nnue_root_init_first;
        end
        if (nnue_build_busy) begin
            if (!nnue_build_draining) begin
                nnue_update_valid = !nnue_build_square_empty;
                nnue_update_req.thread_id = nnue_build_thread;
                nnue_update_req.ply = search_ply[nnue_build_thread];
                nnue_update_req.white_feature = nnue_feature_index(
                    nnue_replay_pos, nnue_replay_tile, WHITE);
                nnue_update_req.black_feature = nnue_feature_index(
                    nnue_replay_pos, nnue_replay_tile, BLACK);
                nnue_update_req.apply = 1'b1;
                nnue_update_req.add = 1'b1;
                nnue_update_req.clear = nnue_build_first;
            end
        end
        if ((!nnue_build_busy || nnue_build_draining) && nnue_delta_busy) begin
            nnue_update_valid = nnue_delta_update_valid;
            nnue_update_req = nnue_delta_update_req;
        end
    end
