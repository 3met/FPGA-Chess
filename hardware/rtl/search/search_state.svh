// Module-local types, configuration checks, thread state, and pipeline signals.
// Included in search_controller scope; this file is not a standalone compilation unit.

    localparam int BOARD_WAIT_BITS = $clog2(BOARD_UPDATE_PIPELINE_STAGE_CNT + 1);
    localparam int MOVE_WAIT_CYCLES = 2;
    localparam int MOVE_WAIT_BITS = $clog2(MOVE_WAIT_CYCLES + 1);
    localparam int SEARCH_BOARD_TAG_PIPE_LEN = (BOARD_UPDATE_PIPELINE_STAGE_CNT <= 1)
        ? 1 : BOARD_UPDATE_PIPELINE_STAGE_CNT;
    localparam int SEARCH_MOVE_TAG_PIPE_LEN = (MOVE_WAIT_CYCLES <= 1) ? 1 : MOVE_WAIT_CYCLES;
    localparam int THREAD_COUNT_BITS = (SEARCH_THREAD_COUNT <= 1) ? 1 : $clog2(SEARCH_THREAD_COUNT + 1);
    localparam int SEARCH_STACK_ADDR_BITS = (SEARCH_STACK_DEPTH <= 1) ? 1 : $clog2(SEARCH_STACK_DEPTH);
    localparam int SEARCH_DEPTH_BITS = (SEARCH_STACK_DEPTH <= 2) ? 1 : $clog2(SEARCH_STACK_DEPTH);
    localparam int SEARCH_INF_VALUE = 32767;
    localparam int MAX_ASPIRATION_THREAD_OFFSET = (SEARCH_THREAD_COUNT < 8)
        ? SEARCH_THREAD_COUNT - 1 : 7;
    localparam EvalScore SEARCH_INF = EvalScore'(SEARCH_INF_VALUE);
    localparam int LMR_LN2_Q8 = 177;
    localparam int LMR_MAX_REMAINING_DEPTH = SEARCH_STACK_DEPTH - 1;
    // Only floor-log2 buckets reachable by a legal configured search depth exist.
    localparam int LMR_DEPTH_BUCKETS = (LMR_MAX_REMAINING_DEPTH <= 1)
        ? 1 : $clog2(LMR_MAX_REMAINING_DEPTH + 1);

