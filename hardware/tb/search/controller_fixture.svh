// Controller fixture signals, observation state, DUT parameters, and TT memory model.
// Included in tb_search_controller scope.

    // Run the same acceptance checks with serial and concurrent dispatch.
    localparam int SEARCH_STACK_DEPTH = 24;

    logic clk;
    logic rst_n;
    logic req_valid;
    logic req_ready;
    EngineControllerRequest req;
    logic resp_valid;
    logic resp_ready = 1'b1;
    EngineControllerResponse resp;
    logic [7:0] debug_stat_address;
    logic [39:0] debug_stat_value;
    logic stats_reset_pending;
    logic [39:0] last_move_generation_cycles;
    logic [39:0] last_move_destination_count;
    logic [39:0] last_move_candidate_count;

    int pass_count = 0;
    int fail_count = 0;
    int tt_lookup_count = 0;
    int tt_hit_count = 0;
    int tt_store_count = 0;
    logic observe_underpromotion = 0, underpromotion_store_seen = 0;
    TTStoreRequest underpromotion_store;
    int tt_validation_repetition_count = 0;
    int tt_validation_pass_count = 0;
    int tt_validation_repeat_reject_count = 0;
    int tt_validation_nonpositive_reject_count = 0;
    int tt_validation_illegal_reject_count = 0;
    bit tt_thread_seen[0:THREAD_COUNT-1];
    bit tt_response_thread_seen[0:THREAD_COUNT-1];
    bit root_push_seen[0:THREAD_COUNT-1];
    bit root_stack_seen[0:THREAD_COUNT-1];
    bit root_stack_capture_pending[0:THREAD_COUNT-1];
    bit repetition_root_request_seen;
    bit repetition_child_request_seen;
    bit repetition_child_draw_seen;
    bit all_threads_root_active_seen;
    bit search_dispatch_state_seen;
    bit active_thread_count_full_seen;
    bit active_thread_count_decrement_seen;
    bit store_wait_dispatch_seen;
    bit store_wait_issue_seen;
    bit return_pending_dispatch_seen;
    bit move_continuation_seen;
    bit direct_reject_waiting[THREAD_COUNT];
    PlyIndex direct_reject_waiting_ply[THREAD_COUNT];
    bit direct_reject_followup_seen = 1'b0;
    bit direct_reject_followup_check_pending = 1'b0;
    ThreadID direct_reject_followup_thread;
    PlyIndex direct_reject_followup_ply;
    int early_noisy_reads = 0, early_quiet_reads = 0;
    int early_child_preparations = 0, repaired_parents = 0;
    int early_child_search_requests = 0;
    move_generator_defs::MoveBucketIndex last_read_bucket[THREAD_COUNT][SEARCH_STACK_DEPTH];
    bit tt_response_consume_seen;
    bit tt_response_buffered_consume_seen;
    bit multi_move_inflight_seen;
    bit pipeline_overlap_seen;
    bit pvs_scout_seen;
    bit aspiration_window_seen;
    bit lmr_reduced_issue_seen;
    bit lmr_illegal_candidate_seen;
    bit lmr_recovery_issue_seen;
    bit lmr_reduced_tt_depth_seen;
    bit lmr_full_tt_depth_seen;
    bit stats_reset_correct = 1'b1;
    bit tt_lookup_depth_correct = 1'b1;
    bit tt_store_depth_correct = 1'b1;
    bit null_push_seen;
    bit null_reverse_seen;
    bit rfp_eval_seen;
    bit nnue_delta_seen;
    bit nnue_rebuild_seen;
    bit nnue_pending_state_invalid = 1'b1;
    bit nnue_root_initialization_seen;
    bit nnue_root_initialization_correct = 1'b1;
    bit nnue_king_delta_seen;
    bit nnue_king_delta_correct = 1'b1;
    bit nnue_castle_delta_seen;
    bit nnue_castle_request_count_correct = 1'b1;
    bit nnue_castle_state_seen;
    bit nnue_en_passant_state_seen;
    bit nnue_promotion_state_seen;
    bit nnue_special_state_correct = 1'b1;
    bit nnue_reverse_delta_seen;
    bit nnue_cached_pop_seen;
    SearchControllerState previous_setup_state;
    ThreadID previous_setup_thread;
    bit nnue_null_state_seen;
    bit nnue_null_state_correct = 1'b1;
    int nnue_root_rebuild_count[0:THREAD_COUNT-1];
    int nnue_castle_request_count[0:THREAD_COUNT-1];
    bit lmr_bucket_check_pending[0:THREAD_COUNT-1];
    move_generator_defs::MoveBucketIndex lmr_expected_bucket[0:THREAD_COUNT-1];
    bit lmr_depth_check_pending[0:THREAD_COUNT-1];
    bit lmr_recovery_check_pending[0:THREAD_COUNT-1];
    bit lmr_full_tt_pending[0:THREAD_COUNT-1];
    logic [7:0] lmr_expected_child_depth[0:THREAD_COUNT-1];
    logic [7:0] lmr_issue_legal_count[0:THREAD_COUNT-1];
    bit shallow_tt_hit_seen;
    bit shallow_tt_target_seen;
    bit shallow_tt_target_pending[0:THREAD_COUNT-1];
    Move shallow_tt_target_move[0:THREAD_COUNT-1];
    bit thread_selected_active_seen[0:THREAD_COUNT-1];
    bit thread_rr_cursor_seen[0:THREAD_COUNT-1];
    bit thread_board_cursor_seen[0:THREAD_COUNT-1];
    bit thread_move_cursor_seen[0:THREAD_COUNT-1];
    bit thread_eval_cursor_seen[0:THREAD_COUNT-1];
    bit thread_tt_lookup_cursor_seen[0:THREAD_COUNT-1];
    bit thread_tt_store_cursor_seen[0:THREAD_COUNT-1];
    bit thread_tt_response_cursor_seen[0:THREAD_COUNT-1];
    bit thread_return_cursor_seen[0:THREAD_COUNT-1];
    bit thread_ready_phase_seen[0:THREAD_COUNT-1];
    bit thread_move_phase_seen[0:THREAD_COUNT-1];
    bit thread_board_phase_seen[0:THREAD_COUNT-1];
    bit thread_eval_phase_seen[0:THREAD_COUNT-1];
    bit thread_store_phase_seen[0:THREAD_COUNT-1];
    bit thread_board_inflight_seen[0:THREAD_COUNT-1];
    bit thread_move_inflight_seen[0:THREAD_COUNT-1];
    bit thread_eval_inflight_seen[0:THREAD_COUNT-1];
    bit thread_tt_lookup_inflight_seen[0:THREAD_COUNT-1];
    bit thread_tt_store_inflight_seen[0:THREAD_COUNT-1];
    bit thread_board_tag_seen[0:THREAD_COUNT-1];
    bit thread_move_tag_seen[0:THREAD_COUNT-1];
    bit thread_eval_tag_seen[0:THREAD_COUNT-1];
    bit thread_move_handoff_seen[0:THREAD_COUNT-1];
    bit thread_eval_handoff_seen[0:THREAD_COUNT-1];
    Move root_first_move[0:THREAD_COUNT-1];
    Move root_first_stack_move[0:THREAD_COUNT-1];

    logic tt_mem_req_valid, tt_mem_req_ready, tt_mem_req_write;
    tt_defs::TTWordAddress tt_mem_req_address;
    tt_defs::TTBurstLength tt_mem_req_length;
    logic tt_mem_write_valid, tt_mem_write_ready, tt_mem_write_last;
    logic [15:0] tt_mem_write_data;
    logic tt_mem_read_valid, tt_mem_read_ready, tt_mem_read_last;
    logic [15:0] tt_mem_read_data;
    logic tt_mem_done_valid, tt_mem_done_ready, tt_mem_done_error;
    logic tt_memory_enabled = 1'b1, tt_model_ready;
    assign tt_mem_req_ready = tt_memory_enabled && tt_model_ready;
    tt_burst_memory_model #(.WORD_COUNT((1 << (MATE_ONLY ? 10 : 4))*tt_defs::TT_WORDS_PER_ENTRY)) tt_memory (
        .clk, .rst_n, .req_valid(tt_mem_req_valid && tt_memory_enabled), .req_ready(tt_model_ready), .req_write(tt_mem_req_write),
        .req_address(tt_mem_req_address), .req_length(tt_mem_req_length),
        .write_valid(tt_mem_write_valid), .write_ready(tt_mem_write_ready), .write_data(tt_mem_write_data), .write_last(tt_mem_write_last),
        .read_valid(tt_mem_read_valid), .read_ready(tt_mem_read_ready), .read_data(tt_mem_read_data), .read_last(tt_mem_read_last),
        .done_valid(tt_mem_done_valid), .done_ready(tt_mem_done_ready), .done_error(tt_mem_done_error));

    search_controller #(
        .CLOCK_FREQ(1_000_000),
        // Directed margin and reduction boundaries use an explicit fixture policy.
        .LMR_A_Q8(192), .LMR_B_Q8(614), .LMR_MINIMUM_DEPTH(3), .LMR_MINIMUM_MOVE_NUMBER(3),
        .NULL_MINIMUM_DEPTH(3), .NULL_DEEP_DEPTH_THRESHOLD(7),
        .NULL_SHALLOW_REDUCTION(2), .NULL_DEEP_REDUCTION(3),
        .RFP_BASE_MARGIN(64), .RFP_MARGIN_PER_DEPTH(128), .RFP_MAXIMUM_DEPTH(5),
        .FUTILITY_BASE_MARGIN(192), .FUTILITY_MARGIN_PER_DEPTH(192), .FUTILITY_MAXIMUM_DEPTH(3),
        .QDELTA_MARGIN(384),
        // Full mating searches use a larger table; the shallow acceptance
        // cases retain their tiny table to exercise replacement and misses.
        .TT_ENTRY_COUNT(1 << (MATE_ONLY ? 10 : 4)),
        .SEARCH_THREAD_COUNT(THREAD_COUNT),
        .SEARCH_STACK_DEPTH(SEARCH_STACK_DEPTH),
        // The focused variant puts ordinary quiets in the highest quiet bucket without
        // seeding internal RAM, so real search must exercise early quiet reads.
        .HISTORY_DEFAULT_SCORE(16),
        .QUIET_THRESHOLD_1(EARLY_ONLY ? 1 : 32),
        .QUIET_THRESHOLD_2(EARLY_ONLY ? 2 : 64),
        .QUIET_THRESHOLD_3(EARLY_ONLY ? 3 : 128),
        .ENABLE_SEARCH_STATS(1'b1)
    ) dut (
        .clk(clk),
        .tt_memory_clk(clk), .tt_memory_rst_n(rst_n),
        .rst_n(rst_n),
        .tt_memory_ready(1'b1), .tt_memory_error(1'b0),
        .tt_mem_req_valid, .tt_mem_req_ready, .tt_mem_req_write, .tt_mem_req_address, .tt_mem_req_length,
        .tt_mem_write_valid, .tt_mem_write_ready, .tt_mem_write_data, .tt_mem_write_last,
        .tt_mem_read_valid, .tt_mem_read_ready, .tt_mem_read_data, .tt_mem_read_last,
        .tt_mem_done_valid, .tt_mem_done_ready, .tt_mem_done_error,
        .req_valid(req_valid),
        .req_ready(req_ready),
        .req(req),
        .resp_valid(resp_valid),
        .resp_ready(resp_ready),
        .resp(resp),
        .debug_stat_address(debug_stat_address),
        .debug_stat_value(debug_stat_value)
    );
