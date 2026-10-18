// Thread readiness, move classification, TT policy, and iteration restart helpers.
// Included in search_controller scope; this file is not a standalone compilation unit.

    function automatic int search_wrap_thread_index(input int index);
        if (index >= SEARCH_THREAD_COUNT) begin
            return index - SEARCH_THREAD_COUNT;
        end
        return index;
    endfunction : search_wrap_thread_index

    function automatic ThreadID search_thread_after(input ThreadID thread);
        if (int'(thread) >= SEARCH_THREAD_COUNT - 1) begin
            return ThreadID'(0);
        end
        return ThreadID'(int'(thread) + 1);
    endfunction : search_thread_after

    // The primary thread has priority whenever it is eligible; helper threads
    // are selected round-robin from the subsystem-specific cursor.
    function automatic ThreadID search_select_thread(
        input SearchThreadMask ready_mask,
        input ThreadID cursor
    );
        if (ready_mask[0]) return ThreadID'(0);
        for (int offset = 0; offset < SEARCH_THREAD_COUNT; offset++) begin
            automatic int idx = search_wrap_thread_index(int'(cursor) + offset);
            if (ready_mask[idx]) return ThreadID'(idx);
        end
        return ThreadID'(0);
    endfunction : search_select_thread

    function automatic logic search_thread_ready(input int thread_index);
        return search_thread_phase[thread_index] == SEARCH_PHASE_READY;
    endfunction : search_thread_ready

    function automatic logic should_probe_search_tt(input ThreadID thread, input PlyIndex ply);
        return !(ply == PlyIndex'(0) && thread != ThreadID'(0));
    endfunction : should_probe_search_tt

    // A checked position at the draw threshold must first prove an evasion
    // exists: checkmate ends the game before a fifty-move draw can be claimed.
    function automatic logic search_thread_terminal_ready(input int thread_index);
        return search_thread_ready(thread_index)
            && ((search_board[thread_index].halfmove_clock >= HalfmoveClock'(100)
                    && (!search_board_in_check[thread_index]
                        || search_stack_top[thread_index].has_legal))
                || search_stack_top[thread_index].move_order_state == MOVE_ORDER_DONE);
    endfunction : search_thread_terminal_ready

    // Keep TT arbitration independent of the later alpha/beta decisions. This
    // avoids placing the null-window adder ahead of the multi-thread TT index.
    function automatic logic search_thread_tt_lookup_ready(input int thread_index);
        return search_thread_ready(thread_index)
            && !search_thread_terminal_ready(thread_index)
            && search_board[thread_index].halfmove_clock < HalfmoveClock'(100)
            && !search_in_qsearch(ThreadID'(thread_index))
            && !search_stack_top[thread_index].tt_checked
            && should_probe_search_tt(
                ThreadID'(thread_index), search_ply[thread_index])
            && !search_tt_lookup_inflight[thread_index];
    endfunction : search_thread_tt_lookup_ready

    function automatic logic search_thread_store_pending(input int thread_index);
        return search_thread_phase[thread_index] == SEARCH_PHASE_STORE_PUBLISH;
    endfunction : search_thread_store_pending

    function automatic logic search_thread_store_complete(input int thread_index);
        return search_thread_phase[thread_index] == SEARCH_PHASE_STORE_PUBLISH
            && search_tt_store_issue_valid && tt_store_req_ready
            && search_tt_store_issue_thread == ThreadID'(thread_index);
    endfunction

    function automatic logic search_has_store_complete_thread();
        for (int idx = 0; idx < SEARCH_THREAD_COUNT; idx++)
            if (search_thread_store_complete(idx)) return 1'b1;
        return 1'b0;
    endfunction

    function automatic ThreadID search_store_complete_thread();
        for (int idx = 0; idx < SEARCH_THREAD_COUNT; idx++)
            if (search_thread_store_complete(idx)) return ThreadID'(idx);
        return ThreadID'(0);
    endfunction

    function automatic logic search_thread_return_pending(input int thread_index);
        return search_thread_phase[thread_index] == SEARCH_PHASE_MOVE_WAIT
            && search_return_valid[thread_index]
            && !search_move_inflight[thread_index];
    endfunction : search_thread_return_pending

    function automatic logic search_thread_tt_response_pending(input int thread_index);
        return search_thread_phase[thread_index] == SEARCH_PHASE_TT_WAIT
            && search_tt_response_pending[thread_index]
            && !search_tt_lookup_inflight[thread_index];
    endfunction : search_thread_tt_response_pending

    function automatic logic search_thread_board_pending(input int thread_index);
        return search_thread_phase[thread_index] == SEARCH_PHASE_BOARD_WAIT
            && !search_board_inflight[thread_index];
    endfunction : search_thread_board_pending

    function automatic logic search_thread_reverse_pending(input int thread_index);
        return search_thread_phase[thread_index] == SEARCH_PHASE_REVERSE_WAIT
            && !search_generation_inflight[thread_index]
            && !search_board_inflight[thread_index];
    endfunction : search_thread_reverse_pending

    // Two/three-ply adaptive reduction uses only a depth comparator and mux.
    function automatic SearchDepth null_child_depth(input ThreadID thread);
        automatic SearchDepth depth = search_stack_top[thread].remaining_depth;
        automatic SearchDepth reduction = depth < SearchDepth'(NULL_DEEP_DEPTH_THRESHOLD)
            ? SearchDepth'(NULL_SHALLOW_REDUCTION) : SearchDepth'(NULL_DEEP_REDUCTION);
        return depth < SearchDepth'(NULL_MINIMUM_DEPTH)
            ? SearchDepth'(0)
            : depth - SearchDepth'(1) - reduction;
    endfunction : null_child_depth

    // Cache the position/depth portion when launching the TT lookup. Alpha can
    // change when the TT response is consumed, so unit-window eligibility stays
    // live while the fixed beta-bound test is cached with the node.
    function automatic logic search_thread_null_candidate(input int thread_index);
        automatic SearchDepth depth = search_stack_top[thread_index].remaining_depth;
        automatic SearchDepth reduction = depth < SearchDepth'(NULL_DEEP_DEPTH_THRESHOLD)
            ? SearchDepth'(NULL_SHALLOW_REDUCTION) : SearchDepth'(NULL_DEEP_REDUCTION);
        automatic logic [7:0] halfmove_depth_sum;
        // halfmove + null_child_depth + 1 < 100 is equivalent to this
        // single-adder form because null_child_depth = depth - 1 - reduction.
        halfmove_depth_sum = {1'b0, search_board[thread_index].halfmove_clock}
            + 8'(depth);
        return search_ply[thread_index] != PlyIndex'(0)
            && search_stack_top[thread_index].remaining_depth >= SearchDepth'(NULL_MINIMUM_DEPTH)
            && !search_board_in_check[thread_index]
            && !search_stack_top[thread_index].entered_by_null
            && halfmove_depth_sum < 8'(100 + int'(reduction));
    endfunction : search_thread_null_candidate

    function automatic logic search_thread_rfp_ready(input int thread_index);
        return search_thread_ready(thread_index)
            // Resolve the retained TT move before any entry-time pruning can
            // return this node or replace its probe context with a null child.
            && !search_tt_validation_pending[thread_index]
            && !search_thread_terminal_ready(thread_index)
            && !search_thread_tt_lookup_ready(thread_index)
            && search_stack_top[thread_index].tt_checked
            && !search_stack_top[thread_index].rfp_checked
            && search_stack_top[thread_index].rfp_eligible;
    endfunction : search_thread_rfp_ready

    function automatic logic search_thread_null_ready(input int thread_index);
        return search_thread_ready(thread_index)
            && !search_tt_validation_pending[thread_index]
            && !search_generation_inflight[thread_index]
            && !search_thread_terminal_ready(thread_index)
            && !search_thread_tt_lookup_ready(thread_index)
            && !search_thread_rfp_ready(thread_index)
            && search_stack_top[thread_index].tt_checked
            && !search_stack_top[thread_index].null_attempted
            && search_null_candidate[thread_index]
            && search_stack_top[thread_index].unit_window
            && search_stack_top[thread_index].null_beta_allowed;
    endfunction : search_thread_null_ready

    function automatic logic search_thread_eval_ready(input int thread_index);
        return search_thread_ready(thread_index)
            && !search_tt_validation_pending[thread_index]
            && !search_thread_terminal_ready(thread_index)
            && search_board[thread_index].halfmove_clock < HalfmoveClock'(100)
            && !search_thread_tt_lookup_ready(thread_index)
            && (search_thread_rfp_ready(thread_index)
                || (!search_thread_null_ready(thread_index)
                    && (search_futility_eval_pending[thread_index]
                        || (search_in_qsearch(ThreadID'(thread_index))
                            && !search_stack_top[thread_index].stand_pat_done)
                        || int'(search_ply[thread_index]) >= SEARCH_STACK_DEPTH - 1)));
    endfunction : search_thread_eval_ready

    // Select requests from thread state alone; destination readiness depends on
    // the selected tags and is checked only when accepting the request.
    function automatic logic search_thread_move_ready(input int thread_index);
        automatic MoveOrderState order_state =
            search_stack_top[thread_index].move_order_state;
        return search_thread_ready(thread_index)
            // Child TT/evaluation work can overlap parent generation, but
            // moving deeper or allocating moves needs final parent bounds.
            && (!search_generation_inflight[thread_index]
                || search_ply[thread_index] == search_generation_ply[thread_index])
            && !search_thread_terminal_ready(thread_index)
            && !search_thread_tt_lookup_ready(thread_index)
            && !search_thread_null_ready(thread_index)
            && !search_thread_eval_ready(thread_index)
            && order_state != MOVE_ORDER_GENERATE_QUIET
            && !search_move_inflight[thread_index];
    endfunction : search_thread_move_ready

    function automatic logic search_thread_quiet_ready(input int thread_index);
        return search_thread_ready(thread_index)
            && !search_thread_terminal_ready(thread_index)
            && !search_thread_tt_lookup_ready(thread_index)
            && !search_thread_null_ready(thread_index)
            && !search_thread_eval_ready(thread_index)
            && search_stack_top[thread_index].move_order_state
                == MOVE_ORDER_GENERATE_QUIET
            && !search_generation_inflight[thread_index]
            && !search_move_inflight[thread_index];
    endfunction : search_thread_quiet_ready

    function automatic logic should_store_search_tt(input ThreadID thread, input PlyIndex ply);
        return !search_in_qsearch(thread);
    endfunction : should_store_search_tt

    function automatic Move root_hint_for_thread(input ThreadID thread);
        // The primary thread follows the previous iteration's PV. Helpers use
        // normal legal move order, creating position-dependent diversification
        // without assuming opening-position moves are legal.
        return thread == ThreadID'(0) ? search_completed_best_move : NULL_MOVE;
    endfunction : root_hint_for_thread

    function automatic Move ordering_move_for_thread(input ThreadID thread);
        // Keep the primary root transactional: the preceding iteration's PV
        // must be searched before a shared-TT hint can introduce a challenger.
        if (thread == ThreadID'(0) && search_ply[thread] == PlyIndex'(0)
                && !search_in_qsearch(thread) && !is_null_move(search_completed_best_move))
            return search_completed_best_move;
        if (search_stack_top[thread].has_tt_move)
            return search_stack_top[thread].tt_move;
        if (search_ply[thread] == PlyIndex'(0) && !search_in_qsearch(thread))
            return root_hint_for_thread(thread);
        return NULL_MOVE;
    endfunction : ordering_move_for_thread

    // Reinitialize one independent search context between completed passes.
    task automatic restart_search_thread(
        input int unsigned thread_index,
        input logic retry_same_depth,
        input AspirationDelta next_delta
    );
        search_thread_phase[thread_index] <= SEARCH_PHASE_READY;
        search_board[thread_index] <= active_board;
        search_board_in_check[thread_index] <= active_board_in_check;
        search_zobrist_key[thread_index] <= active_zobrist_key;
        search_pst_eval[thread_index] <= active_pst_eval;
        search_piece_count[thread_index] <= active_piece_count;
        search_ply[thread_index] <= PlyIndex'(0);
        search_repetition_seen_before[thread_index] <= 1'b0;
        search_best_move[thread_index] <= NULL_MOVE;
        search_ponder_move[thread_index] <= NULL_MOVE;
        search_root_best_score[thread_index] <= -SEARCH_INF;
        search_root_has_completed_move[thread_index] <= 1'b0;
        search_root_best_exact[thread_index] <= 1'b0;
        search_pending_move[thread_index] <= NULL_MOVE;
        search_pending_move_bucket[thread_index] <= QUIET_MEDIUM_BUCKET;
        search_return_score[thread_index] <= EvalScore'(0);
        search_return_valid[thread_index] <= 1'b0;
        search_return_was_scout[thread_index] <= 1'b0;
        search_return_was_reduced[thread_index] <= 1'b0;
        search_return_was_null[thread_index] <= 1'b0;
        search_pvs_research[thread_index] <= 1'b0;
        search_eval_is_stand_pat[thread_index] <= 1'b0;
        search_eval_is_rfp[thread_index] <= 1'b0;
        search_eval_is_futility[thread_index] <= 1'b0;
        search_futility_eval_pending[thread_index] <= 1'b0;
        search_return_ponder_move[thread_index] <= NULL_MOVE;
        if (thread_index == 0) begin
            total_root_nodes <= NodeCountType'(0);
            current_best_move_root_nodes <= NodeCountType'(0);
            current_root_move_start_nodes <= NodeCountType'(0);
        end
        search_stack_top[thread_index] <= empty_search_stack_entry();
        search_tt_validation_pending[thread_index] <= 1'b0;
        search_tt_validation_passed[thread_index] <= 1'b0;
        search_tt_validation_forced[thread_index] <= 1'b0;
        search_stack_top[thread_index].remaining_depth
            <= retry_same_depth
                ? search_thread_target_depth[thread_index]
                : search_thread_target_depth[thread_index] + SearchDepth'(1);
        search_stack_top[thread_index].alpha
            <= aspiration_lower_bound(search_thread_iteration_score[thread_index], next_delta);
        search_stack_top[thread_index].beta
            <= aspiration_upper_bound(search_thread_iteration_score[thread_index], next_delta);
        search_stack_top[thread_index].stand_pat_done <= active_board_in_check;
        search_stack_top[thread_index].node_in_check <= active_board_in_check;
        search_stack_top[thread_index].unit_window
            <= aspiration_upper_bound(search_thread_iteration_score[thread_index], next_delta)
                == aspiration_lower_bound(search_thread_iteration_score[thread_index], next_delta)
                    + EvalScore'(1);
        search_stack_top[thread_index].zero_window_node
            <= aspiration_upper_bound(search_thread_iteration_score[thread_index], next_delta)
                == aspiration_lower_bound(search_thread_iteration_score[thread_index], next_delta)
                    + EvalScore'(1);
        search_return_move[thread_index] <= NULL_MOVE;
    endtask : restart_search_thread

    function automatic logic move_state_uses_pop(input MoveOrderState move_state);
        return move_state == MOVE_ORDER_GOOD_NOISY
            || move_state == MOVE_ORDER_QUIET
            || move_state == MOVE_ORDER_BAD_NOISY
            || move_state == MOVE_ORDER_LOW_QUIET;
    endfunction : move_state_uses_pop

    function automatic logic is_promotion_move(input FullBoard board, input Move move);
        automatic Tile source_tile = board.tiles[move.from_pos];
        return source_tile.piece_type == PAWN
            && (move.to_pos[5:3] == BoardRank'(0) || move.to_pos[5:3] == BoardRank'(7));
    endfunction : is_promotion_move

    // History applies only to ordinary non-captures and castling. Promotions
    // and the empty-destination pawn diagonal used by en passant are noisy.
    function automatic logic is_quiet_move(input FullBoard board, input Move move);
        automatic Tile source_tile;
        automatic Tile destination_tile;
        automatic logic pawn_promotion;
        automatic logic pawn_diagonal;

        source_tile = board.tiles[move.from_pos];
        destination_tile = board.tiles[move.to_pos];
        pawn_promotion = is_promotion_move(board, move);
        pawn_diagonal = source_tile.piece_type == PAWN
            && move.from_pos[2:0] != move.to_pos[2:0];
        return destination_tile.piece_type == NULL_PIECE && !pawn_promotion && !pawn_diagonal;
    endfunction : is_quiet_move

    function automatic TTDepth search_remaining_depth(input ThreadID thread);
        return TTDepth'(search_stack_top[thread].remaining_depth);
    endfunction : search_remaining_depth

    // Root and previously seen nodes use TT hits for ordering only; their
    // scores depend on the current search or repetition history.
    function automatic logic tt_score_cutoff_eligible(input ThreadID thread);
        // The key omits the halfmove clock: a horizon reaching the draw boundary
        // cannot reuse a score computed with a different reversible history.
        return search_ply[thread] != PlyIndex'(0)
            && !search_repetition_seen_before[thread]
            && (int'(search_board[thread].halfmove_clock) + int'(search_remaining_depth(thread)) < 100);
    endfunction : tt_score_cutoff_eligible

    // Repetition history can affect a TT score only after enough reversible
    // moves have accumulated; forced validation extends the depth check only.
    function automatic logic tt_history_validation_required(input ThreadID thread);
        return search_board[thread].halfmove_clock
                > HalfmoveClock'(TT_VALIDATE_BYPASS_HALFMOVES)
            && (search_tt_validation_forced[thread]
                || search_remaining_depth(thread) >= TTDepth'(TT_VALIDATE_MINIMUM_DEPTH));
    endfunction : tt_history_validation_required

    // Recover the entry bound without per-ply storage or another RAM read.
    // Scout and null windows have fixed beta == entry alpha + 1; full-window
    // children retain their entry alpha in the frozen parent's beta.
    function automatic EvalScore search_original_alpha(input ThreadID thread);
        if (search_ply[thread] == PlyIndex'(0))
            return search_thread_root_alpha[thread];
        if (search_stack_top[thread].scout_search)
            return search_stack_top[thread].beta - EvalScore'(1);
        return -search_stack_parent_q[thread].beta;
    endfunction : search_original_alpha

    function automatic TTBoundType tt_bound_for_score(
        input EvalScore score,
        input EvalScore original_alpha,
        input EvalScore beta
    );
        if (score <= original_alpha) begin
            return TT_BOUND_UPPER;
        end
        if (score >= beta) begin
            return TT_BOUND_LOWER;
        end
        return TT_BOUND_EXACT;
    endfunction : tt_bound_for_score

    function automatic logic [7:0] requested_search_depth(input EngineControllerRequest request);
        if (request.operation == ENGINE_CTRL_SEARCH_DEPTH) begin
            return request.depth_limit;
        end
        return 8'(SEARCH_STACK_DEPTH - 1);
    endfunction : requested_search_depth