`ifndef SYNTHESIS
    initial begin
        if (SEARCH_BOARD_TAG_PIPE_LEN < 2)
            $fatal(1, "search pruning classification requires two board pipeline stages");
        if (SEARCH_THREAD_COUNT < 1 || SEARCH_THREAD_COUNT > THREAD_COUNT)
            $fatal(1, "SEARCH_THREAD_COUNT must fit the global ThreadID width");
        if (SEARCH_STACK_DEPTH < 1 || SEARCH_STACK_DEPTH > MAX_PLY_COUNT)
            $fatal(1, "SEARCH_STACK_DEPTH must fit the global PlyIndex width");
        if (ASPIRATION_STARTING_DELTA < 1
                || ASPIRATION_STARTING_DELTA > SEARCH_INF_VALUE - MAX_ASPIRATION_THREAD_OFFSET)
            $fatal(1, "ASPIRATION_STARTING_DELTA plus the thread offset must fit the positive score range");
        if (ASPIRATION_DELTA_MULTIPLIER_Q3 <= 8 || ASPIRATION_DELTA_MULTIPLIER_Q3 > 64)
            $fatal(1, "ASPIRATION_DELTA_MULTIPLIER_Q3 must represent a value in (1, 8]");
        if (LMR_MINIMUM_DEPTH < 1 || LMR_MINIMUM_MOVE_NUMBER < 1)
            $fatal(1, "LMR eligibility values must be positive");
        if (NULL_MINIMUM_DEPTH < 1 || NULL_DEEP_DEPTH_THRESHOLD < NULL_MINIMUM_DEPTH)
            $fatal(1, "null-move depth thresholds are inconsistent");
        if (NULL_SHALLOW_REDUCTION >= NULL_MINIMUM_DEPTH
                || NULL_DEEP_REDUCTION >= NULL_DEEP_DEPTH_THRESHOLD)
            $fatal(1, "null-move reductions must leave a nonnegative child depth");
        if (RFP_BASE_MARGIN < 0 || RFP_BASE_MARGIN > SEARCH_INF_VALUE
                || RFP_MARGIN_PER_DEPTH < 0 || RFP_MARGIN_PER_DEPTH > SEARCH_INF_VALUE
                || RFP_MAXIMUM_DEPTH < 1 || RFP_MAXIMUM_DEPTH > MAX_PLY_COUNT)
            $fatal(1, "RFP parameters must fit the score range at a positive supported depth");
        if (FUTILITY_BASE_MARGIN < 0 || FUTILITY_BASE_MARGIN > SEARCH_INF_VALUE
                || FUTILITY_MARGIN_PER_DEPTH < 0
                || FUTILITY_MARGIN_PER_DEPTH > SEARCH_INF_VALUE
                || FUTILITY_MAXIMUM_DEPTH < 1
                || FUTILITY_MAXIMUM_DEPTH >= SEARCH_STACK_DEPTH)
            $fatal(1, "futility parameters must fit the score range and supported child depth");
        if (QDELTA_MARGIN < 0 || QDELTA_MARGIN > SEARCH_INF_VALUE)
            $fatal(1, "QDELTA_MARGIN must fit the positive score range");
    end
`endif

    typedef logic [BOARD_WAIT_BITS-1:0] BoardWaitCount;
    typedef logic [MOVE_WAIT_BITS-1:0] MoveWaitCount;
    typedef logic [THREAD_COUNT_BITS-1:0] ThreadCount;
    typedef logic [SEARCH_STACK_ADDR_BITS-1:0] SearchStackRamAddr;
    typedef logic [SEARCH_DEPTH_BITS-1:0] SearchDepth;
    typedef logic [TIME_BITS+1:0] SearchTimeBase;
    typedef logic [14:0] AspirationDelta;
    typedef logic [SEARCH_THREAD_COUNT-1:0] SearchThreadMask;
    typedef struct packed {
        ThreadID main;
        ThreadID board;
        ThreadID move;
        ThreadID quiet;
        ThreadID eval;
        ThreadID tt_lookup;
        ThreadID tt_store;
        ThreadID return_result;
        ThreadID tt_response;
    } SearchDispatchCursors;

    // A complete node record is packed so each thread's depth stack can infer as
    // one synchronous FPGA RAM instead of many shallow distributed arrays.
    typedef struct packed {
        Move move;
        Move best_move;
        EvalScore best_score;
        // Preserve stand pat after best_score changes so qsearch delta pruning
        // always uses the node's static evaluation.
        EvalScore static_eval;
        EvalScore alpha;
        EvalScore beta;
        Move tt_move;
        PlyIndex repetition_start;
        SearchDepth remaining_depth;
        logic [7:0] legal_move_count;
        MoveOrderState move_order_state;
        logic direct_attempted;
        logic has_legal;
        logic tt_checked;
        logic has_tt_move;
        logic stand_pat_done;
        logic static_eval_valid;
        logic node_in_check;
        logic scout_search;
        // Preserve the node's entry window independently of later alpha raises.
        logic zero_window_node;
        // Cache beta == alpha + 1 so null eligibility does not add on dispatch.
        logic unit_window;
        logic count_move_on_return;
        logic null_attempted;
        logic entered_by_null;
        logic rfp_checked;
        // Cache fixed entry-time policy tests before shared pipeline arbitration.
        logic rfp_eligible;
        logic null_beta_allowed;
        // The entering move supplies squares and promotion choice; turn and
        // null-move state reconstruct the rest of the reversible NNUE delta.
        SearchNnueUndo nnue_undo;
        logic [11:0] failed_quiet0;
        logic [11:0] failed_quiet1;
        logic [11:0] failed_quiet2;
        logic [1:0] failed_quiet_count;
    } SearchStackEntry;


    // Controller-level request, response, and active-position state.
    SearchControllerState state;
    EngineControllerRequest active_req;
    EngineControllerResponse resp_reg;
    BoardWaitCount board_wait_count;
    MoveWaitCount move_wait_count;

    FullBoard active_board;
    logic active_board_in_check;
    ZobristKey active_zobrist_key;
    PstEvalPair active_pst_eval;
    PieceCount active_piece_count;
    logic [6:0] new_setup_index;

    // Perft borrows search context zero and tracks whether each ply starts a node.

    // Per-thread search context and shared-pipeline bookkeeping.
    (* maxfan = 12, max_fanout = 12 *) Move search_best_move[0:SEARCH_THREAD_COUNT-1];
    Move search_ponder_move[0:SEARCH_THREAD_COUNT-1];
    EvalScore search_root_best_score[0:SEARCH_THREAD_COUNT-1];
    // A completed root child provides a legal fallback if the first iteration
    // is interrupted before it can produce an atomic completed result.
    logic search_root_has_completed_move[0:SEARCH_THREAD_COUNT-1];
    // Root candidates are folded only after PVS/LMR recovery, so one bit is
    // enough to retain whether the current best lies strictly inside the
    // iteration's aspiration window rather than being only a score bound.
    logic search_root_best_exact[0:SEARCH_THREAD_COUNT-1];
    NodeCountType search_nodes;
    NodeCountType search_thread_nodes[0:SEARCH_THREAD_COUNT-1];
    logic search_board_inflight[0:SEARCH_THREAD_COUNT-1];
    logic search_move_inflight[0:SEARCH_THREAD_COUNT-1];
    // Generation owns parent storage until its final tops have been published.
    // Reads and speculative child preparation can proceed independently.
    logic search_generation_inflight[0:SEARCH_THREAD_COUNT-1];
    PlyIndex search_generation_ply[0:SEARCH_THREAD_COUNT-1];
    logic search_tt_lookup_inflight[0:SEARCH_THREAD_COUNT-1];
    SearchThreadMask tt_transport_pending;
    logic search_tt_response_pending[0:SEARCH_THREAD_COUNT-1];
    logic search_repetition_pending[0:SEARCH_THREAD_COUNT-1];
    logic search_repetition_done[0:SEARCH_THREAD_COUNT-1];
    logic search_repetition_draw[0:SEARCH_THREAD_COUNT-1];
    // A node probes TT once before descending, so its history flag needs no
    // stack copy when a child temporarily replaces the thread's live state.
    logic search_repetition_seen_before[0:SEARCH_THREAD_COUNT-1];
    logic search_tt_validation_pending[0:SEARCH_THREAD_COUNT-1];
    logic search_tt_validation_passed[0:SEARCH_THREAD_COUNT-1];
    logic search_tt_validation_forced[0:SEARCH_THREAD_COUNT-1];
    logic search_tt_history_required[0:SEARCH_THREAD_COUNT-1];
    TTLookupResponse search_tt_response[0:SEARCH_THREAD_COUNT-1];
    ThreadID search_board_tag_pipe[0:SEARCH_BOARD_TAG_PIPE_LEN-1];
    BoardOp search_board_op_tag_pipe[0:SEARCH_BOARD_TAG_PIPE_LEN-1];
    PlyIndex search_board_ply_tag_pipe[0:SEARCH_BOARD_TAG_PIPE_LEN-1];
    ThreadID search_move_tag_pipe[0:SEARCH_MOVE_TAG_PIPE_LEN-1];
    logic search_move_in_check_pipe[0:SEARCH_MOVE_TAG_PIPE_LEN-1];
    logic search_board_tag_valid_pipe[0:SEARCH_BOARD_TAG_PIPE_LEN-1];
    logic search_node_stop_q, search_time_stop_q;
    logic parent_futility_eligible_q, parent_futility_prunes_q, parent_qdelta_prunes_q;
    logic search_move_tag_valid_pipe[0:SEARCH_MOVE_TAG_PIPE_LEN-1];
