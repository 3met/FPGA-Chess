// Shared pipeline instances, stack RAMs, transport ownership, and instrumentation.
// Included in search_controller scope; this file is not a standalone compilation unit.

    // Canceled searches still own their accepted TT probes until they return.
    // Prevent thread reuse from associating an old response with a new position.
    always_ff @(posedge clk) begin
        if (!rst_n) tt_transport_pending <= '0;
        else begin
            if (tt_lookup_resp_valid) tt_transport_pending[tt_lookup_resp.thread_id] <= 1'b0;
            if (tt_lookup_req_valid && tt_lookup_req_ready)
                tt_transport_pending[tt_lookup_req.thread_id] <= 1'b1;
        end
    end

    // Complete storage ownership independently of the move-read transaction.
    // The synchronous parent read must be aligned before repairing a saved node.
    // Collapse independent reader responses in a separate combinational block
    // so scheduler logic sees the current response without relying on
    // procedural assignment order inside its larger control block.
    always_comb begin
        move_pop_response_mask = '0;
        for (int tid = 0; tid < SEARCH_THREAD_COUNT; tid++)
            move_pop_response_mask[tid] = move_pop_resp_valid_vec[tid];
        move_pop_resp_valid = |move_pop_response_mask;
        move_pop_response_thread = search_select_thread(
            move_pop_response_mask, move_pop_response_rr);
        move_pop_resp_thread = move_pop_response_thread;
        move_pop_resp_ply = PlyIndex'(0);
        move_pop_resp_found = 1'b0;
        move_pop_resp_move = NULL_MOVE;
        move_pop_resp_bucket = MoveBucketIndex'(0);
        if (move_pop_resp_valid) begin
            move_pop_resp_ply = move_pop_resp_ply_vec[move_pop_response_thread];
            move_pop_resp_found = move_pop_resp_found_vec[move_pop_response_thread];
            move_pop_resp_move = move_pop_resp_move_vec[move_pop_response_thread];
            move_pop_resp_bucket = move_pop_resp_bucket_vec[move_pop_response_thread];
        end
    end

    always_ff @(posedge clk) begin
        for (int tid = 0; tid < SEARCH_THREAD_COUNT; tid++) begin
            if (!rst_n || state != CTRL_SEARCH_RUN
                    || (req_valid && req.operation == ENGINE_CTRL_KILL)) begin
                search_generation_inflight[tid] <= 1'b0;
                search_generation_ply[tid] <= '0;
            end else begin
                // A direct-validation response is not generation completion.
                // Clear only the tracked generation with the matching tag.
                if (search_generation_inflight[tid]
                        && ((move_cmd_resp_valid
                                && move_cmd_resp_thread == ThreadID'(tid)
                                && move_cmd_resp_ply == search_generation_ply[tid])
                            || (move_quiet_resp_valid
                                && move_quiet_resp_thread == ThreadID'(tid)
                                && move_quiet_resp_ply == search_generation_ply[tid]))) begin
                    search_generation_inflight[tid] <= 1'b0;
                end
                // New ownership takes precedence when a rejected direct move
                // chains directly into noisy generation on the same edge.
                if (move_cmd_valid && move_cmd_ready && move_cmd == MOVE_GEN_GENERATE_NOISY
                        && move_cmd_thread == ThreadID'(tid)) begin
                    search_generation_inflight[tid] <= 1'b1;
                    search_generation_ply[tid] <= move_cmd_ply;
                end
                if (move_quiet_cmd_valid && move_quiet_cmd_ready
                        && move_quiet_cmd_thread == ThreadID'(tid)) begin
                    search_generation_inflight[tid] <= 1'b1;
                    search_generation_ply[tid] <= move_quiet_cmd_ply;
                end
            end
        end
    end

    // Keep each thread in a separate one-dimensional RAM instance so both
    // Quartus and Vivado recognize the packed node records as block memory.
    genvar stack_tid;
    generate
        for (stack_tid = 0; stack_tid < SEARCH_THREAD_COUNT; stack_tid = stack_tid + 1) begin : gen_search_stack_ram
            assign search_stack_write_addr[stack_tid]
                = SearchStackRamAddr'(search_ply[stack_tid]);
            assign search_stack_read_addr[stack_tid] = SearchStackRamAddr'(
                (search_ply[stack_tid] == PlyIndex'(0)) ? PlyIndex'(0) : search_ply[stack_tid] - PlyIndex'(1)
            );
            assign search_stack_parent_q[stack_tid] = SearchStackEntry'(search_stack_parent_bits[stack_tid]);

            sync_read_simple_dual_port_ram #(
                .NUM_WORDS(SEARCH_STACK_DEPTH),
                .WORD_SIZE($bits(SearchStackEntry))
            ) stack_memory (
                .clock(clk),
                .data(search_stack_top[stack_tid]),
                .rdaddress(search_stack_read_addr[stack_tid]),
                .rden(rst_n),
                .wraddress(search_stack_write_addr[stack_tid]),
                .wren(rst_n),
                .q(search_stack_parent_bits[stack_tid])
            );
        end
    endgenerate

    board_update_pipeline #(
        .MOVE_RECORD_THREAD_COUNT(SEARCH_THREAD_COUNT),
        .MOVE_RECORD_PLY_COUNT(SEARCH_STACK_DEPTH)
    ) board_update_pipeline (
        .clk(clk),
        .board_op(board_update_op),
        .board_in(board_update_in),
        .zobrist_key_in(board_update_zobrist_in),
        .pst_eval_in(board_update_pst_in),
        .piece_count_in(board_update_piece_count_in),
        .move_in(board_update_move),
        .set_data(board_update_set_data),
        .thread_id(board_update_thread_id),
        .search_ply(board_update_ply),
        .board_out(board_update_out),
        .zobrist_key_out(board_update_zobrist_out),
        .pst_eval_out(board_update_pst_out),
        .piece_count_out(board_update_piece_count_out),
        .mover_in_check_out(board_update_mover_in_check),
        .side_in_check_out(board_update_side_in_check)
    );

    repetition_checker #(
        .SEARCH_THREAD_COUNT(SEARCH_THREAD_COUNT), .SEARCH_STACK_DEPTH(SEARCH_STACK_DEPTH),
        .ACTIVE_HISTORY_DEPTH(ACTIVE_REPETITION_DEPTH), .EPOCH_BITS(REPETITION_EPOCH_BITS)
    ) repetition_checker_inst (
        .clk(clk), .rst_n(rst_n), .flush(state == CTRL_FLUSH_RESPOND),
        .active_history_reset(repetition_history_reset), .active_history_write(repetition_history_write),
        .active_history_key(repetition_history_key), .init_start(repetition_init_start),
        .init_busy(), .init_done(repetition_init_done), .init_failed(repetition_init_failed),
        .line_write_valid(repetition_line_write_valid), .line_write_thread(repetition_line_write_thread),
        .line_write_ply(repetition_line_write_ply), .line_write_key(repetition_line_write_key),
        .req_valid(repetition_req_valid), .req_thread(repetition_req_thread), .req_ply(repetition_req_ply),
        .req_start_ply(repetition_req_start_ply), .req_epoch(repetition_epoch), .req_key(repetition_req_key),
        .resp_valid(repetition_resp_valid), .resp_thread(repetition_resp_thread),
        .resp_epoch(repetition_resp_epoch),
        .resp_previous_count(repetition_resp_count),
        .resp_is_draw(repetition_resp_is_draw)
    );

    move_generator #(
        .THREAD_COUNT(SEARCH_THREAD_COUNT),
        .SEARCH_STACK_DEPTH(SEARCH_STACK_DEPTH),
        .MOVE_MEMORY_ENTRIES(MOVE_MEMORY_ENTRIES),
        .MOVE_BUCKET_0_RATIO(MOVE_BUCKET_0_RATIO),
        .MOVE_BUCKET_1_RATIO(MOVE_BUCKET_1_RATIO),
        .MOVE_BUCKET_2_RATIO(MOVE_BUCKET_2_RATIO),
        .MOVE_BUCKET_3_RATIO(MOVE_BUCKET_3_RATIO),
        .MOVE_BUCKET_4_RATIO(MOVE_BUCKET_4_RATIO),
        .MOVE_BUCKET_5_RATIO(MOVE_BUCKET_5_RATIO),
        .MOVE_BUCKET_6_RATIO(MOVE_BUCKET_6_RATIO),
        .MOVE_BUCKET_7_RATIO(MOVE_BUCKET_7_RATIO),
        .HISTORY_ENTRY_COUNT(HISTORY_ENTRY_COUNT),
        .HISTORY_ENTRY_BITS(HISTORY_ENTRY_BITS),
        .HISTORY_DEFAULT_SCORE(HISTORY_DEFAULT_SCORE),
        .HISTORY_REWARD_PER_DEPTH(HISTORY_REWARD_PER_DEPTH),
        .HISTORY_MAXIMUM_REWARD(HISTORY_MAXIMUM_REWARD),
        .HISTORY_MALUS_DIVISOR(HISTORY_MALUS_DIVISOR),
        .QUIET_THRESHOLD_1(QUIET_THRESHOLD_1),
        .QUIET_THRESHOLD_2(QUIET_THRESHOLD_2),
        .QUIET_THRESHOLD_3(QUIET_THRESHOLD_3),
        .CASTLING_HISTORY_BONUS(CASTLING_HISTORY_BONUS),
        .ENABLE_STATS(ENABLE_SEARCH_STATS)
    ) move_generator (
        .clk(clk),
        .rst_n(rst_n),
        .clear(state == CTRL_NEW_CLEAR_START),
        .flush((req_valid && req.operation == ENGINE_CTRL_KILL && state != CTRL_IDLE)
            || state == CTRL_NEW_CLEAR_START || state == CTRL_FLUSH_RESPOND),
        .init_busy(move_init_busy),
        .noisy_cmd_valid(move_cmd_valid), .noisy_cmd_ready(move_cmd_ready),
        .noisy_cmd(move_cmd),
        .noisy_cmd_thread(move_cmd_thread), .noisy_cmd_ply(move_cmd_ply),
        .noisy_cmd_board(move_cmd_board),
        .noisy_cmd_suppress_valid(move_cmd_suppress_valid),
        .noisy_cmd_suppress_move(move_cmd_suppress_move),
        .noisy_resp_valid(move_cmd_resp_valid), .noisy_resp_thread(move_cmd_resp_thread),
        .noisy_resp_ply(move_cmd_resp_ply),
        .noisy_resp_direct_valid(move_cmd_resp_direct_valid),
        .noisy_resp_direct_move(move_cmd_resp_direct_move),
        .quiet_cmd_valid(move_quiet_cmd_valid), .quiet_cmd_ready(move_quiet_cmd_ready),
        .quiet_cmd_thread(move_quiet_cmd_thread), .quiet_cmd_ply(move_quiet_cmd_ply),
        .quiet_cmd_board(move_quiet_cmd_board),
        .quiet_cmd_suppress_valid(move_quiet_cmd_suppress_valid),
        .quiet_cmd_suppress_move(move_quiet_cmd_suppress_move),
        .quiet_resp_valid(move_quiet_resp_valid),
        .quiet_resp_thread(move_quiet_resp_thread), .quiet_resp_ply(move_quiet_resp_ply),
        .pop_valid(move_pop_valid_vec), .pop_ready(move_pop_ready_vec),
        .pop_ply(move_pop_ply_vec),
        .node_init_valid(move_node_init_valid), .node_init_ready(move_node_init_ready),
        .node_init_ply(move_node_init_ply),
        .bad_noisy_enable(move_bad_noisy_enable),
        .pop_resp_valid(move_pop_resp_valid_vec), .pop_resp_ready(move_pop_resp_ready_vec),
        .pop_resp_ply(move_pop_resp_ply_vec), .pop_resp_found(move_pop_resp_found_vec),
        .pop_resp_move(move_pop_resp_move_vec), .pop_resp_bucket(move_pop_resp_bucket_vec),
        .history_update_valid(move_history_update_valid), .history_update_ready(move_history_update_ready),
        .history_update_thread(move_history_update_thread),
        .history_update_color(move_history_update_color), .history_update_from(move_history_update_from),
        .history_update_to(move_history_update_to), .history_update_depth(move_history_update_depth),
        .history_update_failed0(move_history_update_failed0),
        .history_update_failed1(move_history_update_failed1),
        .history_update_failed2(move_history_update_failed2),
        .history_update_failed_count(move_history_update_failed_count),
        .overflow_sticky(move_overflow_sticky),
        .stat_noisy_count(move_stat_noisy_count), .stat_quiet_count(move_stat_quiet_count),
        .stat_destination_count(move_stat_destination_count), .stat_candidate_count(move_stat_candidate_count),
        .stat_history_lookup_count(move_stat_history_lookup_count),
        .stat_generation_cycles(move_stat_generation_cycles),
        .stat_bucket_count(move_stat_bucket_count), .stat_bucket_high_water(move_stat_bucket_high_water)
    );

    tt_external_load_store #(
        .CACHE_INDEX_BITS(TT_CACHE_INDEX_BITS),
        .STORE_FIFO_DEPTH(TT_STORE_FIFO_DEPTH),
        .OUTSTANDING_DEPTH(TT_OUTSTANDING_DEPTH),
        .RESPONSE_FIFO_DEPTH(TT_RESPONSE_FIFO_DEPTH),
        .WRITEBACK_FIFO_DEPTH(TT_WRITEBACK_FIFO_DEPTH),
        .ENTRY_COUNT(TT_ENTRY_COUNT),
        .TAG_BITS(TT_TAG_BITS),
        .STALE_DEPTH_TOLERANCE(TT_STALE_DEPTH_TOLERANCE)
    ) tt_frontend (
        .clk(clk), .rst_n(rst_n), .memory_clk(tt_memory_clk), .memory_rst_n(tt_memory_rst_n), .memory_ready(tt_memory_ready), .memory_error(tt_memory_error),
        .clear(tt_clear), .clear_busy(tt_clear_busy),
        .store_bank_valid(tt_store_bank_valid), .store_bank(tt_store_bank),
        .lookup_req_valid(tt_lookup_req_valid), .lookup_req_ready(tt_lookup_req_ready),
        .lookup_req(tt_lookup_req), .lookup_resp_valid(tt_lookup_resp_valid), .lookup_resp(tt_lookup_resp),
        .cache_access(tt_cache_access), .cache_hit(tt_cache_hit),
        .cache_store_access(tt_cache_store_access), .cache_store_hit(tt_cache_store_hit),
        .store_req_valid(tt_store_req_valid), .store_req_ready(tt_store_req_ready), .store_req(tt_store_req),
        .mem_req_valid(tt_mem_req_valid), .mem_req_ready(tt_mem_req_ready),
        .mem_req_write(tt_mem_req_write),
        .mem_req_address(tt_mem_req_address),
        .mem_req_length(tt_mem_req_length),
        .mem_write_valid(tt_mem_write_valid), .mem_write_ready(tt_mem_write_ready),
        .mem_write_data(tt_mem_write_data), .mem_write_last(tt_mem_write_last),
        .mem_read_valid(tt_mem_read_valid), .mem_read_ready(tt_mem_read_ready),
        .mem_read_data(tt_mem_read_data), .mem_read_last(tt_mem_read_last),
        .mem_done_valid(tt_mem_done_valid),
        .mem_done_ready(tt_mem_done_ready),
        .mem_done_error(tt_mem_done_error)
    );

    logic [39:0] stat_tt_lookups;
    logic [39:0] stat_tt_hits;
    logic [39:0] stat_cache_lookups;
    logic [39:0] stat_cache_hits;
    logic [39:0] stat_phase_cycles[0:SEARCH_THREAD_COUNT-1][0:ENGINE_STAT_PHASE_COUNT_VALUE-1];
    logic [39:0] stat_search_cycle;

    generate
        if (ENABLE_SEARCH_STATS) begin : gen_search_stats
            always_ff @(posedge clk) begin
                if (!rst_n) begin
                    stat_tt_lookups <= 40'd0;
                    stat_tt_hits <= 40'd0;
                    stat_cache_lookups <= 40'd0;
                    stat_cache_hits <= 40'd0;
                    stat_search_cycle <= 40'd0;
                    for (int tid = 0; tid < SEARCH_THREAD_COUNT; tid++) begin
                        for (int phase = 0; phase < ENGINE_STAT_PHASE_COUNT_VALUE; phase++) begin
                            stat_phase_cycles[tid][phase] <= 40'd0;
                        end
                    end
                end else if (state == CTRL_IDLE && req_valid
                        && (req.operation == ENGINE_CTRL_SEARCH_DEPTH
                            || req.operation == ENGINE_CTRL_SEARCH_FIXED_TIME
                            || req.operation == ENGINE_CTRL_SEARCH_ON_CLOCK
                            || req.operation == ENGINE_CTRL_SEARCH_NODES)) begin
                    stat_tt_lookups <= 40'd0;
                    stat_tt_hits <= 40'd0;
                    stat_cache_lookups <= 40'd0;
                    stat_cache_hits <= 40'd0;
                    stat_search_cycle <= 40'd0;
                    for (int tid = 0; tid < SEARCH_THREAD_COUNT; tid++) begin
                        for (int phase = 0; phase < ENGINE_STAT_PHASE_COUNT_VALUE; phase++) begin
                            stat_phase_cycles[tid][phase] <= 40'd0;
                        end
                    end
                end else begin
                    if (tt_lookup_resp_valid
                            && search_tt_lookup_inflight[tt_lookup_resp.thread_id]
                            && search_thread_phase[tt_lookup_resp.thread_id] == SEARCH_PHASE_TT_WAIT) begin
                        stat_tt_lookups <= stat_tt_lookups + 40'd1;
                        if (tt_lookup_resp.hit) stat_tt_hits <= stat_tt_hits + 40'd1;
                    end
                    // Cache rate describes lookup probes; store probes are excluded.
                    if (tt_cache_access) begin
                        stat_cache_lookups <= stat_cache_lookups + 40'd1;
                        if (tt_cache_hit) stat_cache_hits <= stat_cache_hits + 40'd1;
                    end
                    if (state == CTRL_SEARCH_RUN) begin
                        stat_search_cycle <= stat_search_cycle + 40'd1;
                        for (int tid = 0; tid < SEARCH_THREAD_COUNT; tid++) begin
                            if (search_thread_phase[tid] >= SEARCH_PHASE_READY
                                    && search_thread_phase[tid] <= SEARCH_PHASE_DONE) begin
                                stat_phase_cycles[tid][search_thread_phase[tid] - SEARCH_PHASE_READY]
                                    <= stat_phase_cycles[tid][search_thread_phase[tid] - SEARCH_PHASE_READY] + 40'd1;
                            end else if (search_thread_phase[tid] >= SEARCH_PHASE_TIME_SCALE
                                    && search_thread_phase[tid] <= SEARCH_PHASE_TIME_CHECK) begin
                                stat_phase_cycles[tid][SEARCH_PHASE_DONE - SEARCH_PHASE_READY]
                                    <= stat_phase_cycles[tid][SEARCH_PHASE_DONE - SEARCH_PHASE_READY] + 40'd1;
                            end
                        end
                    end
                end
            end
        end else begin : gen_no_search_stats
            always_comb begin
                stat_tt_lookups = 40'd0;
                stat_tt_hits = 40'd0;
                stat_cache_lookups = 40'd0;
                stat_cache_hits = 40'd0;
                stat_search_cycle = 40'd0;
                for (int tid = 0; tid < SEARCH_THREAD_COUNT; tid++) begin
                    for (int phase = 0; phase < ENGINE_STAT_PHASE_COUNT_VALUE; phase++) begin
                        stat_phase_cycles[tid][phase] = 40'd0;
                    end
                end
            end
        end
    endgenerate

    // Debug reads are intentionally a slow combinational mux used only between searches.
    always_comb begin
        debug_stat_value = 40'd0;
        case (debug_stat_address)
            ENGINE_STAT_ENABLED:          debug_stat_value = {39'd0, ENABLE_SEARCH_STATS};
            ENGINE_STAT_THREAD_COUNT:     debug_stat_value = 40'(SEARCH_THREAD_COUNT);
            ENGINE_STAT_PHASE_COUNT:      debug_stat_value = 40'(ENGINE_STAT_PHASE_COUNT_VALUE);
            ENGINE_STAT_TT_LOOKUPS:       debug_stat_value = stat_tt_lookups;
            ENGINE_STAT_TT_HITS:          debug_stat_value = stat_tt_hits;
            ENGINE_STAT_TT_CACHE_LOOKUPS: debug_stat_value = stat_cache_lookups;
            ENGINE_STAT_TT_CACHE_HITS:    debug_stat_value = stat_cache_hits;
            ENGINE_STAT_MOVE_NOISY:       debug_stat_value = move_stat_noisy_count;
            ENGINE_STAT_MOVE_QUIET:       debug_stat_value = move_stat_quiet_count;
            ENGINE_STAT_MOVE_DESTINATIONS: debug_stat_value = move_stat_destination_count;
            ENGINE_STAT_MOVE_CANDIDATES:  debug_stat_value = move_stat_candidate_count;
            ENGINE_STAT_HISTORY_LOOKUPS:  debug_stat_value = move_stat_history_lookup_count;
            ENGINE_STAT_MOVE_GEN_CYCLES:  debug_stat_value = move_stat_generation_cycles;
            ENGINE_STAT_MOVE_OVERFLOW:   debug_stat_value = 40'(move_overflow_sticky);
            ENGINE_STAT_ACTIVE_PST_FIRST: debug_stat_value = {24'd0, active_pst_eval.first};
            ENGINE_STAT_ACTIVE_PST_ENDGAME: debug_stat_value = {24'd0, active_pst_eval.endgame};
            default: begin
                for (int tid = 0; tid < SEARCH_THREAD_COUNT; tid++) begin
                    for (int phase = 0; phase < ENGINE_STAT_PHASE_COUNT_VALUE; phase++) begin
                        if (debug_stat_address == ENGINE_STAT_PHASE_BASE
                                + 8'(tid * ENGINE_STAT_PHASE_COUNT_VALUE + phase)) begin
                            debug_stat_value = stat_phase_cycles[tid][phase];
                        end
                    end
                end
                for (int bucket = 0; bucket < MOVE_BUCKET_COUNT; bucket++) begin
                    if (debug_stat_address == ENGINE_STAT_BUCKET_COUNT_BASE + 8'(bucket))
                        debug_stat_value = move_stat_bucket_count[bucket];
                    if (debug_stat_address == ENGINE_STAT_BUCKET_HIGH_BASE + 8'(bucket))
                        debug_stat_value = 40'(move_stat_bucket_high_water[bucket]);
                end
            end
        endcase
    end

    time_management #(
        .CLOCK_FREQ(CLOCK_FREQ),
        .MOVES_TO_GO_BUFFER(MOVES_TO_GO_BUFFER),
        .DEFAULT_MOVES_DIVISOR(DEFAULT_MOVES_DIVISOR),
        .INCREMENT_NUMERATOR(INCREMENT_NUMERATOR),
        .INCREMENT_DENOMINATOR(INCREMENT_DENOMINATOR),
        .HARD_BASE_MULTIPLIER(HARD_BASE_MULTIPLIER),
        .HARD_TIME_NUMERATOR(HARD_TIME_NUMERATOR),
        .HARD_TIME_DENOMINATOR(HARD_TIME_DENOMINATOR),
        .SOFT_FACTOR_DEFAULT(SOFT_FACTOR_DEFAULT),
        .NEXT_DEPTH_NUMERATOR(NEXT_DEPTH_NUMERATOR),
        .NEXT_DEPTH_DENOMINATOR(NEXT_DEPTH_DENOMINATOR),
        .SINGLE_LEGAL_MOVE_MS(SINGLE_LEGAL_MOVE_MS)
    ) search_time_management (
        .clk(clk),
        .rst_n(rst_n),
        .cancel(time_management_cancel),
        .timer_reset(timer_rst),
        .timer_run(timer_run),
        .elapsed_ms(elapsed_ms),
        .setup_start(time_setup_start),
        .setup_fixed_time(active_req.operation == ENGINE_CTRL_SEARCH_FIXED_TIME),
        .setup_clock_time(active_req.operation == ENGINE_CTRL_SEARCH_ON_CLOCK),
        .time_limit(active_req.time_limit),
        .move_overhead(active_req.move_overhead),
        .remaining_time(active_req.remaining_time),
        .clock_increment(active_req.increment),
        .moves_to_go(active_req.moves_to_go),
        .adaptive_start(time_adaptive_start),
        .adaptive_base_ms(search_base_ms),
        .adaptive_hard_ms(search_hard_ms),
        .adaptive_factor(pending_soft_factor),
        .adaptive_single_legal_move(pending_single_legal_move),
        .busy(),
        .done(time_management_done),
        .base_ms(allocated_base_ms),
        .soft_ms(allocated_soft_ms),
        .next_depth_ms(allocated_next_depth_ms),
        .hard_ms(allocated_hard_ms)
    );

    nnue_evaluator #(
        .STATE_THREAD_COUNT(SEARCH_THREAD_COUNT)
    ) nnue_evaluator (
        .clk(clk),
        .rst_n(rst_n),
        .clear(nnue_clear),
        .update_valid(nnue_update_valid),
        .update_ready(nnue_update_ready),
        .update_idle(nnue_update_idle),
        .update_req(nnue_update_req),
        .update_done_valid(nnue_update_done_valid),
        .update_done_thread(nnue_update_done_thread),
        .update_done_ply(nnue_update_done_ply),
        .eval_valid(nnue_eval_valid),
        .eval_ready(nnue_eval_ready),
        .eval_thread_id(nnue_build_thread),
        .eval_turn(search_board[nnue_build_thread].turn),
        .eval_piece_count(search_piece_count[nnue_build_thread]),
        .eval_pst(search_pst_eval[nnue_build_thread]),
        .result_valid(nnue_result_valid),
        .result(nnue_result),
        .result_pst(nnue_result_pst)
    );

    // Accumulator contents need not be erased because validity is tracked per
    // state, but queued and in-flight work must not cross lifecycle boundaries.
    assign nnue_clear = state == CTRL_NEW_CLEAR_START || state == CTRL_FLUSH_RESPOND
        || (state == CTRL_SEARCH_ITER_START && !nnue_roots_initialized);
