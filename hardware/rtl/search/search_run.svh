// Active-search node lifecycle, pipeline completions, and iterative-deepening results.
// Included inside the controller state case; all updates retain its single clocked process.

                CTRL_SEARCH_RUN: begin
                    automatic ThreadCount active_count_next;
                    automatic NodeCountType nodes_next;
                    automatic logic nnue_eval_enqueued;
                    automatic logic nnue_eval_dequeued;

                    active_count_next = search_active_thread_count;
                    nodes_next = search_nodes;
                    nnue_eval_enqueued = nnue_eval_valid && nnue_eval_ready;
                    nnue_eval_dequeued = nnue_result_valid;

                    for (int tid = 0; tid < SEARCH_THREAD_COUNT; tid++) begin
                        if (search_node_init_request[tid])
                            search_node_init_pending[tid] <= 1'b1;
                        if (move_node_init_valid[tid] && move_node_init_ready[tid]) begin
                            search_node_init_pending[tid] <= 1'b0;
                            search_node_init_done[tid] <= 1'b1;
                        end
                    end
                    if (move_cmd_valid && move_cmd_ready
                            && move_cmd == MOVE_GEN_GENERATE_NOISY)
                        search_node_init_done[move_cmd_thread] <= 1'b1;

`ifndef SYNTHESIS
                    for (int tid = 0; tid < SEARCH_THREAD_COUNT; tid++) begin
                        assert (search_stack_top[tid].unit_window
                                == (search_stack_top[tid].beta
                                    == search_stack_top[tid].alpha + EvalScore'(1)))
                            else $fatal(1, "cached unit-window state disagrees for thread %0d", tid);
                        if (search_thread_ready(tid) && search_in_qsearch(ThreadID'(tid))
                                && search_board_in_check[tid]) begin
                            assert (search_stack_top[tid].stand_pat_done)
                                else $fatal(1, "checked qsearch thread did not bypass stand pat: %0d", tid);
                        end
                    end
`endif

                    `include "hardware/rtl/search/search_nnue_control.svh"

                    // The two generators may complete together, but one thread owns only one move operation.
                    if (move_cmd_resp_valid && move_quiet_resp_valid)
                        assert (move_cmd_resp_thread != move_quiet_resp_thread)
                            else $fatal(1, "simultaneous move responses targeted one thread");

                    `include "hardware/rtl/search/search_iterations.svh"

                    if (search_stop_requested()) begin
                        resp_reg <= stopped_search_response(
                            1'b1,
                            active_req.operation != ENGINE_CTRL_SEARCH_FIXED_TIME
                                && active_req.operation != ENGINE_CTRL_SEARCH_ON_CLOCK,
                            search_node_stop_q ? ENGINE_END_NODE_LIMIT : ENGINE_END_TIME_LIMIT);
                        state <= CTRL_FLUSH_RESPOND;
                    end else begin
                        if (terminal_result_valid_pipe) begin
                            automatic ThreadID terminal_thread_id;
                            automatic PlyIndex terminal_ply;
                            automatic EvalScore node_score;

                            terminal_thread_id = terminal_result_thread_pipe;
                            terminal_ply = terminal_result_ply_pipe;
                            node_score = terminal_result_score_pipe;
                            search_return_score[terminal_thread_id] <= node_score;
                            search_return_valid[terminal_thread_id] <= 1'b1;
                            if (should_store_search_tt(terminal_thread_id, terminal_ply)) begin
                                search_thread_phase[terminal_thread_id] <= SEARCH_PHASE_STORE_PUBLISH;
                            end else if (terminal_ply == PlyIndex'(0)) begin
                                search_thread_phase[terminal_thread_id] <= SEARCH_PHASE_DONE;
                                search_thread_iteration_score[terminal_thread_id] <= node_score;
                                search_thread_iteration_best_move[terminal_thread_id]
                                    <= search_best_move[terminal_thread_id];
                                search_thread_iteration_ponder_move[terminal_thread_id]
                                    <= search_ponder_move[terminal_thread_id];
`ifndef SYNTHESIS
                                search_thread_completed_best_move[terminal_thread_id] <= search_best_move[terminal_thread_id];
`endif
                                if (active_count_next != ThreadCount'(0)) active_count_next -= ThreadCount'(1);
                            end else begin
                                search_thread_phase[terminal_thread_id] <= SEARCH_PHASE_REVERSE_WAIT;
                            end
                        end

                        if (search_board_tag_valid_pipe[SEARCH_BOARD_TAG_PIPE_LEN - 1]) begin
                            automatic ThreadID board_thread_id;
                            automatic PlyIndex board_ply;
                            automatic PlyIndex child_ply;
                            automatic logic reverse_complete;
                            automatic logic null_push_complete;
                            automatic logic futility_eligible;

                            board_thread_id = search_board_tag_pipe[SEARCH_BOARD_TAG_PIPE_LEN - 1];
                            reverse_complete = search_board_op_tag_pipe[SEARCH_BOARD_TAG_PIPE_LEN - 1] == BOARD_REVERSE_MOVE_OP;
                            null_push_complete = search_board_op_tag_pipe[SEARCH_BOARD_TAG_PIPE_LEN - 1] == BOARD_PUSH_NULL_OP;
                            board_ply = search_board_ply_tag_pipe[SEARCH_BOARD_TAG_PIPE_LEN - 1];
                            child_ply = board_ply + PlyIndex'(1);
                            futility_eligible = parent_futility_eligible_q
                                && !board_update_side_in_check;
`ifndef SYNTHESIS
                            // Catch stale or misrouted parent classifications
                            // across interleaved threads, retries, and flushes.
                            if (!reverse_complete && !null_push_complete) begin
                                assert (futility_eligible === futility_move_eligible(
                                    search_ply[board_thread_id], search_pending_child_depth[board_thread_id],
                                    search_board_in_check[board_thread_id], board_update_side_in_check,
                                    is_quiet_move(search_board[board_thread_id], search_pending_move[board_thread_id]),
                                    is_promotion_move(search_board[board_thread_id], search_pending_move[board_thread_id]),
                                    search_stack_top[board_thread_id].has_tt_move
                                        && search_pending_move[board_thread_id] == search_stack_top[board_thread_id].tt_move,
                                    search_stack_top[board_thread_id].has_legal, search_pvs_research[board_thread_id]))
                                    else $fatal(1, "futility classification lost board-result alignment");
                                assert (parent_futility_prunes_q === futility_prunes(
                                    search_stack_top[board_thread_id].static_eval,
                                    search_stack_top[board_thread_id].alpha, search_pending_child_depth[board_thread_id]))
                                    else $fatal(1, "futility score lost board-result alignment");
                                assert ((parent_qdelta_prunes_q && !board_update_side_in_check)
                                    === (search_in_qsearch(board_thread_id) && qdelta_move_prunes(
                                        search_board[board_thread_id], search_stack_top[board_thread_id].move,
                                        search_pending_move[board_thread_id], search_stack_top[board_thread_id].static_eval,
                                        search_stack_top[board_thread_id].alpha, search_board_in_check[board_thread_id],
                                        board_update_side_in_check)))
                                    else $fatal(1, "qdelta classification lost board-result alignment");
                            end
`endif
`ifndef SYNTHESIS
                            search_board_result_thread_id <= board_thread_id;
                            search_board_result_valid <= 1'b1;
`endif
                            search_board_inflight[board_thread_id] <= 1'b0;
                            if (reverse_complete) begin
                                search_board[board_thread_id] <= board_update_out;
                                search_board_in_check[board_thread_id]
                                    <= search_stack_parent_q[board_thread_id].node_in_check;
                                search_zobrist_key[board_thread_id] <= board_update_zobrist_out;
                                search_pst_eval[board_thread_id] <= board_update_pst_out;
                                search_piece_count[board_thread_id] <= board_update_piece_count_out;
                                search_return_move[board_thread_id] <= search_stack_top[board_thread_id].move;
                                // Preserve the child's best reply while its stack
                                // record is still live so the root can publish PV2.
                                search_return_ponder_move[board_thread_id]
                                    <= !is_null_move(search_stack_top[board_thread_id].best_move)
                                        ? search_stack_top[board_thread_id].best_move
                                        : search_stack_top[board_thread_id].tt_move;
                                search_return_was_scout[board_thread_id] <= search_stack_top[board_thread_id].scout_search;
                                search_return_was_reduced[board_thread_id]
                                    <= search_stack_top[board_thread_id].remaining_depth + SearchDepth'(1)
                                        < search_stack_parent_q[board_thread_id].remaining_depth;
                                search_return_was_null[board_thread_id]
                                    <= search_stack_top[board_thread_id].entered_by_null;
                                search_stack_top[board_thread_id] <= search_stack_parent_q[board_thread_id];
                                // A saved parent left DIRECT only after move-memory
                                // initialization; a null descent records the other case.
                                search_node_init_done[board_thread_id]
                                    <= search_stack_parent_q[board_thread_id].move_order_state
                                            != MOVE_ORDER_DIRECT
                                        || search_stack_parent_q[board_thread_id].null_attempted;
                                if (!search_stack_top[board_thread_id].entered_by_null
                                        && search_stack_top[board_thread_id].count_move_on_return
                                        && search_stack_parent_q[board_thread_id].legal_move_count != 8'hff) begin
                                    search_stack_top[board_thread_id].legal_move_count
                                        <= search_stack_parent_q[board_thread_id].legal_move_count + 8'd1;
                                end
                                search_ply[board_thread_id] <= board_ply - PlyIndex'(1);
                                if (!search_stack_top[board_thread_id].entered_by_null) begin
                                    nnue_plan_pending[board_thread_id] <= 1'b1;
                                    nnue_plan_inflight[board_thread_id] <= 1'b0;
                                    nnue_plan[board_thread_id] <= nnue_undo_plan(
                                        search_stack_top[board_thread_id].move,
                                        search_stack_top[board_thread_id].nnue_undo,
                                        board_update_out.turn,
                                        board_ply - PlyIndex'(1));
                                    nnue_state_valid[board_thread_id] <= 1'b0;
                                    // Start a newly created plan immediately when
                                    // arbitration has no older work, saving one
                                    // child-update-pending controller cycle.
                                    if (!nnue_delta_busy && !nnue_build_busy
                                            && !nnue_plan_select_valid) begin
                                        start_nnue_plan(board_thread_id, 1'b0);
                                    end
                                    search_thread_phase[board_thread_id]
                                        <= SEARCH_PHASE_REPETITION_WAIT;
                                end else begin
                                    search_thread_phase[board_thread_id]
                                        <= SEARCH_PHASE_MOVE_WAIT;
                                end
                            end else if (null_push_complete) begin
                                // Enter a synthetic child without legal-node or
                                // repetition accounting.
                                search_board[board_thread_id] <= board_update_out;
                                search_board_in_check[board_thread_id] <= board_update_side_in_check;
                                search_zobrist_key[board_thread_id] <= board_update_zobrist_out;
                                search_repetition_seen_before[board_thread_id] <= 1'b0;
                                search_pst_eval[board_thread_id] <= board_update_pst_out;
                                search_piece_count[board_thread_id] <= board_update_piece_count_out;
                                search_stack_top[board_thread_id].move <= NULL_MOVE;
                                search_stack_top[board_thread_id].best_move <= NULL_MOVE;
                                search_stack_top[board_thread_id].best_score <= -SEARCH_INF;
                                search_stack_top[board_thread_id].alpha
                                    <= -search_stack_top[board_thread_id].beta;
                                search_stack_top[board_thread_id].beta
                                    <= -search_stack_top[board_thread_id].beta + EvalScore'(1);
                                search_stack_top[board_thread_id].remaining_depth
                                    <= search_pending_child_depth[board_thread_id];
                                // The child inherits arena tails but begins at
                                // the start of its own FIFO ranges.
                                search_stack_top[board_thread_id].legal_move_count <= 8'd0;
                                search_stack_top[board_thread_id].count_move_on_return <= 1'b0;
                                search_stack_top[board_thread_id].tt_move <= NULL_MOVE;
                                // The synthetic ply has no line-history write; exclude
                                // its stale RAM slot as well as all pre-null history.
                                search_stack_top[board_thread_id].repetition_start <= child_ply + PlyIndex'(1);
                                search_stack_top[board_thread_id].has_legal <= 1'b0;
                                search_stack_top[board_thread_id].move_order_state <= MOVE_ORDER_DIRECT;
                                search_node_init_pending[board_thread_id] <= 1'b0;
                                search_node_init_done[board_thread_id] <= 1'b0;
                                search_stack_top[board_thread_id].direct_attempted <= 1'b0;
                                search_stack_top[board_thread_id].tt_checked <= 1'b0;
                                search_stack_top[board_thread_id].has_tt_move <= 1'b0;
                                search_stack_top[board_thread_id].stand_pat_done
                                    <= board_update_side_in_check;
                                search_stack_top[board_thread_id].static_eval_valid <= 1'b0;
                                search_stack_top[board_thread_id].node_in_check
                                    <= board_update_side_in_check;
                                search_stack_top[board_thread_id].scout_search <= 1'b1;
                                search_stack_top[board_thread_id].zero_window_node <= 1'b1;
                                search_stack_top[board_thread_id].unit_window <= 1'b1;
                                search_stack_top[board_thread_id].null_attempted <= 1'b0;
                                search_stack_top[board_thread_id].entered_by_null <= 1'b1;
                                search_stack_top[board_thread_id].rfp_checked <= 1'b0;
                                search_stack_top[board_thread_id].failed_quiet_count <= 2'd0;
                                search_eval_is_stand_pat[board_thread_id] <= 1'b0;
                                search_eval_is_rfp[board_thread_id] <= 1'b0;
                                search_eval_is_futility[board_thread_id] <= 1'b0;
                                search_futility_eval_pending[board_thread_id] <= 1'b0;
                                search_return_valid[board_thread_id] <= 1'b0;
                                search_ply[board_thread_id] <= child_ply;
                                // Null moves preserve the thread's live
                                // accumulator and require no update-plan join.
                                search_thread_phase[board_thread_id] <= SEARCH_PHASE_READY;
                            end else if (search_tt_validation_pending[board_thread_id]) begin
                                if (board_update_mover_in_check) begin
                                    // A pseudo-legal TT move that leaves its king
                                    // checked cannot authorize the stored score.
                                    search_tt_validation_pending[board_thread_id] <= 1'b0;
                                    search_thread_phase[board_thread_id] <= SEARCH_PHASE_READY;
                                end else if (board_update_out.halfmove_clock >= HalfmoveClock'(100)) begin
                                    // Re-run an immediate 50-move draw as an
                                    // ordinary child so it remains selectable.
                                    search_tt_validation_pending[board_thread_id] <= 1'b0;
                                    search_stack_top[board_thread_id].move_order_state
                                        <= MOVE_ORDER_DIRECT;
                                    search_stack_top[board_thread_id].direct_attempted <= 1'b0;
                                    search_thread_phase[board_thread_id] <= SEARCH_PHASE_READY;
                                end else begin
                                    automatic PlyIndex validation_repetition_start =
                                        committed_move_is_irreversible(
                                            search_board[board_thread_id],
                                            board_update_out,
                                            search_pending_move[board_thread_id])
                                            ? child_ply
                                            : search_stack_top[board_thread_id].repetition_start;
                                    // The speculative child is discarded rather
                                    // than entered, so it needs no NNUE update or
                                    // board reversal after its repetition query.
                                    repetition_req_valid <= 1'b1;
                                    repetition_req_thread <= board_thread_id;
                                    repetition_req_ply <= child_ply;
                                    repetition_req_start_ply <= validation_repetition_start;
                                    repetition_req_key <= board_update_zobrist_out;
                                    search_repetition_pending[board_thread_id] <= 1'b1;
                                    search_repetition_done[board_thread_id] <= 1'b0;
                                    search_repetition_draw[board_thread_id] <= 1'b0;
                                    search_thread_phase[board_thread_id]
                                        <= SEARCH_PHASE_REPETITION_WAIT;
                                end
                            end else if (board_update_mover_in_check) begin
                                // The board pipeline is stateless. Ignore the
                                // speculative result; its history entry will be
                                // overwritten by the next candidate at this ply.
                                search_thread_phase[board_thread_id] <= SEARCH_PHASE_READY;
                            end else if (search_board[board_thread_id].halfmove_clock
                                    >= HalfmoveClock'(100)) begin
                                // This legal evasion rules out checkmate in the
                                // unchanged parent. Claim its draw without entering
                                // a child, even if the evasion would reset the clock.
                                search_stack_top[board_thread_id].has_legal <= 1'b1;
                                search_thread_phase[board_thread_id] <= SEARCH_PHASE_READY;
                            end else if (parent_qdelta_prunes_q
                                    && !board_update_side_in_check) begin
`ifdef FPGA_CHESS_PROFILE
                                profile_qdelta_prune_event <= 1'b1;
`endif
                                // The speculative pipeline is stateless, so a
                                // pruned legal move needs no board reversal.
                                search_thread_phase[board_thread_id] <= SEARCH_PHASE_READY;
                            end else if (futility_eligible
                                    && !search_stack_top[board_thread_id].static_eval_valid) begin
                                // Retain this already-proved legal candidate and
                                // evaluate the unchanged parent before retrying it.
                                search_futility_eval_pending[board_thread_id] <= 1'b1;
                                search_thread_phase[board_thread_id] <= SEARCH_PHASE_READY;
                            end else if (futility_eligible && parent_futility_prunes_q) begin
`ifdef FPGA_CHESS_PROFILE
                                profile_futility_prune_event <= 1'b1;
`endif
                                // Count a pruned legal move for subsequent LMR
                                // ordinals without allowing it to establish the
                                // node's first searched legal line.
                                if (search_stack_top[board_thread_id].legal_move_count != 8'hff)
                                    search_stack_top[board_thread_id].legal_move_count
                                        <= search_stack_top[board_thread_id].legal_move_count + 8'd1;
                                search_thread_phase[board_thread_id] <= SEARCH_PHASE_READY;
                            end else begin
                                automatic Tile delta_mover =
                                    search_board[board_thread_id].tiles[
                                        search_pending_move[board_thread_id].from_pos];
                                automatic Tile delta_capture =
                                    search_board[board_thread_id].tiles[
                                        search_pending_move[board_thread_id].to_pos];
                                automatic Position delta_capture_pos =
                                    search_pending_move[board_thread_id].to_pos;
                                automatic logic delta_capture_valid =
                                    delta_capture.piece_type != NULL_PIECE;
                                automatic logic delta_is_ep =
                                    delta_mover.piece_type == PAWN
                                    && search_pending_move[board_thread_id].from_pos[2:0]
                                        != search_pending_move[board_thread_id].to_pos[2:0]
                                    && !delta_capture_valid;
                                automatic logic parent_state_invalid =
                                    !nnue_state_valid[board_thread_id];
                                automatic PlyIndex child_repetition_start =
                                    committed_move_is_irreversible(
                                        search_board[board_thread_id],
                                        board_update_out,
                                        search_pending_move[board_thread_id])
                                        ? child_ply
                                        : search_stack_top[board_thread_id].repetition_start;
                                if (delta_is_ep) begin
                                    delta_capture_pos = {
                                        search_pending_move[board_thread_id].from_pos[5:3],
                                        search_pending_move[board_thread_id].to_pos[2:0]
                                    };
                                    delta_capture = search_board[board_thread_id].tiles[
                                        delta_capture_pos];
                                    delta_capture_valid = 1'b1;
                                end
                                // A node is entered only after a speculative push
                                // proves legal. Count that committed child here so
                                // TT cutoffs, draws, and terminal children count too.
                                nodes_next += NodeCountType'(1);
                                search_thread_nodes[board_thread_id] <= search_thread_nodes[board_thread_id] + NodeCountType'(1);
                                if (board_thread_id == ThreadID'(0)) begin
                                    total_root_nodes <= total_root_nodes + NodeCountType'(1);
                                end
                                if (board_thread_id == ThreadID'(0)
                                        && board_ply == PlyIndex'(0)
                                        && !search_pvs_research[board_thread_id]) begin
                                    current_root_move_start_nodes <= total_root_nodes;
                                end
                                search_board[board_thread_id] <= board_update_out;
                                search_board_in_check[board_thread_id] <= board_update_side_in_check;
                                search_zobrist_key[board_thread_id] <= board_update_zobrist_out;
                                search_repetition_seen_before[board_thread_id] <= 1'b0;
                                search_pst_eval[board_thread_id] <= board_update_pst_out;
                                search_piece_count[board_thread_id] <= board_update_piece_count_out;
                                repetition_line_write_valid <= 1'b1;
                                repetition_line_write_thread <= board_thread_id;
                                repetition_line_write_ply <= child_ply;
                                repetition_line_write_key <= board_update_zobrist_out;
                                // Repetition lookup and NNUE construction are
                                // independent; launch both from the legal board
                                // result and join their tagged completions.
                                repetition_req_valid <= 1'b1;
                                repetition_req_thread <= board_thread_id;
                                repetition_req_ply <= child_ply;
                                repetition_req_start_ply <= child_repetition_start;
                                repetition_req_key <= board_update_zobrist_out;
                                search_repetition_pending[board_thread_id] <= 1'b1;
                                search_repetition_done[board_thread_id] <= 1'b0;
                                search_repetition_draw[board_thread_id] <= 1'b0;
                                nnue_plan_pending[board_thread_id] <= 1'b1;
                                nnue_plan_inflight[board_thread_id] <= 1'b0;
                                nnue_state_valid[board_thread_id] <= 1'b0;
                                nnue_plan[board_thread_id].kind
                                    <= parent_state_invalid
                                        ? NNUE_PLAN_REBUILD : NNUE_PLAN_DELTA;
                                nnue_plan[board_thread_id].child_ply <= child_ply;
                                nnue_plan[board_thread_id].from_pos
                                    <= search_pending_move[board_thread_id].from_pos;
                                nnue_plan[board_thread_id].to_pos
                                    <= search_pending_move[board_thread_id].to_pos;
                                nnue_plan[board_thread_id].capture_pos <= delta_capture_pos;
                                nnue_plan[board_thread_id].mover <= delta_mover;
                                nnue_plan[board_thread_id].placed
                                    <= board_update_out.tiles[
                                        search_pending_move[board_thread_id].to_pos];
                                nnue_plan[board_thread_id].capture <= delta_capture;
                                nnue_plan[board_thread_id].capture_valid
                                    <= delta_capture_valid;
                                nnue_plan[board_thread_id].real_move <= 1'b1;
                                nnue_plan[board_thread_id].reverse <= 1'b0;
                                // Bypass the next-cycle plan-selection stage when
                                // the update planner is otherwise completely idle.
                                if (!nnue_delta_busy && !nnue_build_busy
                                        && !nnue_plan_select_valid) begin
                                    start_nnue_plan(board_thread_id, parent_state_invalid);
                                end
                                search_stack_top[board_thread_id].nnue_undo.mover
                                    <= delta_mover.piece_type;
                                search_stack_top[board_thread_id].nnue_undo.capture_kind
                                    <= delta_is_ep ? NNUE_CAPTURE_EP
                                        : delta_capture.piece_type;
                                search_stack_top[board_thread_id].move <= search_pending_move[board_thread_id];
                                search_stack_top[board_thread_id].best_move <= NULL_MOVE;
                                search_stack_top[board_thread_id].best_score <= -SEARCH_INF;
                                // Search the first child (and any required re-search) with the full
                                // window. Later main-search children use a one-point PVS scout window.
                                if (!search_pvs_research[board_thread_id]
                                        && search_stack_top[board_thread_id].has_legal
                                        && !search_in_qsearch(board_thread_id)) begin
                                    search_stack_top[board_thread_id].alpha <= -(search_stack_top[board_thread_id].alpha + EvalScore'(1));
                                    search_stack_top[board_thread_id].beta <= -search_stack_top[board_thread_id].alpha;
                                    search_stack_top[board_thread_id].scout_search <= 1'b1;
                                    search_stack_top[board_thread_id].zero_window_node <= 1'b1;
                                    search_stack_top[board_thread_id].unit_window <= 1'b1;
                                end else begin
                                    search_stack_top[board_thread_id].alpha <= -search_stack_top[board_thread_id].beta;
                                    search_stack_top[board_thread_id].beta <= -search_stack_top[board_thread_id].alpha;
                                    search_stack_top[board_thread_id].scout_search <= 1'b0;
                                    search_stack_top[board_thread_id].zero_window_node
                                        <= search_stack_top[board_thread_id].unit_window;
                                    search_stack_top[board_thread_id].unit_window
                                        <= search_stack_top[board_thread_id].unit_window;
                                end
                                search_pvs_research[board_thread_id] <= 1'b0;
                                search_stack_top[board_thread_id].remaining_depth <= search_pending_child_depth[board_thread_id];
                                // The child inherits arena tails but begins at
                                // the start of its own FIFO ranges.
                                search_stack_top[board_thread_id].legal_move_count <= 8'd0;
                                search_stack_top[board_thread_id].count_move_on_return <= !search_pvs_research[board_thread_id];
                                search_stack_top[board_thread_id].tt_move <= NULL_MOVE;
                                search_stack_top[board_thread_id].repetition_start <= committed_move_is_irreversible(
                                    search_board[board_thread_id],
                                    board_update_out,
                                    search_pending_move[board_thread_id]
                                ) ? child_ply : search_stack_top[board_thread_id].repetition_start;
                                search_stack_top[board_thread_id].has_legal <= 1'b0;
                                search_stack_top[board_thread_id].move_order_state <= MOVE_ORDER_DIRECT;
                                search_node_init_pending[board_thread_id] <= 1'b0;
                                search_node_init_done[board_thread_id] <= 1'b0;
                                search_stack_top[board_thread_id].direct_attempted <= 1'b0;
                                search_stack_top[board_thread_id].tt_checked <= 1'b0;
                                search_stack_top[board_thread_id].has_tt_move <= 1'b0;
                                search_stack_top[board_thread_id].stand_pat_done
                                    <= board_update_side_in_check;
                                search_stack_top[board_thread_id].static_eval_valid <= 1'b0;
                                search_stack_top[board_thread_id].node_in_check
                                    <= board_update_side_in_check;
                                search_stack_top[board_thread_id].null_attempted <= 1'b0;
                                search_stack_top[board_thread_id].entered_by_null <= 1'b0;
                                search_stack_top[board_thread_id].rfp_checked <= 1'b0;
                                // A new logical node reuses stale address bits but starts with no failed quiets.
                                search_stack_top[board_thread_id].failed_quiet_count <= 2'd0;
                                search_eval_is_stand_pat[board_thread_id] <= 1'b0;
                                search_eval_is_rfp[board_thread_id] <= 1'b0;
                                search_eval_is_futility[board_thread_id] <= 1'b0;
                                search_futility_eval_pending[board_thread_id] <= 1'b0;
                                search_return_valid[board_thread_id] <= 1'b0;
                                search_ply[board_thread_id] <= child_ply;
                                search_thread_phase[board_thread_id] <= SEARCH_PHASE_REPETITION_WAIT;
                            end
                        end

                        // Generation completion is handled separately from pop
                        // completion: an early candidate may already be a child.
                        if (move_cmd_resp_valid
                                && !search_generation_inflight[move_cmd_resp_thread]) begin
                            automatic ThreadID move_thread_id = move_cmd_resp_thread;
                            search_move_result_thread_id <= move_thread_id;
                            search_move_result_valid <= 1'b1;
                            search_move_inflight[move_thread_id] <= 1'b0;
                            search_stack_top[move_thread_id].move_order_state
                                <= move_followup_accepted && move_followup_thread == move_thread_id
                                    ? MOVE_ORDER_GOOD_NOISY : MOVE_ORDER_GENERATE_NOISY;
                            if (move_cmd_resp_direct_valid) begin
                                search_stack_top[move_thread_id].direct_attempted <= 1'b1;
                                search_stack_top[move_thread_id].tt_move <= move_cmd_resp_direct_move;
                                search_pending_move[move_thread_id] <= move_cmd_resp_direct_move;
                                search_pending_move_bucket[move_thread_id] <= QUIET_MEDIUM_BUCKET;
                                search_thread_phase[move_thread_id] <= SEARCH_PHASE_BOARD_WAIT;
                            end else begin
                                search_tt_validation_pending[move_thread_id] <= 1'b0;
                                search_thread_phase[move_thread_id] <= SEARCH_PHASE_READY;
                            end
                        end
                        if (move_pop_resp_valid) begin
                            automatic ThreadID move_thread_id;
                            move_thread_id = move_pop_resp_thread;
                            search_move_result_thread_id <= move_thread_id;
                            search_move_result_valid <= 1'b1;
                            search_move_inflight[move_thread_id]
                                <= move_followup_accepted && !move_followup_uses_quiet
                                    && move_followup_thread == move_thread_id;
                            if (move_pop_resp_found) begin
                                search_pending_move[move_thread_id] <= move_pop_resp_move;
                                search_pending_move_bucket[move_thread_id] <= move_pop_resp_bucket;
                                search_thread_phase[move_thread_id] <= SEARCH_PHASE_BOARD_WAIT;
                            end else begin
                                // Move-order states have distinct encodings.
                                unique case (search_stack_top[move_thread_id].move_order_state)
                                    MOVE_ORDER_GOOD_NOISY:
                                        search_stack_top[move_thread_id].move_order_state
                                            <= search_in_qsearch(move_thread_id)
                                                    && !search_board_in_check[move_thread_id]
                                                ? MOVE_ORDER_DONE
                                                : move_followup_accepted && move_followup_uses_quiet
                                                    && move_followup_thread == move_thread_id
                                                    ? MOVE_ORDER_QUIET : MOVE_ORDER_GENERATE_QUIET;
                                    MOVE_ORDER_QUIET:
                                        search_stack_top[move_thread_id].move_order_state <= MOVE_ORDER_BAD_NOISY;
                                    MOVE_ORDER_BAD_NOISY:
                                        search_stack_top[move_thread_id].move_order_state <= MOVE_ORDER_LOW_QUIET;
                                    default:
                                        search_stack_top[move_thread_id].move_order_state <= MOVE_ORDER_DONE;
                                endcase
                                search_thread_phase[move_thread_id]
                                    <= move_followup_accepted && !move_followup_uses_quiet
                                            && move_followup_thread == move_thread_id
                                        ? SEARCH_PHASE_MOVE_WAIT : SEARCH_PHASE_READY;
                            end
                        end

                        if (nnue_result_valid) begin
                            automatic EvalScore eval_score;
                            automatic ThreadID eval_thread_id;
                            automatic PlyIndex eval_ply;

`ifndef SYNTHESIS
                            assert (nnue_eval_tag_count != 0)
                                else $fatal(1, "NNUE result arrived without an ownership tag");
`endif
                            eval_thread_id = nnue_eval_tag[nnue_eval_tag_read_ptr].thread_id;
                            eval_ply = nnue_eval_tag[nnue_eval_tag_read_ptr].ply;
                            search_eval_result_thread_id <= eval_thread_id;
                            search_eval_result_valid <= 1'b1;
                            eval_score = add_nnue_correction(
                                pov_eval(search_board[eval_thread_id],
                                    nnue_result_pst),
                                nnue_result);
                            nnue_state_valid[eval_thread_id] <= 1'b1;
                            search_eval_is_stand_pat[eval_thread_id] <= 1'b0;
                            search_eval_is_rfp[eval_thread_id] <= 1'b0;
                            search_eval_is_futility[eval_thread_id] <= 1'b0;

                            if (search_eval_is_stand_pat[eval_thread_id]) begin
                                search_stack_top[eval_thread_id].stand_pat_done <= 1'b1;
                                search_stack_top[eval_thread_id].best_score <= eval_score;
                                search_stack_top[eval_thread_id].static_eval <= eval_score;
                                search_stack_top[eval_thread_id].static_eval_valid <= 1'b1;
                                if (eval_score > search_stack_top[eval_thread_id].alpha) begin
                                    search_stack_top[eval_thread_id].alpha <= eval_score;
                                    search_stack_top[eval_thread_id].unit_window
                                        <= search_stack_top[eval_thread_id].beta
                                            == eval_score + EvalScore'(1);
                                end
                                if (eval_score >= search_stack_top[eval_thread_id].beta) begin
                                    search_return_score[eval_thread_id] <= eval_score;
                                    search_return_valid[eval_thread_id] <= 1'b1;
                                    if (eval_ply == PlyIndex'(0)) begin
                                        search_thread_phase[eval_thread_id] <= SEARCH_PHASE_DONE;
                                        search_thread_iteration_score[eval_thread_id] <= eval_score;
                                        search_thread_iteration_best_move[eval_thread_id] <= NULL_MOVE;
                                        search_thread_iteration_ponder_move[eval_thread_id] <= NULL_MOVE;
`ifndef SYNTHESIS
                                        search_thread_completed_best_move[eval_thread_id] <= NULL_MOVE;
`endif
                                        if (active_count_next != ThreadCount'(0)) active_count_next -= ThreadCount'(1);
                                    end else begin
                                        search_thread_phase[eval_thread_id] <= SEARCH_PHASE_REVERSE_WAIT;
                                    end
                                end else begin
                                    search_thread_phase[eval_thread_id] <= SEARCH_PHASE_READY;
                                end
                            end else if (search_eval_is_rfp[eval_thread_id]) begin
                                // A failed margin test resumes normal pruning and
                                // move search without evaluating this node again.
                                search_stack_top[eval_thread_id].rfp_checked <= 1'b1;
                                search_stack_top[eval_thread_id].static_eval <= eval_score;
                                search_stack_top[eval_thread_id].static_eval_valid <= 1'b1;
                                if (rfp_prunes(
                                        eval_score,
                                        search_stack_top[eval_thread_id].beta,
                                        search_stack_top[eval_thread_id].remaining_depth
                                    )) begin
`ifdef FPGA_CHESS_PROFILE
                                    profile_rfp_cutoff_event <= 1'b1;
`endif
                                    search_return_score[eval_thread_id] <= eval_score;
                                    search_return_valid[eval_thread_id] <= 1'b1;
                                    if (eval_ply == PlyIndex'(0)) begin
                                        search_thread_phase[eval_thread_id] <= SEARCH_PHASE_DONE;
                                        search_thread_iteration_score[eval_thread_id] <= eval_score;
                                        search_thread_iteration_best_move[eval_thread_id] <= NULL_MOVE;
                                        search_thread_iteration_ponder_move[eval_thread_id] <= NULL_MOVE;
`ifndef SYNTHESIS
                                        search_thread_completed_best_move[eval_thread_id] <= NULL_MOVE;
`endif
                                        if (active_count_next != ThreadCount'(0)) active_count_next -= ThreadCount'(1);
                                    end else begin
                                        search_thread_phase[eval_thread_id] <= SEARCH_PHASE_REVERSE_WAIT;
                                    end
                                end else begin
                                    search_thread_phase[eval_thread_id] <= SEARCH_PHASE_READY;
                                end
                            end else if (search_eval_is_futility[eval_thread_id]) begin
                                // Retry the retained legal candidate after its
                                // parent receives the one static evaluation this
                                // node may need for all later quiets.
                                search_stack_top[eval_thread_id].static_eval <= eval_score;
                                search_stack_top[eval_thread_id].static_eval_valid <= 1'b1;
                                search_futility_eval_pending[eval_thread_id] <= 1'b0;
                                search_thread_phase[eval_thread_id] <= SEARCH_PHASE_BOARD_WAIT;
                            end else begin
                                search_return_score[eval_thread_id] <= eval_score;
                                search_return_valid[eval_thread_id] <= 1'b1;
                                if (eval_ply == PlyIndex'(0)) begin
                                    search_thread_phase[eval_thread_id] <= SEARCH_PHASE_DONE;
                                    search_thread_iteration_score[eval_thread_id] <= eval_score;
                                    search_thread_iteration_best_move[eval_thread_id] <= NULL_MOVE;
                                    search_thread_iteration_ponder_move[eval_thread_id] <= NULL_MOVE;
`ifndef SYNTHESIS
                                    search_thread_completed_best_move[eval_thread_id] <= NULL_MOVE;
`endif
                                    if (active_count_next != ThreadCount'(0)) active_count_next -= ThreadCount'(1);
                                end else begin
                                    search_thread_phase[eval_thread_id] <= SEARCH_PHASE_REVERSE_WAIT;
                                end
                            end
                        end

                        if (search_tt_consume_valid) begin
                            automatic logic tt_cutoff;
                            automatic logic tt_cutoff_eligible;
                            automatic logic tt_score_usable;
                            automatic logic tt_validation_required;
                            automatic ThreadID lookup_thread_id;
                            automatic PlyIndex lookup_ply;
                            automatic TTLookupResponse lookup_resp;

                            lookup_thread_id = search_tt_consume_thread;
                            lookup_resp = search_tt_consume_response;
                            lookup_ply = search_ply[lookup_thread_id];
                            tt_cutoff = 1'b0;
                            tt_score_usable = lookup_resp.hit
                                && lookup_resp.depth >= search_remaining_depth(lookup_thread_id);
                            tt_cutoff_eligible = tt_score_usable
                                && tt_score_cutoff_eligible(lookup_thread_id);
                            tt_validation_required = tt_cutoff_eligible
                                && search_tt_history_required[lookup_thread_id]
                                && !search_tt_validation_passed[lookup_thread_id];
                            search_thread_id <= lookup_thread_id;
                            search_dispatch.tt_response <= search_thread_after(lookup_thread_id);
                            search_tt_response_pending[lookup_thread_id] <= 1'b0;
                            search_tt_validation_passed[lookup_thread_id] <= 1'b0;

                            // A matching TT move remains useful for ordering even when the
                            // stored depth is too shallow for its score/bound to be usable.
                            if (lookup_resp.hit) begin
                                search_stack_top[lookup_thread_id].tt_move <= lookup_resp.best_move;
                                search_stack_top[lookup_thread_id].has_tt_move <= !is_null_move(lookup_resp.best_move);
                            end
                            if (tt_cutoff_eligible && (!tt_validation_required
                                    || (search_tt_validation_passed[lookup_thread_id]
                                        && lookup_resp.score > DRAW_EVAL_SCORE))) begin
                                if (lookup_resp.bound_type == TT_BOUND_EXACT) begin
                                    search_return_score[lookup_thread_id] <= lookup_resp.score;
                                    search_return_valid[lookup_thread_id] <= 1'b1;
                                    tt_cutoff = 1'b1;
                                end else if (lookup_resp.bound_type == TT_BOUND_LOWER) begin
                                    if (lookup_resp.score > search_stack_top[lookup_thread_id].alpha) begin
                                        search_stack_top[lookup_thread_id].alpha <= lookup_resp.score;
                                        search_stack_top[lookup_thread_id].unit_window
                                            <= search_stack_top[lookup_thread_id].beta
                                                == lookup_resp.score + EvalScore'(1);
                                    end
                                    // max(alpha, score) >= beta, expressed as
                                    // parallel comparisons instead of a mux
                                    // followed by another score comparator.
                                    if (lookup_resp.score >= search_stack_top[lookup_thread_id].beta
                                            || search_stack_top[lookup_thread_id].alpha
                                                >= search_stack_top[lookup_thread_id].beta) begin
                                        search_return_score[lookup_thread_id] <= lookup_resp.score;
                                        search_return_valid[lookup_thread_id] <= 1'b1;
                                        tt_cutoff = 1'b1;
                                    end
                                end else if (lookup_resp.bound_type == TT_BOUND_UPPER) begin
                                    if (lookup_resp.score <= search_stack_top[lookup_thread_id].alpha) begin
                                        search_return_score[lookup_thread_id] <= lookup_resp.score;
                                        search_return_valid[lookup_thread_id] <= 1'b1;
                                        tt_cutoff = 1'b1;
                                    end
                                end
                            end else if (tt_validation_required
                                    && lookup_resp.score > DRAW_EVAL_SCORE
                                    && !is_null_move(lookup_resp.best_move)) begin
                                // A deep history-bearing hit must prove that its
                                // stored move is legal and does not immediately
                                // enter a drawn child before its score is usable.
                                search_tt_validation_pending[lookup_thread_id] <= 1'b1;
                                search_pending_move[lookup_thread_id] <= lookup_resp.best_move;
                            end
`ifndef SYNTHESIS
                            assert (search_tt_history_required[lookup_thread_id]
                                    == tt_history_validation_required(lookup_thread_id))
                                else $fatal(1, "TT history eligibility changed during response validation: thread=%0d ply=%0d", lookup_thread_id, lookup_ply);
                            if (tt_cutoff
                                    && tt_history_validation_required(lookup_thread_id)) begin
                                assert (search_tt_validation_passed[lookup_thread_id])
                                    else $fatal(1, "deep TT score bypassed child validation");
                            end
`endif

                            if (tt_cutoff) begin
                                if (lookup_ply == PlyIndex'(0)) begin
                                    search_thread_phase[lookup_thread_id] <= SEARCH_PHASE_DONE;
                                    search_thread_iteration_score[lookup_thread_id] <= lookup_resp.score;
                                    search_thread_iteration_best_move[lookup_thread_id] <= lookup_resp.best_move;
                                    search_thread_iteration_ponder_move[lookup_thread_id] <= NULL_MOVE;
`ifndef SYNTHESIS
                                    search_thread_completed_best_move[lookup_thread_id] <= lookup_resp.best_move;
`endif
                                    if (active_count_next != ThreadCount'(0)) active_count_next -= ThreadCount'(1);
                                end else begin
                                    search_thread_phase[lookup_thread_id] <= SEARCH_PHASE_REVERSE_WAIT;
                                end
                            end else begin
                                search_thread_phase[lookup_thread_id] <= SEARCH_PHASE_READY;
                            end
                        end

                        // Keep score and history decisions local to each thread; arbitration
                        // enables one update without muxing the parent state through its result.
                        for (int return_idx = 0; return_idx < SEARCH_THREAD_COUNT; return_idx++) begin
                            if (search_return_mask[return_idx]
                                    && search_select_thread(search_return_mask,
                                        search_dispatch.return_result) == ThreadID'(return_idx)) begin
                                automatic ThreadID return_thread_id = ThreadID'(return_idx);
                                automatic EvalScore parent_score;
                                automatic PlyIndex return_ply;

                                return_ply = search_ply[return_thread_id];
                                parent_score = -search_return_score[return_thread_id];
                                search_thread_id <= return_thread_id;
                                search_dispatch.return_result <= search_thread_after(return_thread_id);
                                if (search_return_was_null[return_thread_id]) begin
                                    // A null probe is evidence only: cut off at the
                                    // parent's beta bound or resume real moves.
                                    search_return_was_null[return_thread_id] <= 1'b0;
                                    search_return_was_scout[return_thread_id] <= 1'b0;
                                    search_return_was_reduced[return_thread_id] <= 1'b0;
                                    if (parent_score >= search_stack_top[return_thread_id].beta) begin
                                        search_return_score[return_thread_id]
                                            <= search_stack_top[return_thread_id].beta;
                                        search_return_valid[return_thread_id] <= 1'b1;
                                        if (should_store_search_tt(return_thread_id, return_ply)) begin
                                            search_thread_phase[return_thread_id] <= SEARCH_PHASE_STORE_PUBLISH;
                                        end else begin
                                            search_thread_phase[return_thread_id] <= SEARCH_PHASE_REVERSE_WAIT;
                                        end
                                    end else begin
                                        search_return_valid[return_thread_id] <= 1'b0;
                                        search_thread_phase[return_thread_id] <= SEARCH_PHASE_READY;
                                    end
                                end else if (search_needs_research(
                                        search_return_was_scout[return_thread_id],
                                        search_return_was_reduced[return_thread_id],
                                        parent_score,
                                        search_stack_top[return_thread_id].alpha,
                                        search_stack_top[return_thread_id].beta)) begin
                                    // A scout fail-high that does not cut off must be searched again
                                    // with the parent's original full window before it can be folded.
                                    search_pending_move[return_thread_id] <= search_return_move[return_thread_id];
                                    search_return_valid[return_thread_id] <= 1'b0;
                                    search_return_was_scout[return_thread_id] <= 1'b0;
                                    search_return_was_reduced[return_thread_id] <= 1'b0;
                                    search_pvs_research[return_thread_id] <= 1'b1;
                                    search_pending_child_depth[return_thread_id]
                                        <= search_stack_top[return_thread_id].remaining_depth == SearchDepth'(0)
                                            ? SearchDepth'(0)
                                            : search_stack_top[return_thread_id].remaining_depth - SearchDepth'(1);
                                    search_thread_phase[return_thread_id] <= SEARCH_PHASE_BOARD_WAIT;
                                end else begin
                                    if (return_ply == PlyIndex'(0))
                                        search_root_has_completed_move[return_thread_id] <= 1'b1;
                                    if (!search_stack_top[return_thread_id].has_legal
                                            || parent_score > search_stack_top[return_thread_id].best_score) begin
                                        search_stack_top[return_thread_id].best_score <= parent_score;
                                        search_stack_top[return_thread_id].best_move <= search_return_move[return_thread_id];
                                        if (return_ply == PlyIndex'(0)) begin
                                            search_best_move[return_thread_id] <= search_return_move[return_thread_id];
                                            search_ponder_move[return_thread_id]
                                                <= search_return_ponder_move[return_thread_id];
                                            search_root_best_score[return_thread_id] <= parent_score;
                                            search_root_best_exact[return_thread_id]
                                                <= tt_bound_for_score(
                                                    parent_score,
                                                    search_thread_root_alpha[return_thread_id],
                                                    search_stack_top[return_thread_id].beta
                                                ) == TT_BOUND_EXACT;
                                            if (return_thread_id == ThreadID'(0)) begin
                                                current_best_move_root_nodes
                                                    <= total_root_nodes
                                                        - current_root_move_start_nodes;
                                            end
                                        end
                                    end
                                    search_stack_top[return_thread_id].has_legal <= 1'b1;
                                    if (parent_score > search_stack_top[return_thread_id].alpha) begin
                                        search_stack_top[return_thread_id].alpha <= parent_score;
                                        search_stack_top[return_thread_id].unit_window
                                            <= search_stack_top[return_thread_id].beta
                                                == parent_score + EvalScore'(1);
                                    end
                                    search_return_valid[return_thread_id] <= 1'b0;
                                    search_return_was_scout[return_thread_id] <= 1'b0;
                                    search_return_was_reduced[return_thread_id] <= 1'b0;
                                    if (parent_score >= search_stack_top[return_thread_id].beta) begin
    `ifdef FPGA_CHESS_PROFILE
                                        profile_beta_cutoff_event <= 1'b1;
                                        profile_beta_cutoff_thread <= return_thread_id;
                                        profile_beta_cutoff_ply <= return_ply;
                                        profile_beta_cutoff_rank
                                            <= search_stack_top[return_thread_id].legal_move_count;
                                        profile_beta_cutoff_move <= search_return_move[return_thread_id];
    `endif
                                        if (is_quiet_move(
                                                search_board[return_thread_id],
                                                search_return_move[return_thread_id]
                                            ) && !history_update_pending[return_thread_id]) begin
                                            history_update_pending[return_thread_id] <= 1'b1;
                                            history_update_pending_color[return_thread_id]
                                                <= search_board[return_thread_id].turn;
                                            history_update_pending_from[return_thread_id]
                                                <= search_return_move[return_thread_id].from_pos;
                                            history_update_pending_to[return_thread_id]
                                                <= search_return_move[return_thread_id].to_pos;
                                            history_update_pending_depth[return_thread_id]
                                                <= PlyIndex'(search_stack_top[return_thread_id].remaining_depth);
                                            history_update_pending_failed0[return_thread_id]
                                                <= search_stack_top[return_thread_id].failed_quiet0;
                                            history_update_pending_failed1[return_thread_id]
                                                <= search_stack_top[return_thread_id].failed_quiet1;
                                            history_update_pending_failed2[return_thread_id]
                                                <= search_stack_top[return_thread_id].failed_quiet2;
                                            history_update_pending_failed_count[return_thread_id]
                                                <= search_stack_top[return_thread_id].failed_quiet_count;
                                        end
                                        search_return_score[return_thread_id] <= parent_score;
                                        search_return_valid[return_thread_id] <= 1'b1;
                                        if (should_store_search_tt(return_thread_id, return_ply)) begin
                                            search_thread_phase[return_thread_id] <= SEARCH_PHASE_STORE_PUBLISH;
                                        end else if (return_ply == PlyIndex'(0)) begin
                                            automatic Move root_move;

                                            root_move = (is_null_move(search_best_move[return_thread_id]) && !is_null_move(search_return_move[return_thread_id]))
                                                ? search_return_move[return_thread_id]
                                                : search_best_move[return_thread_id];
                                            search_thread_phase[return_thread_id] <= SEARCH_PHASE_DONE;
                                            search_thread_iteration_score[return_thread_id] <= parent_score;
                                            search_thread_iteration_best_move[return_thread_id] <= root_move;
                                            search_thread_iteration_ponder_move[return_thread_id]
                                                <= is_null_move(search_best_move[return_thread_id])
                                                    ? search_return_ponder_move[return_thread_id]
                                                    : search_ponder_move[return_thread_id];
    `ifndef SYNTHESIS
                                            search_thread_completed_best_move[return_thread_id] <= root_move;
    `endif
                                            if (active_count_next != ThreadCount'(0)) active_count_next -= ThreadCount'(1);
                                        end else begin
                                            search_thread_phase[return_thread_id] <= SEARCH_PHASE_REVERSE_WAIT;
                                        end
                                    end else begin
                                        // Record a quiet only after its complete logical search, including
                                        // any PVS/LMR recovery, has definitively failed to cut off.
                                        if (!search_in_qsearch(return_thread_id)
                                                && is_quiet_move(
                                                    search_board[return_thread_id],
                                                    search_return_move[return_thread_id]
                                                )
                                                && search_stack_top[return_thread_id].failed_quiet_count < 2'd3) begin
                                            // Failed-quiet counts select distinct storage slots.
                                            unique case (search_stack_top[return_thread_id].failed_quiet_count)
                                                2'd0: search_stack_top[return_thread_id].failed_quiet0
                                                    <= {search_return_move[return_thread_id].from_pos,
                                                        search_return_move[return_thread_id].to_pos};
                                                2'd1: search_stack_top[return_thread_id].failed_quiet1
                                                    <= {search_return_move[return_thread_id].from_pos,
                                                        search_return_move[return_thread_id].to_pos};
                                                default: search_stack_top[return_thread_id].failed_quiet2
                                                    <= {search_return_move[return_thread_id].from_pos,
                                                        search_return_move[return_thread_id].to_pos};
                                            endcase
                                            search_stack_top[return_thread_id].failed_quiet_count
                                                <= search_stack_top[return_thread_id].failed_quiet_count + 2'd1;
                                        end
                                        search_thread_phase[return_thread_id] <= SEARCH_PHASE_READY;
                                    end
                                end
                            end
                        end

                        if (|search_terminal_mask) begin
                            automatic ThreadID terminal_thread_id;
                            automatic logic found_terminal;
                            automatic logic terminal_is_no_move;
                            automatic SearchThreadMask terminal_select_mask;

                            found_terminal = 1'b0;
                            terminal_is_no_move = |search_terminal_no_move_mask;
                            terminal_select_mask = terminal_is_no_move
                                ? search_terminal_no_move_mask
                                : search_terminal_mask;
                            terminal_thread_id = ThreadID'(0);
                            for (int offset = 0; offset < SEARCH_THREAD_COUNT; offset++) begin
                                automatic int idx = search_wrap_thread_index(int'(search_dispatch.main) + offset);
                                if (!found_terminal && terminal_select_mask[idx]) begin
                                    found_terminal = 1'b1;
                                    terminal_thread_id = ThreadID'(idx);
                                end
                            end
                            if (found_terminal) begin
                                search_thread_id <= terminal_thread_id;
                                search_dispatch.main <= search_thread_after(terminal_thread_id);
                                if (terminal_is_no_move) begin
`ifdef FPGA_CHESS_PROFILE
                                    profile_terminal_event <= 1'b1;
                                    if (search_in_qsearch(terminal_thread_id))
                                        profile_terminal_kind <= 2'd1;
                                    else if (search_stack_top[terminal_thread_id].has_legal)
                                        profile_terminal_kind <= 2'd0;
                                    else if (search_board_in_check[terminal_thread_id])
                                        profile_terminal_kind <= 2'd2;
                                    else
                                        profile_terminal_kind <= 2'd3;
`endif
                                    terminal_result_valid_pipe <= 1'b1;
                                    terminal_result_thread_pipe <= terminal_thread_id;
                                    terminal_result_ply_pipe <= search_ply[terminal_thread_id];
                                    terminal_result_score_pipe <= search_in_qsearch(terminal_thread_id)
                                            && (!search_board_in_check[terminal_thread_id]
                                                || search_stack_top[terminal_thread_id].has_legal)
                                        ? search_stack_top[terminal_thread_id].best_score
                                        : search_stack_top[terminal_thread_id].has_legal
                                        ? search_stack_top[terminal_thread_id].best_score
                                        : terminal_no_move_score(
                                            search_board_in_check[terminal_thread_id],
                                            search_ply[terminal_thread_id]);
                                    search_thread_phase[terminal_thread_id] <= SEARCH_PHASE_TERMINAL_WAIT;
                                end else begin
                                    search_return_score[terminal_thread_id] <= DRAW_EVAL_SCORE;
                                    search_return_valid[terminal_thread_id] <= 1'b1;
                                end
                                if (!terminal_is_no_move && search_ply[terminal_thread_id] == PlyIndex'(0)) begin
                                    search_thread_phase[terminal_thread_id] <= SEARCH_PHASE_DONE;
                                    search_thread_iteration_score[terminal_thread_id] <= DRAW_EVAL_SCORE;
                                    search_thread_iteration_best_move[terminal_thread_id] <= NULL_MOVE;
                                    search_thread_iteration_ponder_move[terminal_thread_id] <= NULL_MOVE;
`ifndef SYNTHESIS
                                    search_thread_completed_best_move[terminal_thread_id] <= NULL_MOVE;
`endif
                                    if (active_count_next != ThreadCount'(0)) active_count_next -= ThreadCount'(1);
                                end else if (!terminal_is_no_move) begin
                                    search_thread_phase[terminal_thread_id] <= SEARCH_PHASE_REVERSE_WAIT;
                                end
                            end
                        end

                        if (search_tt_lookup_issue_valid && tt_lookup_req_ready) begin
                            search_thread_id <= search_tt_lookup_issue_thread;
                            search_null_candidate[search_tt_lookup_issue_thread]
                                <= search_thread_null_candidate(search_tt_lookup_issue_thread);
                            // Beta, entry window, depth, and check status are fixed for this node.
                            // Register their policy comparisons before they enter shared dispatch.
                            search_stack_top[search_tt_lookup_issue_thread].rfp_eligible
                                <= rfp_node_eligible(
                                    search_stack_top[search_tt_lookup_issue_thread].remaining_depth,
                                    search_stack_top[search_tt_lookup_issue_thread].zero_window_node,
                                    search_board_in_check[search_tt_lookup_issue_thread],
                                    search_stack_top[search_tt_lookup_issue_thread].beta);
                            search_stack_top[search_tt_lookup_issue_thread].null_beta_allowed
                                <= null_beta_eligible(search_stack_top[search_tt_lookup_issue_thread].beta);
                            // Board history and depth remain fixed while this
                            // probe and any retained-response validation run.
                            search_tt_history_required[search_tt_lookup_issue_thread]
                                <= tt_history_validation_required(search_tt_lookup_issue_thread);
                            search_stack_top[search_tt_lookup_issue_thread].tt_checked <= 1'b1;
                            search_thread_phase[search_tt_lookup_issue_thread] <= SEARCH_PHASE_TT_WAIT;
                            search_tt_lookup_inflight[search_tt_lookup_issue_thread] <= 1'b1;
                            search_dispatch.tt_lookup <= search_thread_after(search_tt_lookup_issue_thread);
                        end

                        if (search_eval_issue_valid) begin
                            search_thread_id <= search_eval_issue_thread;
                            search_thread_phase[search_eval_issue_thread] <= SEARCH_PHASE_EVAL_WAIT;
                            search_eval_is_stand_pat[search_eval_issue_thread] <= search_in_qsearch(search_eval_issue_thread)
                                && !search_stack_top[search_eval_issue_thread].stand_pat_done;
                            search_eval_is_rfp[search_eval_issue_thread]
                                <= search_thread_rfp_ready(search_eval_issue_thread);
                            search_eval_is_futility[search_eval_issue_thread]
                                <= search_futility_eval_pending[search_eval_issue_thread];
                            search_dispatch.eval <= search_thread_after(search_eval_issue_thread);
                            nnue_build_busy <= 1'b1;
                            nnue_build_draining
                                <= nnue_state_valid[search_eval_issue_thread];
                            nnue_build_first
                                <= !nnue_state_valid[search_eval_issue_thread];
                            nnue_build_wait_updates
                                <= !nnue_state_valid[search_eval_issue_thread];
                            nnue_build_pos <= Position'(0);
                            nnue_build_thread <= search_eval_issue_thread;
                        end

                        if (move_followup_accepted) begin
                            if (move_followup_uses_quiet)
                                search_dispatch.quiet
                                    <= search_thread_after(move_followup_thread);
                            else
                                search_dispatch.move
                                    <= search_thread_after(move_followup_thread);
                        end

                        if (search_move_issue_valid && move_cmd_valid && move_cmd_ready) begin
                            search_thread_id <= search_move_issue_thread;
                            // Generation and reads are separate transactions:
                            // start reading the admitted class on the next cycle.
                            search_thread_phase[search_move_issue_thread]
                                <= move_cmd_valid && move_cmd == MOVE_GEN_GENERATE_NOISY
                                    ? SEARCH_PHASE_READY : SEARCH_PHASE_MOVE_WAIT;
                            search_move_inflight[search_move_issue_thread]
                                <= !(move_cmd_valid && move_cmd == MOVE_GEN_GENERATE_NOISY);
                            // RFP is an entry-time decision; a full window that
                            // narrows after a child return must not enable it.
                            search_stack_top[search_move_issue_thread].rfp_checked <= 1'b1;
                            if (move_cmd_valid && move_cmd == MOVE_GEN_GENERATE_NOISY) begin
                                search_stack_top[search_move_issue_thread].move_order_state
                                    <= MOVE_ORDER_GOOD_NOISY;
                            end else if (move_cmd_valid && move_cmd == MOVE_GEN_VALIDATE_DIRECT
                                    && !search_stack_top[search_move_issue_thread].has_tt_move) begin
                                search_stack_top[search_move_issue_thread].tt_move
                                    <= move_cmd_suppress_move;
                                search_stack_top[search_move_issue_thread].has_tt_move <= 1'b1;
                            end
                            search_dispatch.move <= search_thread_after(search_move_issue_thread);
                        end

                        // Accept every reader locally, without routing a pop
                        // through shared command arbitration or another thread's
                        // move-order decode.
                        for (int tid = 0; tid < SEARCH_THREAD_COUNT; tid++) begin
                            if (move_pop_valid_vec[tid] && move_pop_ready_vec[tid]) begin
                                search_thread_phase[tid] <= SEARCH_PHASE_MOVE_WAIT;
                                search_move_inflight[tid] <= 1'b1;
                                search_stack_top[tid].rfp_checked <= 1'b1;
                            end
                        end

                        if (search_quiet_issue_valid
                                && move_quiet_cmd_valid && move_quiet_cmd_ready) begin
                            search_thread_id <= search_quiet_issue_thread;
                            search_thread_phase[search_quiet_issue_thread] <= SEARCH_PHASE_READY;
                            search_move_inflight[search_quiet_issue_thread] <= 1'b0;
                            search_stack_top[search_quiet_issue_thread].move_order_state <= MOVE_ORDER_QUIET;
                            search_stack_top[search_quiet_issue_thread].rfp_checked <= 1'b1;
                            search_dispatch.quiet
                                <= search_thread_after(search_quiet_issue_thread);
                        end

                        if (search_board_issue_valid) begin
                            search_thread_id <= search_board_issue_thread;
                            search_thread_phase[search_board_issue_thread] <= SEARCH_PHASE_BOARD_WAIT;
                            search_board_inflight[search_board_issue_thread] <= 1'b1;
                            if (search_board_issue_is_null) begin
                                search_stack_top[search_board_issue_thread].null_attempted <= 1'b1;
                                search_pending_child_depth[search_board_issue_thread]
                                    <= null_child_depth(search_board_issue_thread);
                            end else if (search_thread_phase[search_board_issue_thread] != SEARCH_PHASE_REVERSE_WAIT) begin
                                if (search_pvs_research[search_board_issue_thread]) begin
                                    search_pending_child_depth[search_board_issue_thread]
                                        <= search_stack_top[search_board_issue_thread].remaining_depth == SearchDepth'(0)
                                            ? SearchDepth'(0)
                                            : search_stack_top[search_board_issue_thread].remaining_depth - SearchDepth'(1);
                                end else if (lmr_eligible(
                                        search_ply[search_board_issue_thread],
                                        search_stack_top[search_board_issue_thread].remaining_depth,
                                        search_stack_top[search_board_issue_thread].legal_move_count,
                                        search_pvs_research[search_board_issue_thread])) begin
                                    search_pending_child_depth[search_board_issue_thread] <= lmr_child_depth(search_board_issue_thread, search_board_issue_bucket);
`ifndef SYNTHESIS
                                    assert (floor_log2_8(8'(search_stack_top[search_board_issue_thread].remaining_depth))
                                            < LMR_DEPTH_BUCKETS);
                                    assert (lmr_child_depth(search_board_issue_thread, search_board_issue_bucket)
                                            < search_stack_top[search_board_issue_thread].remaining_depth);
`endif
                                end else begin
                                    search_pending_child_depth[search_board_issue_thread]
                                        <= search_stack_top[search_board_issue_thread].remaining_depth == SearchDepth'(0)
                                            ? SearchDepth'(0)
                                            : search_stack_top[search_board_issue_thread].remaining_depth - SearchDepth'(1);
                                end
                            end
                            search_dispatch.board <= search_thread_after(search_board_issue_thread);
                        end

                        if (search_tt_store_issue_valid && tt_store_req_ready) begin
                            // Store publication completes from the searcher's
                            // perspective as soon as the frontend consumes it.
                            // The frontend may queue or drop it under pressure.
                            search_dispatch.tt_store <= search_thread_after(search_tt_store_issue_thread);
                        end

                        if (search_has_store_complete_thread()) begin
                            automatic ThreadID store_thread_id;
                            automatic PlyIndex store_ply;

                            store_thread_id = search_store_complete_thread();
                            store_ply = search_ply[store_thread_id];
                            search_thread_id <= store_thread_id;
                            search_return_valid[store_thread_id] <= 1'b1;
                            if (store_ply == PlyIndex'(0)) begin
                                search_thread_phase[store_thread_id] <= SEARCH_PHASE_DONE;
                                search_thread_iteration_score[store_thread_id] <= search_return_score[store_thread_id];
                                search_thread_iteration_best_move[store_thread_id]
                                    <= search_stack_top[store_thread_id].best_move;
                                search_thread_iteration_ponder_move[store_thread_id]
                                    <= search_ponder_move[store_thread_id];
`ifndef SYNTHESIS
                                search_thread_completed_best_move[store_thread_id] <= search_stack_top[store_thread_id].best_move;
`endif
                                if (active_count_next != ThreadCount'(0)) active_count_next -= ThreadCount'(1);
                            end else begin
                                search_thread_phase[store_thread_id] <= SEARCH_PHASE_REVERSE_WAIT;
                            end
                        end

                        search_nodes <= nodes_next;
                        search_active_thread_count <= active_count_next;
                    end
                end