`ifndef SYNTHESIS
    ThreadID search_board_result_thread_id;
    ThreadID search_move_result_thread_id;
    ThreadID search_eval_result_thread_id;
    logic search_board_result_valid;
    logic search_move_result_valid;
    logic search_eval_result_valid;
`endif
    // Position and stack state owned by each search context.
    Move search_pending_move[0:SEARCH_THREAD_COUNT-1];
    // Preserve ordering evidence when a popped move waits for board issue.
    MoveBucketIndex search_pending_move_bucket[0:SEARCH_THREAD_COUNT-1];
    FullBoard search_board[0:SEARCH_THREAD_COUNT-1];
    // Cache the side-to-move check status with each board so move dispatch does
    // not put the round-robin board mux in front of the full attack scan.
    logic search_board_in_check[0:SEARCH_THREAD_COUNT-1];
    ZobristKey search_zobrist_key[0:SEARCH_THREAD_COUNT-1];
    PstEvalPair search_pst_eval[0:SEARCH_THREAD_COUNT-1];
    PieceCount search_piece_count[0:SEARCH_THREAD_COUNT-1];
    SearchStackEntry search_stack_top[0:SEARCH_THREAD_COUNT-1];
    SearchStackEntry search_stack_parent_q[0:SEARCH_THREAD_COUNT-1];
    logic [$bits(SearchStackEntry)-1:0] search_stack_parent_bits[0:SEARCH_THREAD_COUNT-1];
    SearchStackRamAddr search_stack_read_addr[0:SEARCH_THREAD_COUNT-1];
    SearchStackRamAddr search_stack_write_addr[0:SEARCH_THREAD_COUNT-1];
    Move search_return_move[0:SEARCH_THREAD_COUNT-1];
    Move search_return_ponder_move[0:SEARCH_THREAD_COUNT-1];
    PlyIndex search_ply[0:SEARCH_THREAD_COUNT-1];
    SearchDepth search_thread_target_depth[0:SEARCH_THREAD_COUNT-1];
    SearchDepth search_max_depth;
    SearchDepth search_completed_depth;
    Move search_completed_best_move;
    Move search_completed_ponder_move;
    EvalScore search_completed_score;
    EvalScore search_thread_root_alpha[0:SEARCH_THREAD_COUNT-1];
    EvalScore search_thread_root_beta[0:SEARCH_THREAD_COUNT-1];
    AspirationDelta search_thread_aspiration_delta[0:SEARCH_THREAD_COUNT-1];
    logic search_thread_aspiration_active[0:SEARCH_THREAD_COUNT-1];
    Move search_thread_iteration_best_move[0:SEARCH_THREAD_COUNT-1];
    Move search_thread_iteration_ponder_move[0:SEARCH_THREAD_COUNT-1];
    EvalScore search_thread_iteration_score[0:SEARCH_THREAD_COUNT-1];
`ifndef SYNTHESIS
    logic [7:0] search_thread_completed_depth[0:SEARCH_THREAD_COUNT-1];
    Move search_thread_completed_best_move[0:SEARCH_THREAD_COUNT-1];
`endif
    // Scheduler cursors select helper work after giving ready primary work priority.
    ThreadID search_thread_id;
    SearchDispatchCursors search_dispatch;
    SearchThreadMask search_store_mask;
    SearchThreadMask search_board_mask;
    SearchThreadMask search_move_mask;
    SearchThreadMask search_quiet_mask;
    SearchThreadMask search_eval_mask;
    SearchThreadMask search_tt_lookup_mask;
    SearchThreadMask search_return_mask;
    SearchThreadMask search_tt_response_mask;
    SearchThreadMask search_null_mask;
    SearchThreadMask search_terminal_mask;
    SearchThreadMask search_terminal_no_move_mask;
    logic search_null_candidate[0:SEARCH_THREAD_COUNT-1];
    SearchThreadPhase search_thread_phase[0:SEARCH_THREAD_COUNT-1];
    ThreadCount search_active_thread_count;
    EvalScore search_return_score[0:SEARCH_THREAD_COUNT-1];
    logic search_return_valid[0:SEARCH_THREAD_COUNT-1];
    logic search_return_was_scout[0:SEARCH_THREAD_COUNT-1];
    logic search_return_was_reduced[0:SEARCH_THREAD_COUNT-1];
    logic search_return_was_null[0:SEARCH_THREAD_COUNT-1];
    logic search_pvs_research[0:SEARCH_THREAD_COUNT-1];
    SearchDepth search_pending_child_depth[0:SEARCH_THREAD_COUNT-1];
    logic search_eval_is_stand_pat[0:SEARCH_THREAD_COUNT-1];
    logic search_eval_is_rfp[0:SEARCH_THREAD_COUNT-1];
    logic search_eval_is_futility[0:SEARCH_THREAD_COUNT-1];
    logic search_futility_eval_pending[0:SEARCH_THREAD_COUNT-1];
    logic terminal_result_valid_pipe;
    ThreadID terminal_result_thread_pipe;
    PlyIndex terminal_result_ply_pipe;
    EvalScore terminal_result_score_pipe;
`ifdef FPGA_CHESS_PROFILE
    // One-cycle semantic event used only by the external simulation profiler.
    logic profile_terminal_event;
    logic [1:0] profile_terminal_kind;
    logic profile_rfp_cutoff_event;
    logic profile_futility_prune_event;
    logic profile_qdelta_prune_event;
    logic profile_beta_cutoff_event;
    ThreadID profile_beta_cutoff_thread;
    PlyIndex profile_beta_cutoff_ply;
    logic [7:0] profile_beta_cutoff_rank;
    Move profile_beta_cutoff_move;
`endif

    // Shared board-update pipeline request and result signals.
    BoardOp board_update_op;
    FullBoard board_update_in;
    ZobristKey board_update_zobrist_in;
    PstEvalPair board_update_pst_in;
    PieceCount board_update_piece_count_in;
    Move board_update_move;
    logic [6:0] board_update_set_data;
    ThreadID board_update_thread_id;
    PlyIndex board_update_ply;
    FullBoard board_update_out;
    ZobristKey board_update_zobrist_out;
    PstEvalPair board_update_pst_out;
    PieceCount board_update_piece_count_out;
    logic board_update_mover_in_check;
    // Evaluate a completed board once, then retain its check status with the
    // board context that accepts it instead of scanning during move dispatch.
    logic board_update_side_in_check;

    // Shared variable-latency move-generation and bucket-store interfaces.
    logic move_cmd_valid;
    logic move_cmd_ready;
    MoveGenCommand move_cmd;
    ThreadID move_cmd_thread;
    PlyIndex move_cmd_ply;
    FullBoard move_cmd_board;
    logic move_cmd_in_check;
    logic move_cmd_suppress_valid;
    Move move_cmd_suppress_move;
    logic move_cmd_resp_valid;
    ThreadID move_cmd_resp_thread;
    PlyIndex move_cmd_resp_ply;
    logic move_cmd_resp_direct_valid;
    Move move_cmd_resp_direct_move;
    logic move_quiet_cmd_valid;
    logic move_quiet_cmd_ready;
    ThreadID move_quiet_cmd_thread;
    PlyIndex move_quiet_cmd_ply;
    FullBoard move_quiet_cmd_board;
    logic move_quiet_cmd_in_check;
    logic move_quiet_cmd_suppress_valid;
    Move move_quiet_cmd_suppress_move;
    logic move_quiet_resp_valid;
    ThreadID move_quiet_resp_thread;
    PlyIndex move_quiet_resp_ply;
    logic move_pop_valid;
    logic move_pop_ready;
    ThreadID move_pop_thread;
    logic move_pop_resp_valid;
    ThreadID move_pop_resp_thread;
    PlyIndex move_pop_resp_ply;
    logic move_pop_resp_found;
    Move move_pop_resp_move;
    MoveBucketIndex move_pop_resp_bucket;
    logic move_pop_valid_vec[SEARCH_THREAD_COUNT], move_pop_ready_vec[SEARCH_THREAD_COUNT];
    logic move_node_init_valid[SEARCH_THREAD_COUNT];
    logic move_node_init_ready[SEARCH_THREAD_COUNT];
    PlyIndex move_node_init_ply[SEARCH_THREAD_COUNT];
    logic search_node_init_request[SEARCH_THREAD_COUNT];
    logic search_direct_command[SEARCH_THREAD_COUNT];
    logic search_node_init_pending[SEARCH_THREAD_COUNT];
    logic search_node_init_done[SEARCH_THREAD_COUNT];
    logic move_bad_noisy_enable[SEARCH_THREAD_COUNT];
    PlyIndex move_pop_ply_vec[SEARCH_THREAD_COUNT], move_pop_resp_ply_vec[SEARCH_THREAD_COUNT];
    logic move_pop_resp_valid_vec[SEARCH_THREAD_COUNT], move_pop_resp_ready_vec[SEARCH_THREAD_COUNT];
    logic move_pop_resp_found_vec[SEARCH_THREAD_COUNT];
    Move move_pop_resp_move_vec[SEARCH_THREAD_COUNT];
    MoveBucketIndex move_pop_resp_bucket_vec[SEARCH_THREAD_COUNT];
    logic [SEARCH_THREAD_COUNT-1:0] move_pop_response_mask;
    ThreadID move_pop_response_thread;
    ThreadID move_pop_response_rr;
    logic move_history_update_valid;
    logic move_history_update_ready;
    ThreadID move_history_update_thread;
    Color move_history_update_color;
    Position move_history_update_from;
    Position move_history_update_to;
    PlyIndex move_history_update_depth;
    logic [11:0] move_history_update_failed0;
    logic [11:0] move_history_update_failed1;
    logic [11:0] move_history_update_failed2;
    logic [1:0] move_history_update_failed_count;
    logic move_init_busy;
    logic move_overflow_sticky;
    logic [39:0] move_stat_noisy_count;
    logic [39:0] move_stat_quiet_count;
    logic [39:0] move_stat_destination_count;
    logic [39:0] move_stat_candidate_count;
    logic [39:0] move_stat_history_lookup_count;
    logic [39:0] move_stat_generation_cycles;
    logic [39:0] move_stat_bucket_count[MOVE_BUCKET_COUNT];
    MoveBucketTop move_stat_bucket_high_water[MOVE_BUCKET_COUNT];
    logic history_update_pending[0:SEARCH_THREAD_COUNT-1];
    Color history_update_pending_color[0:SEARCH_THREAD_COUNT-1];
    Position history_update_pending_from[0:SEARCH_THREAD_COUNT-1];
    Position history_update_pending_to[0:SEARCH_THREAD_COUNT-1];
    PlyIndex history_update_pending_depth[0:SEARCH_THREAD_COUNT-1];
    logic [11:0] history_update_pending_failed0[0:SEARCH_THREAD_COUNT-1];
    logic [11:0] history_update_pending_failed1[0:SEARCH_THREAD_COUNT-1];
    logic [11:0] history_update_pending_failed2[0:SEARCH_THREAD_COUNT-1];
    logic [1:0] history_update_pending_failed_count[0:SEARCH_THREAD_COUNT-1];

    // NNUE evaluations are serialized while one board is replayed through the
    // physical feature-update port; search threads remain independently schedulable.
    logic nnue_build_busy, nnue_build_draining, nnue_build_first;
    logic nnue_build_wait_updates;
    Position nnue_build_pos;
    ThreadID nnue_build_thread;
    logic nnue_roots_initialized, nnue_root_init_draining, nnue_root_init_first;
    ThreadID nnue_root_init_thread;
    Position nnue_root_init_pos;
    logic nnue_clear;
    logic nnue_update_valid, nnue_update_ready, nnue_update_idle;
    NnueUpdateRequest nnue_update_req;
    logic nnue_delta_update_valid;
    NnueUpdateRequest nnue_delta_update_req;
    logic nnue_update_done_valid;
    ThreadID nnue_update_done_thread;
    PlyIndex nnue_update_done_ply;
    logic nnue_eval_valid, nnue_eval_ready, nnue_result_valid;
    EvalScore nnue_result;
    EvalScore nnue_result_pst;
    SearchPipelineTag nnue_eval_tag[2];
    logic nnue_eval_tag_read_ptr, nnue_eval_tag_write_ptr;
    logic [1:0] nnue_eval_tag_count;
    logic nnue_state_valid[0:SEARCH_THREAD_COUNT-1];
    logic nnue_plan_pending[0:SEARCH_THREAD_COUNT-1];
    logic nnue_plan_inflight[0:SEARCH_THREAD_COUNT-1];
    SearchNnuePlan nnue_plan[0:SEARCH_THREAD_COUNT-1];
    logic nnue_plan_any;
    logic nnue_delta_busy, nnue_delta_draining, nnue_delta_replay, nnue_delta_first;
    ThreadID nnue_delta_thread;
    ThreadID nnue_plan_rr_ptr, nnue_plan_select_thread;
    logic nnue_plan_select_valid;
    logic [2:0] nnue_delta_step;
    Position nnue_delta_pos;

    // Shared transposition-table frontend request and result signals.
    logic tt_clear;
    logic tt_clear_busy;
    // Reset work is infrequent: register the clear pulse rather than routing
    // the controller's wide state decoder into cache-bank read controls.
    always_ff @(posedge clk) begin
        if (!rst_n) tt_clear <= 1'b0;
        else tt_clear <= state == CTRL_NEW_CLEAR_START;
    end

    logic tt_store_bank_valid, tt_store_bank;
    SearchThreadMask tt_noncolliding_lookup_mask;
    logic tt_lookup_req_valid;
    logic tt_lookup_req_ready;
    TTLookupRequest tt_lookup_req;
    logic tt_lookup_resp_valid;
    TTLookupResponse tt_lookup_resp;
    logic tt_cache_access;
    logic tt_cache_hit;
    logic tt_cache_store_access, tt_cache_store_hit;
    logic tt_store_req_valid;
    logic tt_store_req_ready;
    TTStoreRequest tt_store_req;
    TTAge tt_age;

    // Operation timer and scheduler-selected pipeline issues.
    logic timer_rst;
    logic timer_run;
    TimeType elapsed_ms;
    SearchTimeBase search_base_ms;
    TimeType search_soft_ms;
    TimeType search_next_depth_ms;
    TimeType search_hard_ms;
    logic time_management_cancel;
    logic time_setup_start;
    logic time_adaptive_start;
    logic time_management_done;
    SearchTimeBase allocated_base_ms;
    TimeType allocated_soft_ms;
    TimeType allocated_next_depth_ms;
    TimeType allocated_hard_ms;
    logic [3:0] pending_soft_factor;
    logic pending_single_legal_move;
    Move previous_depth_best_move;
    logic [7:0] best_move_stable_depths;
    EvalScore previous_depth_score;
    NodeCountType total_root_nodes;
    NodeCountType current_best_move_root_nodes;
    NodeCountType current_root_move_start_nodes;
    EngineControllerRequest setup_req_comb;
    logic search_board_issue_valid;
    logic search_move_issue_valid;
    logic search_quiet_issue_valid;
    logic search_eval_issue_valid;
    logic search_tt_lookup_issue_valid;
    logic search_tt_store_issue_valid;
    logic search_tt_consume_valid;
    logic search_null_issue_valid;
    logic search_board_issue_is_null;
    ThreadID search_board_issue_thread;
    ThreadID search_board_work_thread;
    ThreadID search_null_issue_thread;
    ThreadID search_move_issue_thread;
    ThreadID search_quiet_issue_thread;
    ThreadID search_eval_issue_thread;
    ThreadID search_tt_lookup_issue_thread;
    ThreadID search_tt_store_issue_thread;
    ThreadID search_tt_consume_thread;
    TTLookupResponse search_tt_consume_response;
    logic move_board_bypass_valid;
    ThreadID move_board_bypass_thread;
    Move move_board_bypass_move;
    MoveBucketIndex search_board_issue_bucket;

    // Repetition checker request, response, and epoch state.
    localparam int REPETITION_EPOCH_BITS = 4;
    logic [REPETITION_EPOCH_BITS-1:0] repetition_epoch;
    logic repetition_init_start;
    logic repetition_init_done;
    logic repetition_init_failed;
    logic repetition_history_reset;
    logic repetition_history_write;
    ZobristKey repetition_history_key;
    logic repetition_line_write_valid;
    logic repetition_req_valid;
    ThreadID repetition_line_write_thread;
    ThreadID repetition_req_thread;
    PlyIndex repetition_line_write_ply;
    PlyIndex repetition_req_ply;
    PlyIndex repetition_req_start_ply;
    ZobristKey repetition_line_write_key;
    ZobristKey repetition_req_key;
    logic repetition_resp_valid;
    logic repetition_resp_is_draw;
    ThreadID repetition_resp_thread;
    logic [REPETITION_EPOCH_BITS-1:0] repetition_resp_epoch;
    logic [1:0] repetition_resp_count;

    assign resp = resp_reg;
    assign req_ready = (req_valid && req.operation == ENGINE_CTRL_KILL && state != CTRL_IDLE)
        || state == CTRL_IDLE;
