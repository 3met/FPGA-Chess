`timescale 1ns/1ps

import chess_defs::*;
import board_update_pipeline_defs::*;
import engine_defs::*;
import move_generator_defs::*;
import tt_defs::*;

// Engine-only runtime profiler. This is measurement infrastructure, not a
// chess-correctness testbench.
module tb_engine_profile #(
    parameter int ENGINE_CLOCK_FREQ = 75_000_000,
    parameter int ENGINE_HALF_PERIOD_PS = 6667,
    parameter int SEARCH_THREAD_COUNT = 1,
    parameter int SEARCH_STACK_DEPTH = 24,
    parameter int TT_TAG_BITS = TT_DEFAULT_TAG_BITS,
    parameter int TT_CACHE_INDEX_BITS = 10,
    parameter bit ENABLE_SEARCH_STATS = 1'b0,
    parameter int ASPIRATION_STARTING_DELTA = 15,
    parameter int unsigned ASPIRATION_DELTA_MULTIPLIER_Q3 = 12,
    parameter int unsigned LMR_A_Q8 = 192,
    parameter int unsigned LMR_B_Q8 = 614,
    parameter int LMR_MINIMUM_DEPTH = 3,
    parameter int LMR_MINIMUM_MOVE_NUMBER = 3,
    parameter int NULL_MINIMUM_DEPTH = 3,
    parameter int NULL_DEEP_DEPTH_THRESHOLD = 7,
    parameter int NULL_SHALLOW_REDUCTION = 2,
    parameter int NULL_DEEP_REDUCTION = 3,
    parameter int RFP_BASE_MARGIN = 64,
    parameter int RFP_MARGIN_PER_DEPTH = 128,
    parameter int RFP_MAXIMUM_DEPTH = 5,
    parameter int QDELTA_MARGIN = 384,
    parameter int MOVE_OVERHEAD_MS = 5,
    parameter int MINIMUM_SEARCH_MS = 5,
    parameter int INCREMENT_NUMERATOR = 3,
    parameter int INCREMENT_DENOMINATOR = 4,
    parameter int REMAINING_TIME_NUMERATOR = 1,
    parameter int REMAINING_TIME_DENOMINATOR = 32,
    parameter int HISTORY_REWARD_PER_DEPTH = 4,
    parameter int HISTORY_MAXIMUM_REWARD = 63,
    parameter int HISTORY_MALUS_DIVISOR = 2,
    parameter int QUIET_THRESHOLD_1 = 16,
    parameter int QUIET_THRESHOLD_2 = 64,
    parameter int QUIET_THRESHOLD_3 = 128,
    parameter int CASTLING_HISTORY_BONUS = 16,
    parameter int TT_VALIDATE_MINIMUM_DEPTH = 8,
    parameter int TT_VALIDATE_BYPASS_HALFMOVES = 4,
    parameter int TT_STALE_DEPTH_TOLERANCE = 4
);
    localparam int TT_COMPACT_BITS = TT_TAG_BITS + TT_ENTRY_PAYLOAD_BITS;
    localparam int TT_ENTRY_WORDS = (TT_COMPACT_BITS + TT_WORD_BITS - 1) / TT_WORD_BITS;
    localparam int TT_ENTRY_COUNT = TT_EXTERNAL_WORD_COUNT / TT_ENTRY_WORDS;
    localparam int MEMORY_HALF_PERIOD_NS = 5;
    localparam realtime MEMORY_PIN_LEAD_NS = 2.5;
    // The DE1 pin clock leads the controller by 2.5 ns. Sampling 5 ns after the
    // controller edge places reads 7.5 ns into the SDRAM's 10 ns data cycle.
    localparam int MEMORY_READ_LAG_NS = 5;
    localparam int ENGINE_STATE_COUNT = 8;
    localparam int CONTROLLER_STATE_COUNT = 22;
    localparam int THREAD_PHASE_COUNT = 11;
    // Profiler-local copies of the stable state encodings avoid hierarchical
    // enum-item references, which trigger a Verilator width-analysis bug.
    localparam int CONTROLLER_STATE_SEARCH_ROOT_INIT = 18;
    localparam int CONTROLLER_STATE_SEARCH_RUN = 19;
    localparam int THREAD_PHASE_IDLE = 0;
    localparam int THREAD_PHASE_READY = 1;
    localparam int THREAD_PHASE_EVAL_WAIT = 3;
    localparam int THREAD_PHASE_MOVE_WAIT = 4;
    localparam int THREAD_PHASE_REPETITION_WAIT = 7;
    localparam int THREAD_PHASE_STORE_PUBLISH = 8;
    localparam int THREAD_PHASE_DONE = 10;
    localparam int MOVE_ORDER_STATE_COUNT = 7;
    localparam int ORDINAL_BUCKET_COUNT = 8;
    localparam int GENERATOR_STATE_COUNT = 8;
    localparam int MOVE_OPERATION_COUNT = 4;
    localparam int MOVE_OPERATION_BUCKET_POP = 3;
    localparam int SEARCH_BOARD_TAG_PIPE_LEN = (BOARD_UPDATE_PIPELINE_STAGE_CNT <= 1)
        ? 1 : BOARD_UPDATE_PIPELINE_STAGE_CNT;
    localparam int TT_STATE_COUNT = 12;
    localparam int TT_STATE_IDLE = 0;
    localparam int SDRAM_STATE_COUNT = 37;

    logic engine_clk = 1'b0;
    logic memory_clk = 1'b0;
    logic memory_pin_clk = 1'b0;
    logic memory_read_clk = 1'b0;
    logic system_rst_n = 1'b0;
    logic engine_rst_n;
    always #(ENGINE_HALF_PERIOD_PS * 1ps) engine_clk = ~engine_clk;
    always #(MEMORY_HALF_PERIOD_NS) memory_clk = ~memory_clk;
    initial begin
        #(MEMORY_HALF_PERIOD_NS - MEMORY_PIN_LEAD_NS);
        forever #(MEMORY_HALF_PERIOD_NS) memory_pin_clk = ~memory_pin_clk;
    end
    initial begin
        #(MEMORY_HALF_PERIOD_NS + MEMORY_READ_LAG_NS);
        forever #(MEMORY_HALF_PERIOD_NS) memory_read_clk = ~memory_read_clk;
    end

    logic [7:0] data_in;
    logic data_in_valid;
    logic ready_for_result;
    logic error_flag;
    logic ready;
    logic [7:0] data_out;
    logic data_out_valid;
    logic tt_memory_ready;
    logic tt_memory_error;
    logic tt_mem_req_valid, tt_mem_req_ready, tt_mem_req_write;
    TTWordAddress tt_mem_req_address;
    logic [3:0] tt_mem_req_length;
    logic tt_mem_write_valid, tt_mem_write_ready, tt_mem_write_last;
    logic [15:0] tt_mem_write_data;
    logic tt_mem_read_valid, tt_mem_read_ready, tt_mem_read_last;
    logic [15:0] tt_mem_read_data;
    logic tt_mem_done_valid, tt_mem_done_ready, tt_mem_done_error;

    logic backend_req_valid, backend_req_ready, backend_req_write;
    TTWordAddress backend_req_address;
    logic [3:0] backend_req_length;
    logic backend_write_valid, backend_write_ready, backend_write_last;
    logic [15:0] backend_write_data;
    logic backend_read_valid, backend_read_ready, backend_read_last;
    logic [15:0] backend_read_data;
    logic backend_done_valid, backend_done_ready, backend_done_error;
    logic backend_memory_ready, backend_memory_error;

    logic [12:0] dram_addr;
    logic [1:0] dram_ba;
    logic dram_cas_n, dram_cke, dram_cs_n;
    wire [15:0] dram_dq;
    logic dram_ldqm, dram_ras_n, dram_udqm, dram_we_n;

    assign engine_rst_n = system_rst_n && tt_memory_ready && !tt_memory_error;

    engine #(
        .CLOCK_FREQ(ENGINE_CLOCK_FREQ),
        .SEARCH_THREAD_COUNT(SEARCH_THREAD_COUNT),
        .SEARCH_STACK_DEPTH(SEARCH_STACK_DEPTH),
        .TT_TAG_BITS(TT_TAG_BITS),
        .TT_CACHE_INDEX_BITS(TT_CACHE_INDEX_BITS),
        .ASPIRATION_STARTING_DELTA(ASPIRATION_STARTING_DELTA),
        .ASPIRATION_DELTA_MULTIPLIER_Q3(ASPIRATION_DELTA_MULTIPLIER_Q3),
        .LMR_A_Q8(LMR_A_Q8), .LMR_B_Q8(LMR_B_Q8),
        .LMR_MINIMUM_DEPTH(LMR_MINIMUM_DEPTH),
        .LMR_MINIMUM_MOVE_NUMBER(LMR_MINIMUM_MOVE_NUMBER),
        .NULL_MINIMUM_DEPTH(NULL_MINIMUM_DEPTH),
        .NULL_DEEP_DEPTH_THRESHOLD(NULL_DEEP_DEPTH_THRESHOLD),
        .NULL_SHALLOW_REDUCTION(NULL_SHALLOW_REDUCTION),
        .NULL_DEEP_REDUCTION(NULL_DEEP_REDUCTION),
        .RFP_BASE_MARGIN(RFP_BASE_MARGIN),
        .RFP_MARGIN_PER_DEPTH(RFP_MARGIN_PER_DEPTH),
        .RFP_MAXIMUM_DEPTH(RFP_MAXIMUM_DEPTH),
        .QDELTA_MARGIN(QDELTA_MARGIN),
        .MOVE_OVERHEAD_MS(MOVE_OVERHEAD_MS), .MINIMUM_SEARCH_MS(MINIMUM_SEARCH_MS),
        .INCREMENT_NUMERATOR(INCREMENT_NUMERATOR), .INCREMENT_DENOMINATOR(INCREMENT_DENOMINATOR),
        .REMAINING_TIME_NUMERATOR(REMAINING_TIME_NUMERATOR),
        .REMAINING_TIME_DENOMINATOR(REMAINING_TIME_DENOMINATOR),
        .HISTORY_REWARD_PER_DEPTH(HISTORY_REWARD_PER_DEPTH),
        .HISTORY_MAXIMUM_REWARD(HISTORY_MAXIMUM_REWARD),
        .HISTORY_MALUS_DIVISOR(HISTORY_MALUS_DIVISOR),
        .QUIET_THRESHOLD_1(QUIET_THRESHOLD_1), .QUIET_THRESHOLD_2(QUIET_THRESHOLD_2),
        .QUIET_THRESHOLD_3(QUIET_THRESHOLD_3),
        .CASTLING_HISTORY_BONUS(CASTLING_HISTORY_BONUS),
        .TT_VALIDATE_MINIMUM_DEPTH(TT_VALIDATE_MINIMUM_DEPTH),
        .TT_VALIDATE_BYPASS_HALFMOVES(TT_VALIDATE_BYPASS_HALFMOVES),
        .TT_STALE_DEPTH_TOLERANCE(TT_STALE_DEPTH_TOLERANCE),
        .EXTERNAL_TT(1'b1),
        .ENABLE_SEARCH_STATS(ENABLE_SEARCH_STATS)
    ) dut (
        .clk(engine_clk), .rst_n(engine_rst_n),
        .data_in, .data_in_valid, .ready_for_result,
        .error_flag, .ready, .data_out, .data_out_valid,
        .tt_memory_ready, .tt_memory_error,
        .tt_mem_req_valid, .tt_mem_req_ready, .tt_mem_req_write,
        .tt_mem_req_address, .tt_mem_req_length,
        .tt_mem_write_valid, .tt_mem_write_ready, .tt_mem_write_data, .tt_mem_write_last,
        .tt_mem_read_valid, .tt_mem_read_ready, .tt_mem_read_data, .tt_mem_read_last,
        .tt_mem_done_valid, .tt_mem_done_ready, .tt_mem_done_error
    );

    tt_memory_cdc_bridge memory_bridge (
        .req_clk(engine_clk), .req_rst_n(system_rst_n),
        .mem_clk(memory_clk), .mem_rst_n(system_rst_n),
        .backend_ready(backend_memory_ready), .backend_error(backend_memory_error),
        .req_memory_ready(tt_memory_ready), .req_memory_error(tt_memory_error),
        .req_valid(tt_mem_req_valid), .req_ready(tt_mem_req_ready),
        .req_write(tt_mem_req_write), .req_address(tt_mem_req_address), .req_length(tt_mem_req_length),
        .write_valid(tt_mem_write_valid), .write_ready(tt_mem_write_ready),
        .write_data(tt_mem_write_data), .write_last(tt_mem_write_last),
        .read_valid(tt_mem_read_valid), .read_ready(tt_mem_read_ready),
        .read_data(tt_mem_read_data), .read_last(tt_mem_read_last),
        .done_valid(tt_mem_done_valid), .done_ready(tt_mem_done_ready), .done_error(tt_mem_done_error),
        .backend_req_valid, .backend_req_ready, .backend_req_write,
        .backend_req_address, .backend_req_length,
        .backend_write_valid, .backend_write_ready, .backend_write_data, .backend_write_last,
        .backend_read_valid, .backend_read_ready, .backend_read_data, .backend_read_last,
        .backend_done_valid, .backend_done_ready, .backend_done_error
    );

    sdr_sdram_controller #(
        .CLOCK_FREQ(100_000_000),
        .ENTRY_COUNT(TT_ENTRY_COUNT),
        .WORDS_PER_ENTRY(TT_ENTRY_WORDS),
        .CAS_LATENCY(2),
        .SKIP_INITIAL_CLEAR(1'b1)
    ) memory_controller (
        .clk(memory_clk), .read_capture_clk(memory_read_clk), .rst_n(system_rst_n),
        .ready(backend_memory_ready), .error(backend_memory_error),
        .req_valid(backend_req_valid), .req_ready(backend_req_ready),
        .req_write(backend_req_write), .req_address(backend_req_address), .req_length(backend_req_length),
        .write_valid(backend_write_valid), .write_ready(backend_write_ready),
        .write_data(backend_write_data), .write_last(backend_write_last),
        .read_valid(backend_read_valid), .read_ready(backend_read_ready),
        .read_data(backend_read_data), .read_last(backend_read_last),
        .done_valid(backend_done_valid), .done_ready(backend_done_ready), .done_error(backend_done_error),
        .dram_addr, .dram_ba, .dram_cas_n, .dram_cke, .dram_cs_n,
        .dram_dq, .dram_ldqm, .dram_ras_n, .dram_udqm, .dram_we_n
    );

    sdram_chip_model memory_chip (
        .clk(memory_pin_clk), .addr(dram_addr), .ba(dram_ba),
        .cas_n(dram_cas_n), .cke(dram_cke), .cs_n(dram_cs_n),
        .dq(dram_dq), .ldqm(dram_ldqm), .ras_n(dram_ras_n),
        .udqm(dram_udqm), .we_n(dram_we_n)
    );

    string board_file;
    string metrics_file;
    string events_file;
    string wave_file;
    logic [7:0] board_payload[0:35];
    integer metrics_fd;
    integer events_fd;
    integer search_kind;
    longint unsigned search_limit;
    logic profile_active;
    logic drain_active;
    logic result_seen;
    EngineControllerResponse search_result;

    longint unsigned setup_cycles;
    longint unsigned search_cycles;
    longint unsigned output_cycles;
    longint unsigned drain_cycles;
    longint unsigned engine_state_cycles[0:ENGINE_STATE_COUNT-1];
    longint unsigned controller_state_cycles[0:CONTROLLER_STATE_COUNT-1];
    longint unsigned thread_phase_cycles[0:SEARCH_THREAD_COUNT-1][0:THREAD_PHASE_COUNT-1];
    longint unsigned thread_ready_nnue_init[0:SEARCH_THREAD_COUNT-1];
    longint unsigned thread_ready_dispatch[0:SEARCH_THREAD_COUNT-1];
    longint unsigned thread_ready_arbitration[0:SEARCH_THREAD_COUNT-1];
    longint unsigned thread_ready_tt_blocked[0:SEARCH_THREAD_COUNT-1];
    longint unsigned thread_ready_noisy_move_blocked[0:SEARCH_THREAD_COUNT-1];
    longint unsigned thread_ready_quiet_move_blocked[0:SEARCH_THREAD_COUNT-1];
    longint unsigned thread_ready_transition[0:SEARCH_THREAD_COUNT-1];
    longint unsigned thread_noisy_move_wait[0:SEARCH_THREAD_COUNT-1];
    longint unsigned thread_quiet_move_wait[0:SEARCH_THREAD_COUNT-1];
    longint unsigned thread_repetition_nnue_wait[0:SEARCH_THREAD_COUNT-1];
    longint unsigned thread_repetition_overlap_wait[0:SEARCH_THREAD_COUNT-1];
    longint unsigned thread_repetition_checker_wait[0:SEARCH_THREAD_COUNT-1];
    longint unsigned thread_move_order_cycles[0:SEARCH_THREAD_COUNT-1][0:MOVE_ORDER_STATE_COUNT-1];
    longint unsigned thread_ply_cycles[0:SEARCH_THREAD_COUNT-1][0:MAX_PLY_COUNT-1];
    longint unsigned active_thread_histogram[0:SEARCH_THREAD_COUNT];
    longint unsigned inflight_histogram[0:5];
    longint unsigned generator_state_cycles[0:GENERATOR_STATE_COUNT-1];
    longint unsigned tt_state_cycles[0:TT_STATE_COUNT-1];
    longint unsigned sdram_state_cycles[0:SDRAM_STATE_COUNT-1];
    longint unsigned bucket_writes[0:MOVE_BUCKET_COUNT-1];
    longint unsigned bucket_pops[0:MOVE_BUCKET_COUNT-1];
    longint unsigned bucket_cutoffs[0:MOVE_BUCKET_COUNT-1];
    longint unsigned bucket_high_water[0:MOVE_BUCKET_COUNT-1];
    longint unsigned legal_ordinal_histogram[0:ORDINAL_BUCKET_COUNT-1];
    longint unsigned cutoff_ordinal_histogram[0:ORDINAL_BUCKET_COUNT-1];
    longint unsigned direct_move_cutoffs;
    longint unsigned board_issues, board_reverses, board_completions;
    longint unsigned legal_candidates, illegal_candidates;
    longint unsigned board_stall_cycles, move_stall_cycles, tt_request_stall_cycles;
    longint unsigned move_commands, move_pops, move_pop_misses;
    longint unsigned move_operation_count[0:MOVE_OPERATION_COUNT-1];
    longint unsigned move_operation_cycles[0:MOVE_OPERATION_COUNT-1];
    longint unsigned move_operation_max_cycles[0:MOVE_OPERATION_COUNT-1];
    longint unsigned move_operation_aborted[0:MOVE_OPERATION_COUNT-1];
    longint unsigned move_command_start_cycle[0:SEARCH_THREAD_COUNT-1], move_pop_start_cycle;
    logic move_command_active[0:SEARCH_THREAD_COUNT-1];
    logic move_pop_active;
    logic [1:0] move_command_operation[0:SEARCH_THREAD_COUNT-1];
    longint unsigned noisy_destinations_examined, quiet_destinations_examined;
    longint unsigned noisy_destinations_with_sources, quiet_destinations_with_sources;
    longint unsigned noisy_candidates_emitted, quiet_candidates_emitted;
    longint unsigned candidates_analyzed, history_lookups, move_generation_cycles;
    longint unsigned evaluations, eval_completions;
    longint unsigned nnue_update_requests, nnue_root_rows, nnue_rebuild_rows;
    longint unsigned nnue_rebuilds, nnue_delta_requests;
    longint unsigned nnue_completion_markers;
    longint unsigned nnue_recovery_rows, nnue_update_completions;
    longint unsigned nnue_update_busy_cycles;
    longint unsigned nnue_update_backpressure_cycles;
    longint unsigned repetition_requests, repetition_responses;
    longint unsigned tt_lookups, tt_hits, tt_stores;
    longint unsigned tt_bound_hits[0:2];
    longint unsigned tt_cutoff_hits, tt_ordering_hits;
    longint unsigned tt_cache_lookup_probes, tt_cache_lookup_hits;
    longint unsigned tt_cache_store_probes, tt_cache_store_hits;
    longint unsigned tt_store_drops;
    longint unsigned tt_store_fifo_high_water;
    longint unsigned tt_cache_bypass_hits;
    longint unsigned tt_store_write_preemptions;
    longint unsigned pvs_scouts, pvs_researches, lmr_reduced_issues, rfp_cutoffs;
    longint unsigned qdelta_pruned_moves;
    longint unsigned terminal_checkmates, terminal_stalemates;
    longint unsigned terminal_main_exhausted, terminal_qsearch_exhausted;
    longint unsigned repetition_draws, fifty_move_draws;
    longint unsigned qsearch_board_issues, main_search_board_issues;
    longint unsigned sdram_reads, sdram_writes, sdram_read_words, sdram_write_words;
    longint unsigned sdram_row_hits, sdram_row_misses, sdram_row_conflicts;
    longint unsigned cdc_command_stalls, cdc_write_stalls, cdc_read_stalls, cdc_done_stalls;
    longint unsigned previous_nodes;
    longint unsigned depth_cycles[0:MAX_PLY_COUNT-1];
    longint unsigned depth_nodes[0:MAX_PLY_COUNT-1];
    longint unsigned depth_tt_lookups[0:MAX_PLY_COUNT-1];
    longint unsigned depth_tt_hits[0:MAX_PLY_COUNT-1];
    longint unsigned depth_cache_probes[0:MAX_PLY_COUNT-1];
    longint unsigned depth_cache_hits[0:MAX_PLY_COUNT-1];
    PlyIndex depth_max_ply[0:MAX_PLY_COUNT-1];
    PlyIndex deepest_search_ply;
    logic selected_bucket_valid[0:SEARCH_THREAD_COUNT-1][0:MAX_PLY_COUNT-1];
    Move selected_bucket_move[0:SEARCH_THREAD_COUNT-1][0:MAX_PLY_COUNT-1];
    MoveBucketIndex selected_bucket[0:SEARCH_THREAD_COUNT-1][0:MAX_PLY_COUNT-1];

    task automatic send_byte(input logic [7:0] value);
        while (!ready) @(posedge engine_clk);
        @(negedge engine_clk);
        data_in = value;
        data_in_valid = 1'b1;
        @(negedge engine_clk);
        data_in_valid = 1'b0;
        data_in = 8'h00;
    endtask

    task automatic consume_response(input int byte_count);
        automatic int received = 0;
        while (received < byte_count) begin
            @(posedge engine_clk);
            if (data_out_valid) received++;
        end
    endtask

    task automatic emit(input string key, input longint unsigned value);
        $fdisplay(metrics_fd, "METRIC\t%s\t%0d", key, value);
    endtask

    task automatic emit_result(input string key, input longint signed value);
        $fdisplay(metrics_fd, "RESULT\t%s\t%0d", key, value);
    endtask

    function automatic int ordinal_bucket(input int ordinal);
        if (ordinal <= 1) return 0;
        if (ordinal == 2) return 1;
        if (ordinal == 3) return 2;
        if (ordinal == 4) return 3;
        if (ordinal <= 8) return 4;
        if (ordinal <= 16) return 5;
        if (ordinal <= 32) return 6;
        return 7;
    endfunction

    // Finish one measured generator operation. Timed searches may stop with
    // one operation in flight, in which case its observed partial latency is
    // retained and marked as aborted rather than discarded.
    task automatic record_move_operation(
        input int operation,
        input longint unsigned operation_cycles,
        input logic aborted
    );
        move_operation_count[operation] =
            move_operation_count[operation] + 1;
        move_operation_cycles[operation] =
            move_operation_cycles[operation] + operation_cycles;
        if (operation_cycles > move_operation_max_cycles[operation])
            move_operation_max_cycles[operation] = operation_cycles;
        if (aborted)
            move_operation_aborted[operation] =
                move_operation_aborted[operation] + 1;
    endtask

    // Engine-domain profiling counters are active only between controller
    // request acceptance and controller response.
    always @(posedge engine_clk) begin
        if (engine_rst_n && dut.controller_req_valid && dut.controller_req_ready
                && (dut.controller_req.operation == ENGINE_CTRL_SEARCH_DEPTH
                    || dut.controller_req.operation == ENGINE_CTRL_SEARCH_FIXED_TIME
                    || dut.controller_req.operation == ENGINE_CTRL_SEARCH_NODES)) begin
            profile_active <= 1'b1;
            previous_nodes <= 0;
        end
        if (profile_active) begin
            int active_count;
            int inflight_count;
            int iteration_depth;
            logic any_ready_move_blocked;
            logic any_ready_tt_blocked;
            iteration_depth = int'(dut.controller.search_thread_target_depth[0]);
            // These counters are testbench-only observations. Blocking updates
            // avoid scheduling thousands of needless NBA events without changing
            // any DUT timing or sampled value.
            search_cycles = search_cycles + 1;
            depth_cycles[iteration_depth] = depth_cycles[iteration_depth] + 1;
            engine_state_cycles[int'(dut.command_layer.state)] =
                engine_state_cycles[int'(dut.command_layer.state)] + 1;
            controller_state_cycles[int'(dut.controller.state)] =
                controller_state_cycles[int'(dut.controller.state)] + 1;
            if (!dut.controller.nnue_update_idle)
                nnue_update_busy_cycles = nnue_update_busy_cycles + 1;
            if (dut.controller.nnue_update_valid && !dut.controller.nnue_update_ready)
                nnue_update_backpressure_cycles = nnue_update_backpressure_cycles + 1;
            generator_state_cycles[int'(dut.controller.move_generator.noisy_lane.state)] =
                generator_state_cycles[int'(dut.controller.move_generator.noisy_lane.state)] + 1;
            generator_state_cycles[int'(dut.controller.move_generator.quiet_lane.state)] =
                generator_state_cycles[int'(dut.controller.move_generator.quiet_lane.state)] + 1;
            tt_state_cycles[int'(dut.controller.external_tt_gen.tt_load_store.state)] =
                tt_state_cycles[int'(dut.controller.external_tt_gen.tt_load_store.state)] + 1;
            if (dut.controller.external_tt_gen.tt_load_store.store_fifo_count
                    > tt_store_fifo_high_water)
                tt_store_fifo_high_water =
                    dut.controller.external_tt_gen.tt_load_store.store_fifo_count;
            if (int'(dut.controller.external_tt_gen.tt_load_store.state)
                        == TT_STATE_IDLE
                    && dut.controller.external_tt_gen.tt_load_store.lookup_miss_valid
                    && dut.controller.external_tt_gen.tt_load_store.store_write_pending)
                tt_store_write_preemptions = tt_store_write_preemptions + 1;

            active_count = 0;
            inflight_count = 0;
            any_ready_move_blocked = 1'b0;
            any_ready_tt_blocked = 1'b0;
            for (int tid = 0; tid < SEARCH_THREAD_COUNT; tid++) begin
                thread_phase_cycles[tid][int'(dut.controller.search_thread_phase[tid])] =
                    thread_phase_cycles[tid][int'(dut.controller.search_thread_phase[tid])] + 1;
                // Attribute the shared move-wait phase to the ordering class
                // that issued the generation or bucket-pop operation.
                if (int'(dut.controller.search_thread_phase[tid]) == THREAD_PHASE_MOVE_WAIT) begin
                    automatic MoveOrderState wait_order_state =
                        dut.controller.search_stack_top[tid].move_order_state;
                    if (wait_order_state == MOVE_ORDER_GENERATE_QUIET
                            || wait_order_state == MOVE_ORDER_QUIET)
                        thread_quiet_move_wait[tid] = thread_quiet_move_wait[tid] + 1;
                    else
                        thread_noisy_move_wait[tid] = thread_noisy_move_wait[tid] + 1;
                end
                // The controller's repetition-wait phase begins while the NNUE
                // child state is prepared. Separate that work from an accepted,
                // genuinely in-flight repetition lookup.
                if (int'(dut.controller.search_thread_phase[tid])
                        == THREAD_PHASE_REPETITION_WAIT) begin
                    if (dut.controller.nnue_plan_pending[tid]
                            && dut.controller.search_repetition_pending[tid])
                        thread_repetition_overlap_wait[tid] =
                            thread_repetition_overlap_wait[tid] + 1;
                    else if (dut.controller.nnue_plan_pending[tid])
                        thread_repetition_nnue_wait[tid] =
                            thread_repetition_nnue_wait[tid] + 1;
                    else if (dut.controller.search_repetition_pending[tid])
                        thread_repetition_checker_wait[tid] =
                            thread_repetition_checker_wait[tid] + 1;
                end
                // Split the broad READY phase into exclusive causes without
                // adding profiler state to the synthesizable controller.
                if (int'(dut.controller.search_thread_phase[tid]) == THREAD_PHASE_READY) begin
                    automatic logic dispatched =
                        (dut.controller.search_tt_lookup_issue_valid
                            && dut.controller.tt_lookup_req_ready
                            && dut.controller.search_tt_lookup_issue_thread == ThreadID'(tid))
                        || (dut.controller.search_eval_issue_valid
                            && dut.controller.search_eval_issue_thread == ThreadID'(tid))
                        || (dut.controller.search_move_issue_valid
                            && ((dut.controller.move_cmd_valid && dut.controller.move_cmd_ready)
                                || (dut.controller.move_pop_valid && dut.controller.move_pop_ready))
                            && dut.controller.search_move_issue_thread == ThreadID'(tid))
                        || (dut.controller.search_quiet_issue_valid
                            && dut.controller.move_quiet_cmd_valid
                            && dut.controller.move_quiet_cmd_ready
                            && dut.controller.search_quiet_issue_thread == ThreadID'(tid))
                        || (dut.controller.search_null_issue_valid
                            && dut.controller.search_board_issue_thread == ThreadID'(tid));
                    automatic MoveOrderState order_state =
                        dut.controller.search_stack_top[tid].move_order_state;
                    if (int'(dut.controller.state) == CONTROLLER_STATE_SEARCH_ROOT_INIT) begin
                        thread_ready_nnue_init[tid] = thread_ready_nnue_init[tid] + 1;
                    end else if (int'(dut.controller.state) != CONTROLLER_STATE_SEARCH_RUN
                            || order_state == MOVE_ORDER_DONE
                            || dut.controller.search_board[tid].halfmove_clock >= HalfmoveClock'(100)) begin
                        thread_ready_transition[tid] = thread_ready_transition[tid] + 1;
                    end else if (dispatched) begin
                        thread_ready_dispatch[tid] = thread_ready_dispatch[tid] + 1;
                    end else if (dut.controller.search_tt_lookup_mask[tid]
                            && !dut.controller.tt_lookup_req_ready) begin
                        thread_ready_tt_blocked[tid] = thread_ready_tt_blocked[tid] + 1;
                        any_ready_tt_blocked = 1'b1;
                    end else if (dut.controller.search_tt_lookup_mask[tid]
                            || dut.controller.search_eval_mask[tid]
                            || dut.controller.search_null_mask[tid]) begin
                        thread_ready_arbitration[tid] = thread_ready_arbitration[tid] + 1;
                    end else if (order_state == MOVE_ORDER_GENERATE_QUIET
                            && !dut.controller.move_quiet_cmd_ready) begin
                        thread_ready_quiet_move_blocked[tid] =
                            thread_ready_quiet_move_blocked[tid] + 1;
                        any_ready_move_blocked = 1'b1;
                    end else if ((order_state == MOVE_ORDER_DIRECT
                                || order_state == MOVE_ORDER_GENERATE_NOISY)
                            && !dut.controller.move_cmd_ready) begin
                        thread_ready_noisy_move_blocked[tid] =
                            thread_ready_noisy_move_blocked[tid] + 1;
                        any_ready_move_blocked = 1'b1;
                    end else if (dut.controller.search_move_mask[tid]
                            || dut.controller.search_quiet_mask[tid]
                            ) begin
                        thread_ready_arbitration[tid] = thread_ready_arbitration[tid] + 1;
                    end else begin
                        thread_ready_transition[tid] = thread_ready_transition[tid] + 1;
                    end
                end
                if (int'(dut.controller.search_thread_phase[tid]) != THREAD_PHASE_IDLE
                        && int'(dut.controller.search_thread_phase[tid])
                            != THREAD_PHASE_DONE) begin
                    active_count++;
                    thread_move_order_cycles[tid][int'(dut.controller.search_stack_top[tid].move_order_state)] =
                        thread_move_order_cycles[tid][int'(dut.controller.search_stack_top[tid].move_order_state)] + 1;
                    thread_ply_cycles[tid][int'(dut.controller.search_ply[tid])] =
                        thread_ply_cycles[tid][int'(dut.controller.search_ply[tid])] + 1;
                    if (dut.controller.search_ply[tid] > depth_max_ply[iteration_depth])
                        depth_max_ply[iteration_depth] = dut.controller.search_ply[tid];
                    if (dut.controller.search_ply[tid] > deepest_search_ply)
                        deepest_search_ply = dut.controller.search_ply[tid];
                end
                if (dut.controller.search_board_inflight[tid]) inflight_count++;
                if (dut.controller.search_move_inflight[tid]) inflight_count++;
                if (int'(dut.controller.search_thread_phase[tid])
                        == THREAD_PHASE_EVAL_WAIT) inflight_count++;
                if (dut.controller.search_tt_lookup_inflight[tid]) inflight_count++;
                if (int'(dut.controller.search_thread_phase[tid])
                        == THREAD_PHASE_STORE_PUBLISH) inflight_count++;
            end
            active_thread_histogram[active_count] = active_thread_histogram[active_count] + 1;
            if (inflight_count > 5) inflight_count = 5;
            inflight_histogram[inflight_count] = inflight_histogram[inflight_count] + 1;
            if (any_ready_move_blocked) move_stall_cycles <= move_stall_cycles + 1;
            if (any_ready_tt_blocked) tt_request_stall_cycles <= tt_request_stall_cycles + 1;

            if (dut.controller.search_board_issue_valid) begin
                board_issues <= board_issues + 1;
                if (dut.controller.board_update_op == BOARD_REVERSE_MOVE_OP) begin
                    board_reverses <= board_reverses + 1;
                end else begin
                    if (dut.controller.search_stack_top[dut.controller.search_board_issue_thread].remaining_depth == 0)
                        qsearch_board_issues <= qsearch_board_issues + 1;
                    else
                        main_search_board_issues <= main_search_board_issues + 1;
                    if (dut.controller.search_pvs_research[dut.controller.search_board_issue_thread])
                        pvs_researches <= pvs_researches + 1;
                    else if (dut.controller.search_stack_top[dut.controller.search_board_issue_thread].legal_move_count != 0)
                        pvs_scouts <= pvs_scouts + 1;
                    if (dut.controller.search_ply[dut.controller.search_board_issue_thread] != 0
                            && dut.controller.search_stack_top[dut.controller.search_board_issue_thread].remaining_depth >= 3
                            && dut.controller.search_stack_top[dut.controller.search_board_issue_thread].legal_move_count >= 3
                            && !dut.controller.search_pvs_research[dut.controller.search_board_issue_thread])
                        lmr_reduced_issues <= lmr_reduced_issues + 1;
                end
            end
            // Sample the tagged pipeline completion only while the controller
            // consumes it. ST_FLUSH_RESPOND freezes the tag pipe, so sampling a
            // held valid tag there would count one completion multiple times.
            // The simulation result pulse is registered one cycle later, when
            // check status and the parent's legal-move ordinal have moved on.
            if (int'(dut.controller.state) == CONTROLLER_STATE_SEARCH_RUN
                    && dut.controller.search_board_tag_valid_pipe[
                    SEARCH_BOARD_TAG_PIPE_LEN - 1
                ]) begin
                automatic int tid = int'(dut.controller.search_board_tag_pipe[
                    SEARCH_BOARD_TAG_PIPE_LEN - 1
                ]);
                automatic logic reverse_complete =
                    dut.controller.search_board_op_tag_pipe[
                        SEARCH_BOARD_TAG_PIPE_LEN - 1
                    ] == BOARD_REVERSE_MOVE_OP;
                automatic int legal_bucket = ordinal_bucket(
                    int'(dut.controller.search_stack_top[tid].legal_move_count) + 1
                );
                board_completions <= board_completions + 1;
                // Reverse operations restore a parent board; they are pipeline
                // work, not searched candidate moves.
                if (!reverse_complete) begin
                    if (!dut.controller.board_update_mover_in_check) begin
                        legal_candidates <= legal_candidates + 1;
                        if (dut.controller.board_update_out.halfmove_clock >= 100)
                            fifty_move_draws <= fifty_move_draws + 1;
                        legal_ordinal_histogram[legal_bucket] =
                            legal_ordinal_histogram[legal_bucket] + 1;
                    end else begin
                        illegal_candidates <= illegal_candidates + 1;
                    end
                end
            end
            // Measure the complete request-to-response latency seen by the
            // search controller, rather than inferring it from thread waits.
            if (dut.controller.move_cmd_resp_valid) begin
                automatic int tid = int'(dut.controller.move_cmd_resp_thread);
                automatic longint unsigned operation_cycles =
                    search_cycles - move_command_start_cycle[tid];
                if (!move_command_active[tid])
                    $fatal(1, "move-generator response without a profiled command");
                record_move_operation(move_command_operation[tid], operation_cycles, 1'b0);
                move_command_active[tid] = 1'b0;
            end
            if (dut.controller.move_quiet_resp_valid) begin
                automatic int tid = int'(dut.controller.move_quiet_resp_thread);
                automatic longint unsigned operation_cycles =
                    search_cycles - move_command_start_cycle[tid];
                if (!move_command_active[tid])
                    $fatal(1, "quiet move-generator response without a profiled command");
                record_move_operation(move_command_operation[tid], operation_cycles, 1'b0);
                move_command_active[tid] = 1'b0;
            end
            if (dut.controller.move_cmd_valid && dut.controller.move_cmd_ready) begin
                automatic int tid = int'(dut.controller.move_cmd_thread);
                if (move_command_active[tid])
                    $fatal(1, "thread accepted more than one outstanding move command");
                move_commands = move_commands + 1;
                move_command_active[tid] = 1'b1;
                move_command_operation[tid] = dut.controller.move_cmd;
                move_command_start_cycle[tid] = search_cycles;
            end
            if (dut.controller.move_quiet_cmd_valid && dut.controller.move_quiet_cmd_ready) begin
                automatic int tid = int'(dut.controller.move_quiet_cmd_thread);
                if (move_command_active[tid])
                    $fatal(1, "thread accepted more than one outstanding move command");
                move_commands = move_commands + 1;
                move_command_active[tid] = 1'b1;
                move_command_operation[tid] = MOVE_GEN_GENERATE_QUIET;
                move_command_start_cycle[tid] = search_cycles;
            end

            // Bucket pops are pipelined and may accept a new request on the
            // same edge that the previous response is consumed.
            if (dut.controller.move_pop_resp_valid) begin
                automatic longint unsigned operation_cycles =
                    search_cycles - move_pop_start_cycle;
                if (!move_pop_active)
                    $fatal(1, "move bucket response without a profiled request");
                record_move_operation(
                    MOVE_OPERATION_BUCKET_POP, operation_cycles, 1'b0
                );
                move_pop_active = 1'b0;
            end
            if (dut.controller.move_pop_valid && dut.controller.move_pop_ready) begin
                if (move_pop_active)
                    $fatal(1, "move bucket pipeline accepted more than one outstanding request");
                move_pops <= move_pops + 1;
                move_pop_active = 1'b1;
                move_pop_start_cycle = search_cycles;
            end

            // Destination/source events are classified by the active
            // generation command. Candidate emission is counted below at the
            // common ordering-bucket write interface.
            if (dut.controller.move_generator.noisy_lane.destination_examined_event)
                noisy_destinations_examined = noisy_destinations_examined + 1;
            if (dut.controller.move_generator.quiet_lane.destination_examined_event)
                quiet_destinations_examined = quiet_destinations_examined + 1;
            if (dut.controller.move_generator.noisy_lane.destination_with_source_event)
                noisy_destinations_with_sources = noisy_destinations_with_sources + 1;
            if (dut.controller.move_generator.quiet_lane.destination_with_source_event)
                quiet_destinations_with_sources = quiet_destinations_with_sources + 1;
            if (dut.controller.move_generator.noisy_lane.profile_candidate_event)
                candidates_analyzed = candidates_analyzed + 1;
            if (dut.controller.move_generator.quiet_lane.profile_candidate_event)
                candidates_analyzed = candidates_analyzed + 1;
            if (dut.controller.move_generator.noisy_lane.generator_history_read)
                history_lookups = history_lookups + 1;
            if (dut.controller.move_generator.quiet_lane.generator_history_read)
                history_lookups = history_lookups + 1;
            if (int'(dut.controller.move_generator.noisy_lane.state) != 0)
                move_generation_cycles = move_generation_cycles + 1;
            if (int'(dut.controller.move_generator.quiet_lane.state) != 0)
                move_generation_cycles = move_generation_cycles + 1;
            if (dut.controller.move_pop_resp_valid) begin
                if (dut.controller.move_pop_resp_found) begin
                    bucket_pops[int'(dut.controller.move_pop_resp_bucket)] <=
                        bucket_pops[int'(dut.controller.move_pop_resp_bucket)] + 1;
                    selected_bucket_valid[int'(dut.controller.move_pop_resp_thread)]
                        [int'(dut.controller.move_pop_resp_ply)] <= 1'b1;
                    selected_bucket_move[int'(dut.controller.move_pop_resp_thread)]
                        [int'(dut.controller.move_pop_resp_ply)] <= dut.controller.move_pop_resp_move;
                    selected_bucket[int'(dut.controller.move_pop_resp_thread)]
                        [int'(dut.controller.move_pop_resp_ply)] <= dut.controller.move_pop_resp_bucket;
                end else begin
                    move_pop_misses <= move_pop_misses + 1;
                end
            end
            for (int bucket = 0; bucket < MOVE_BUCKET_COUNT; bucket++) begin
                if (dut.controller.move_generator.noisy_lane.bucket_wr_en[bucket]) begin
                    bucket_writes[bucket] <= bucket_writes[bucket] + 1;
                    noisy_candidates_emitted = noisy_candidates_emitted + 1;
                    if (int'(dut.controller.move_generator.noisy_lane.bucket_wr_top) + 1
                            > bucket_high_water[bucket])
                        bucket_high_water[bucket] =
                            int'(dut.controller.move_generator.noisy_lane.bucket_wr_top) + 1;
                end
                if (dut.controller.move_generator.quiet_lane.bucket_wr_en[bucket]) begin
                    bucket_writes[bucket] <= bucket_writes[bucket] + 1;
                    quiet_candidates_emitted = quiet_candidates_emitted + 1;
                    if (int'(dut.controller.move_generator.quiet_lane.bucket_wr_top) + 1
                            > bucket_high_water[bucket])
                        bucket_high_water[bucket] =
                            int'(dut.controller.move_generator.quiet_lane.bucket_wr_top) + 1;
                end
            end
            // An accepted evaluator request is one static evaluation.
            if (dut.controller.search_eval_issue_valid) evaluations <= evaluations + 1;
            if (dut.controller.search_eval_result_valid) eval_completions <= eval_completions + 1;
            if (dut.controller.nnue_update_valid && dut.controller.nnue_update_ready) begin
                nnue_update_requests = nnue_update_requests + 1;
                if (int'(dut.controller.state) == CONTROLLER_STATE_SEARCH_ROOT_INIT) begin
                    nnue_root_rows = nnue_root_rows + 1;
                end else if (dut.controller.nnue_update_req.complete
                        && !dut.controller.nnue_update_req.apply) begin
                    nnue_completion_markers = nnue_completion_markers + 1;
                end else if (dut.controller.nnue_delta_busy
                        && dut.controller.nnue_delta_replay
                        && dut.controller.nnue_plan_kind[dut.controller.nnue_delta_thread]
                            == dut.controller.NNUE_PLAN_REBUILD) begin
                    nnue_rebuild_rows = nnue_rebuild_rows + 1;
                    if (dut.controller.nnue_update_req.clear)
                        nnue_rebuilds = nnue_rebuilds + 1;
                end else if (dut.controller.nnue_build_busy
                        && !dut.controller.nnue_build_draining) begin
                    nnue_recovery_rows = nnue_recovery_rows + 1;
                end else begin
                    nnue_delta_requests = nnue_delta_requests + 1;
                end
            end
            if (dut.controller.nnue_update_done_valid)
                nnue_update_completions = nnue_update_completions + 1;
            if (dut.controller.nnue_delta_busy && dut.controller.nnue_delta_draining
                    && dut.controller.nnue_update_idle
                    && dut.controller.nnue_plan_kind[dut.controller.nnue_delta_thread]
                        == dut.controller.NNUE_PLAN_REBUILD)
                nnue_update_completions = nnue_update_completions + 1;
            if (dut.controller.repetition_req_valid) repetition_requests <= repetition_requests + 1;
            if (dut.controller.repetition_resp_valid) repetition_responses <= repetition_responses + 1;
            if (dut.controller.repetition_resp_valid && dut.controller.repetition_resp_is_draw)
                repetition_draws <= repetition_draws + 1;
            if (dut.controller.tt_lookup_resp_valid) begin
                automatic int tid = int'(dut.controller.tt_lookup_resp.thread_id);
                automatic logic usable;
                tt_lookups <= tt_lookups + 1;
                depth_tt_lookups[iteration_depth] <= depth_tt_lookups[iteration_depth] + 1;
                if (dut.controller.tt_lookup_resp.hit) begin
                    tt_hits <= tt_hits + 1;
                    depth_tt_hits[iteration_depth] <= depth_tt_hits[iteration_depth] + 1;
                    if (dut.controller.tt_lookup_resp.bound_type != TT_BOUND_INVALID)
                        tt_bound_hits[int'(dut.controller.tt_lookup_resp.bound_type) - 1] <=
                            tt_bound_hits[int'(dut.controller.tt_lookup_resp.bound_type) - 1] + 1;
                    usable = dut.controller.tt_lookup_resp.depth
                            >= dut.controller.search_stack_top[tid].remaining_depth
                        && (dut.controller.tt_lookup_resp.bound_type == TT_BOUND_EXACT
                            || (dut.controller.tt_lookup_resp.bound_type == TT_BOUND_LOWER
                                && dut.controller.tt_lookup_resp.score
                                    >= dut.controller.search_stack_top[tid].beta)
                            || (dut.controller.tt_lookup_resp.bound_type == TT_BOUND_UPPER
                                && dut.controller.tt_lookup_resp.score
                                    <= dut.controller.search_stack_top[tid].alpha));
                    if (usable) tt_cutoff_hits <= tt_cutoff_hits + 1;
                    else tt_ordering_hits <= tt_ordering_hits + 1;
                end
            end
            if (dut.controller.tt_store_req_valid && dut.controller.tt_store_req_ready) tt_stores <= tt_stores + 1;
            if (dut.controller.tt_cache_access) begin
                if (dut.controller.tt_cache_access_is_store) begin
                    tt_cache_store_probes <= tt_cache_store_probes + 1;
                    if (dut.controller.tt_cache_hit) tt_cache_store_hits <= tt_cache_store_hits + 1;
                end else begin
                    tt_cache_lookup_probes <= tt_cache_lookup_probes + 1;
                    depth_cache_probes[iteration_depth] <= depth_cache_probes[iteration_depth] + 1;
                    if (dut.controller.tt_cache_hit) tt_cache_lookup_hits <= tt_cache_lookup_hits + 1;
                    if (dut.controller.tt_cache_hit
                            && int'(dut.controller.external_tt_gen.tt_load_store.state)
                                != TT_STATE_IDLE)
                        tt_cache_bypass_hits <= tt_cache_bypass_hits + 1;
                    if (dut.controller.tt_cache_hit)
                        depth_cache_hits[iteration_depth] <= depth_cache_hits[iteration_depth] + 1;
                end
            end
            if (dut.controller.external_tt_gen.tt_load_store.store_accept
                    && !dut.controller.external_tt_gen.tt_load_store.store_fifo_push_ready)
                tt_store_drops <= tt_store_drops + 1;
            if (tt_mem_req_valid && !tt_mem_req_ready) cdc_command_stalls <= cdc_command_stalls + 1;
            if (tt_mem_write_valid && !tt_mem_write_ready) cdc_write_stalls <= cdc_write_stalls + 1;
            if (tt_mem_read_valid && !tt_mem_read_ready) cdc_read_stalls <= cdc_read_stalls + 1;
            if (tt_mem_done_valid && !tt_mem_done_ready) cdc_done_stalls <= cdc_done_stalls + 1;

            if (events_fd != 0 && dut.controller.search_nodes != previous_nodes)
                $fdisplay(events_fd, "{\"cycle\":%0d,\"event\":\"node\",\"nodes\":%0d}",
                    search_cycles, dut.controller.search_nodes);
            if (dut.controller.search_nodes > previous_nodes)
                depth_nodes[iteration_depth] <= depth_nodes[iteration_depth]
                    + (dut.controller.search_nodes - previous_nodes);
            previous_nodes <= dut.controller.search_nodes;
            if (dut.controller.profile_beta_cutoff_event) begin
                automatic int cutoff_tid = int'(dut.controller.profile_beta_cutoff_thread);
                automatic int cutoff_ply = int'(dut.controller.profile_beta_cutoff_ply);
                automatic int cutoff_bucket =
                    ordinal_bucket(int'(dut.controller.profile_beta_cutoff_rank));
                cutoff_ordinal_histogram[cutoff_bucket] =
                    cutoff_ordinal_histogram[cutoff_bucket] + 1;
                if (selected_bucket_valid[cutoff_tid][cutoff_ply]
                        && selected_bucket_move[cutoff_tid][cutoff_ply]
                            === dut.controller.profile_beta_cutoff_move) begin
                    bucket_cutoffs[int'(selected_bucket[cutoff_tid][cutoff_ply])] <=
                        bucket_cutoffs[int'(selected_bucket[cutoff_tid][cutoff_ply])] + 1;
                end else begin
                    direct_move_cutoffs <= direct_move_cutoffs + 1;
                end
            end
            if (dut.controller.profile_rfp_cutoff_event)
                rfp_cutoffs <= rfp_cutoffs + 1;
            if (dut.controller.profile_qdelta_prune_event)
                qdelta_pruned_moves <= qdelta_pruned_moves + 1;
            if (dut.controller.profile_terminal_event) begin
                case (dut.controller.profile_terminal_kind)
                    2'd0: terminal_main_exhausted <= terminal_main_exhausted + 1;
                    2'd1: terminal_qsearch_exhausted <= terminal_qsearch_exhausted + 1;
                    2'd2: terminal_checkmates <= terminal_checkmates + 1;
                    default: terminal_stalemates <= terminal_stalemates + 1;
                endcase
            end
        end
        if (dut.controller_resp_valid && profile_active) begin
            for (int tid = 0; tid < SEARCH_THREAD_COUNT; tid++)
                if (move_command_active[tid]) begin
                    record_move_operation(
                        move_command_operation[tid],
                        search_cycles - move_command_start_cycle[tid],
                        1'b1
                    );
                    move_command_active[tid] = 1'b0;
                end
            if (move_pop_active) begin
                record_move_operation(
                    MOVE_OPERATION_BUCKET_POP,
                    search_cycles - move_pop_start_cycle,
                    1'b1
                );
                move_pop_active = 1'b0;
            end
            search_result <= dut.controller_resp;
            result_seen <= 1'b1;
            profile_active <= 1'b0;
            drain_active <= 1'b1;
        end
        if (drain_active) begin
            drain_cycles <= drain_cycles + 1;
            tt_state_cycles[int'(dut.controller.external_tt_gen.tt_load_store.state)] <=
                tt_state_cycles[int'(dut.controller.external_tt_gen.tt_load_store.state)] + 1;
            if (dut.controller.tt_cache_access && dut.controller.tt_cache_access_is_store) begin
                tt_cache_store_probes <= tt_cache_store_probes + 1;
                if (dut.controller.tt_cache_hit) tt_cache_store_hits <= tt_cache_store_hits + 1;
            end
            if (tt_mem_req_valid && !tt_mem_req_ready) cdc_command_stalls <= cdc_command_stalls + 1;
            if (tt_mem_write_valid && !tt_mem_write_ready) cdc_write_stalls <= cdc_write_stalls + 1;
            if (tt_mem_read_valid && !tt_mem_read_ready) cdc_read_stalls <= cdc_read_stalls + 1;
            if (tt_mem_done_valid && !tt_mem_done_ready) cdc_done_stalls <= cdc_done_stalls + 1;
        end
    end

    always @(posedge memory_clk) begin
        if (profile_active || drain_active) begin
            sdram_state_cycles[int'(memory_controller.state)] <=
                sdram_state_cycles[int'(memory_controller.state)] + 1;
            if (backend_req_valid && backend_req_ready) begin
                if (backend_req_write) begin
                    sdram_writes <= sdram_writes + 1;
                    sdram_write_words <= sdram_write_words + backend_req_length;
                end else begin
                    sdram_reads <= sdram_reads + 1;
                    sdram_read_words <= sdram_read_words + backend_req_length;
                end
                if (memory_controller.open_valid[backend_req_address[24:23]]) begin
                    if (memory_controller.open_row[backend_req_address[24:23]] == backend_req_address[22:10])
                        sdram_row_hits <= sdram_row_hits + 1;
                    else
                        sdram_row_conflicts <= sdram_row_conflicts + 1;
                end else begin
                    sdram_row_misses <= sdram_row_misses + 1;
                end
            end
        end
    end

    task automatic write_metrics();
        emit("cycles.setup", setup_cycles);
        emit("cycles.search", search_cycles);
        emit("cycles.output", output_cycles);
        emit("cycles.drain", drain_cycles);
        emit_result("best_move.from", search_result.best_move.from_pos);
        emit_result("best_move.to", search_result.best_move.to_pos);
        emit_result("best_move.promotion", search_result.best_move.promo_piece);
        emit_result("score", $signed(search_result.score));
        emit_result("nodes", search_result.nodes_count);
        emit_result("completed_depth", search_result.completed_depth);
        emit_result("end_reason", search_result.end_reason);
        emit_result("error", search_result.error);
        emit_result("deepest_search_ply", deepest_search_ply);
        for (int state_idx = 0; state_idx < ENGINE_STATE_COUNT; state_idx++)
            emit($sformatf("states.engine.%0d", state_idx), engine_state_cycles[state_idx]);
        for (int state_idx = 0; state_idx < CONTROLLER_STATE_COUNT; state_idx++)
            emit($sformatf("states.controller.%0d", state_idx), controller_state_cycles[state_idx]);
        for (int tid = 0; tid < SEARCH_THREAD_COUNT; tid++) begin
            emit($sformatf("threads.%0d.nodes", tid), dut.controller.search_thread_nodes[tid]);
            for (int phase = 0; phase < THREAD_PHASE_COUNT; phase++)
                emit($sformatf("threads.%0d.phases.%0d", tid, phase), thread_phase_cycles[tid][phase]);
            emit($sformatf("threads.%0d.ready.nnue_init", tid), thread_ready_nnue_init[tid]);
            emit($sformatf("threads.%0d.ready.dispatch", tid), thread_ready_dispatch[tid]);
            emit($sformatf("threads.%0d.ready.arbitration", tid), thread_ready_arbitration[tid]);
            emit($sformatf("threads.%0d.ready.tt_blocked", tid), thread_ready_tt_blocked[tid]);
            emit($sformatf("threads.%0d.ready.noisy_move_blocked", tid),
                thread_ready_noisy_move_blocked[tid]);
            emit($sformatf("threads.%0d.ready.quiet_move_blocked", tid),
                thread_ready_quiet_move_blocked[tid]);
            emit($sformatf("threads.%0d.ready.transition", tid), thread_ready_transition[tid]);
            emit($sformatf("threads.%0d.move_wait.noisy", tid), thread_noisy_move_wait[tid]);
            emit($sformatf("threads.%0d.move_wait.quiet", tid), thread_quiet_move_wait[tid]);
            emit($sformatf("threads.%0d.repetition_wait.nnue_update", tid),
                thread_repetition_nnue_wait[tid]);
            emit($sformatf("threads.%0d.repetition_wait.overlap", tid),
                thread_repetition_overlap_wait[tid]);
            emit($sformatf("threads.%0d.repetition_wait.checker", tid),
                thread_repetition_checker_wait[tid]);
            for (int order = 0; order < MOVE_ORDER_STATE_COUNT; order++)
                emit($sformatf("threads.%0d.move_order.%0d", tid, order), thread_move_order_cycles[tid][order]);
            for (int ply = 0; ply < MAX_PLY_COUNT; ply++)
                if (thread_ply_cycles[tid][ply] != 0)
                    emit($sformatf("threads.%0d.ply.%0d", tid, ply), thread_ply_cycles[tid][ply]);
        end
        for (int count = 0; count <= SEARCH_THREAD_COUNT; count++)
            emit($sformatf("concurrency.active_threads.%0d", count), active_thread_histogram[count]);
        for (int count = 0; count <= 5; count++)
            emit($sformatf("concurrency.inflight.%0d", count), inflight_histogram[count]);
        for (int state_idx = 0; state_idx < GENERATOR_STATE_COUNT; state_idx++)
            emit($sformatf("components.move_generator.states.%0d", state_idx), generator_state_cycles[state_idx]);
        for (int state_idx = 0; state_idx < TT_STATE_COUNT; state_idx++)
            emit($sformatf("tt.frontend_states.%0d", state_idx), tt_state_cycles[state_idx]);
        for (int state_idx = 0; state_idx < SDRAM_STATE_COUNT; state_idx++)
            emit($sformatf("sdram.states.%0d", state_idx), sdram_state_cycles[state_idx]);
        for (int depth = 0; depth < MAX_PLY_COUNT; depth++) begin
            if (depth_cycles[depth] != 0) begin
                emit($sformatf("depths.%0d.cycles", depth), depth_cycles[depth]);
                emit($sformatf("depths.%0d.nodes", depth), depth_nodes[depth]);
                emit($sformatf("depths.%0d.tt_lookups", depth), depth_tt_lookups[depth]);
                emit($sformatf("depths.%0d.tt_hits", depth), depth_tt_hits[depth]);
                emit($sformatf("depths.%0d.cache_probes", depth), depth_cache_probes[depth]);
                emit($sformatf("depths.%0d.cache_hits", depth), depth_cache_hits[depth]);
                emit($sformatf("depths.%0d.max_ply", depth), depth_max_ply[depth]);
            end
        end
        emit("components.board.issues", board_issues);
        emit("components.board.reverses", board_reverses);
        emit("components.board.completions", board_completions);
        emit("components.board.legal_candidates", legal_candidates);
        emit("components.board.illegal_candidates", illegal_candidates);
        emit("components.move.commands", move_commands);
        emit("components.move.pops", move_pops);
        emit("components.move.pop_misses", move_pop_misses);
        for (int operation = 0; operation < MOVE_OPERATION_COUNT; operation++) begin
            emit($sformatf("components.move_generator.operations.%0d.count", operation),
                move_operation_count[operation]);
            emit($sformatf("components.move_generator.operations.%0d.total_cycles", operation),
                move_operation_cycles[operation]);
            emit($sformatf("components.move_generator.operations.%0d.max_cycles", operation),
                move_operation_max_cycles[operation]);
            emit($sformatf("components.move_generator.operations.%0d.aborted", operation),
                move_operation_aborted[operation]);
        end
        emit("components.move_generator.generation.noisy.destinations_examined",
            noisy_destinations_examined);
        emit("components.move_generator.generation.noisy.destinations_with_sources",
            noisy_destinations_with_sources);
        emit("components.move_generator.generation.noisy.candidates_emitted",
            noisy_candidates_emitted);
        emit("components.move_generator.generation.quiet.destinations_examined",
            quiet_destinations_examined);
        emit("components.move_generator.generation.quiet.destinations_with_sources",
            quiet_destinations_with_sources);
        emit("components.move_generator.generation.quiet.candidates_emitted",
            quiet_candidates_emitted);
        emit("components.eval.evaluations", evaluations);
        emit("components.eval.completions", eval_completions);
        emit("components.eval.update_requests", nnue_update_requests);
        emit("components.eval.root_rows", nnue_root_rows);
        emit("components.eval.rebuild_rows", nnue_rebuild_rows);
        emit("components.eval.rebuilds", nnue_rebuilds);
        emit("components.eval.delta_requests", nnue_delta_requests);
        emit("components.eval.completion_markers", nnue_completion_markers);
        emit("components.eval.recovery_rows", nnue_recovery_rows);
        emit("components.eval.update_completions", nnue_update_completions);
        emit("components.eval.update_busy_cycles", nnue_update_busy_cycles);
        emit("components.eval.update_backpressure_cycles",
            nnue_update_backpressure_cycles);
        emit("components.eval.accumulator_wrap_lanes",
            dut.controller.nnue_evaluator.profile_accumulator_wrap_lanes);
        emit("components.repetition.requests", repetition_requests);
        emit("components.repetition.responses", repetition_responses);
        emit("stalls.move_not_ready", move_stall_cycles);
        emit("stalls.tt_request_not_ready", tt_request_stall_cycles);
        emit("stalls.cdc_command", cdc_command_stalls);
        emit("stalls.cdc_write", cdc_write_stalls);
        emit("stalls.cdc_read", cdc_read_stalls);
        emit("stalls.cdc_done", cdc_done_stalls);
        for (int bucket = 0; bucket < MOVE_BUCKET_COUNT; bucket++) begin
            emit($sformatf("move_order.bucket_writes.%0d", bucket), bucket_writes[bucket]);
            emit($sformatf("move_order.bucket_pops.%0d", bucket), bucket_pops[bucket]);
            emit($sformatf("move_order.bucket_cutoffs.%0d", bucket), bucket_cutoffs[bucket]);
            emit($sformatf("move_order.bucket_high_water.%0d", bucket), bucket_high_water[bucket]);
        end
        for (int idx = 0; idx < ORDINAL_BUCKET_COUNT; idx++)
            emit($sformatf("move_order.legal_ordinal.%0d", idx), legal_ordinal_histogram[idx]);
        for (int idx = 0; idx < ORDINAL_BUCKET_COUNT; idx++)
            emit($sformatf("move_order.cutoff_ordinal.%0d", idx), cutoff_ordinal_histogram[idx]);
        emit("move_order.direct_cutoffs", direct_move_cutoffs);
        emit("move_order.noisy_jobs", noisy_candidates_emitted);
        emit("move_order.quiet_jobs", quiet_candidates_emitted);
        emit("move_order.destinations",
            noisy_destinations_examined + quiet_destinations_examined);
        emit("move_order.candidates", candidates_analyzed);
        emit("move_order.history_lookups", history_lookups);
        emit("move_order.generation_cycles", move_generation_cycles);
        emit("move_order.overflows", dut.controller.move_overflow_count);
        emit("algorithm.main_board_issues", main_search_board_issues);
        emit("algorithm.qsearch_board_issues", qsearch_board_issues);
        emit("algorithm.pvs_scouts", pvs_scouts);
        emit("algorithm.pvs_researches", pvs_researches);
        emit("algorithm.lmr_reduced_issues", lmr_reduced_issues);
        emit("algorithm.rfp_cutoffs", rfp_cutoffs);
        emit("algorithm.qdelta_pruned_moves", qdelta_pruned_moves);
        emit("algorithm.terminal_checkmates", terminal_checkmates);
        emit("algorithm.terminal_stalemates", terminal_stalemates);
        emit("algorithm.terminal_main_exhausted", terminal_main_exhausted);
        emit("algorithm.terminal_qsearch_exhausted", terminal_qsearch_exhausted);
        emit("algorithm.repetition_draws", repetition_draws);
        emit("algorithm.fifty_move_draws", fifty_move_draws);
        emit("tt.lookups", tt_lookups);
        emit("tt.hits", tt_hits);
        emit("tt.bound_hits.exact", tt_bound_hits[0]);
        emit("tt.bound_hits.lower", tt_bound_hits[1]);
        emit("tt.bound_hits.upper", tt_bound_hits[2]);
        emit("tt.cutoff_hits", tt_cutoff_hits);
        emit("tt.ordering_hits", tt_ordering_hits);
        emit("tt.stores", tt_stores);
        emit("tt.store_drops", tt_store_drops);
        emit("tt.store_fifo_high_water", tt_store_fifo_high_water);
        emit("tt.store_write_preemptions", tt_store_write_preemptions);
        emit("tt.cache.lookup_probes", tt_cache_lookup_probes);
        emit("tt.cache.lookup_hits", tt_cache_lookup_hits);
        emit("tt.cache.bypass_hits", tt_cache_bypass_hits);
        emit("tt.cache.store_probes", tt_cache_store_probes);
        emit("tt.cache.store_hits", tt_cache_store_hits);
        emit("sdram.read_requests", sdram_reads);
        emit("sdram.write_requests", sdram_writes);
        emit("sdram.read_words", sdram_read_words);
        emit("sdram.write_words", sdram_write_words);
        emit("sdram.row_hits", sdram_row_hits);
        emit("sdram.row_misses", sdram_row_misses);
        emit("sdram.row_conflicts", sdram_row_conflicts);
        $fdisplay(metrics_fd, "PROFILE_COMPLETE");
    endtask

    initial begin
        data_in = '0;
        data_in_valid = 1'b0;
        ready_for_result = 1'b1;
        profile_active = 1'b0;
        drain_active = 1'b0;
        result_seen = 1'b0;
        search_result = EngineControllerResponse'('0);
        setup_cycles = 0;
        search_cycles = 0;
        output_cycles = 0;
        drain_cycles = 0;
        previous_nodes = 0;
        deepest_search_ply = PlyIndex'(0);
        tt_store_fifo_high_water = 0;
        tt_cache_bypass_hits = 0;
        tt_store_write_preemptions = 0;
        move_pop_active = 1'b0;
        for (int tid = 0; tid < SEARCH_THREAD_COUNT; tid++) begin
            move_command_active[tid] = 1'b0;
            move_command_operation[tid] = '0;
            move_command_start_cycle[tid] = 0;
            thread_ready_nnue_init[tid] = 0;
            thread_ready_dispatch[tid] = 0;
            thread_ready_arbitration[tid] = 0;
            thread_ready_tt_blocked[tid] = 0;
            thread_ready_noisy_move_blocked[tid] = 0;
            thread_ready_quiet_move_blocked[tid] = 0;
            thread_ready_transition[tid] = 0;
            thread_noisy_move_wait[tid] = 0;
            thread_quiet_move_wait[tid] = 0;
            thread_repetition_nnue_wait[tid] = 0;
            thread_repetition_overlap_wait[tid] = 0;
            thread_repetition_checker_wait[tid] = 0;
        end
        move_pop_start_cycle = 0;
        noisy_destinations_examined = 0;
        quiet_destinations_examined = 0;
        noisy_destinations_with_sources = 0;
        quiet_destinations_with_sources = 0;
        noisy_candidates_emitted = 0;
        quiet_candidates_emitted = 0;
        candidates_analyzed = 0;
        history_lookups = 0;
        move_generation_cycles = 0;
        for (int bucket = 0; bucket < MOVE_BUCKET_COUNT; bucket++)
            bucket_high_water[bucket] = 0;
        evaluations = 0;
        eval_completions = 0;
        nnue_update_requests = 0;
        nnue_root_rows = 0;
        nnue_rebuild_rows = 0;
        nnue_rebuilds = 0;
        nnue_delta_requests = 0;
        nnue_completion_markers = 0;
        nnue_recovery_rows = 0;
        nnue_update_completions = 0;
        nnue_update_busy_cycles = 0;
        nnue_update_backpressure_cycles = 0;
        repetition_requests = 0;
        repetition_responses = 0;
        rfp_cutoffs = 0;
        qdelta_pruned_moves = 0;
        for (int operation = 0; operation < MOVE_OPERATION_COUNT; operation++) begin
            move_operation_count[operation] = 0;
            move_operation_cycles[operation] = 0;
            move_operation_max_cycles[operation] = 0;
            move_operation_aborted[operation] = 0;
        end
        for (int depth = 0; depth < MAX_PLY_COUNT; depth++)
            depth_max_ply[depth] = PlyIndex'(0);
        for (int tid = 0; tid < SEARCH_THREAD_COUNT; tid++)
            for (int ply = 0; ply < MAX_PLY_COUNT; ply++)
                selected_bucket_valid[tid][ply] = 1'b0;
        metrics_fd = 0;
        events_fd = 0;
        search_kind = 0;
        search_limit = 5;
        if (!$value$plusargs("BOARD_FILE=%s", board_file)) $fatal(1, "BOARD_FILE plusarg is required");
        if (!$value$plusargs("METRICS_FILE=%s", metrics_file)) $fatal(1, "METRICS_FILE plusarg is required");
        void'($value$plusargs("SEARCH_KIND=%d", search_kind));
        void'($value$plusargs("SEARCH_LIMIT=%d", search_limit));
        if ($value$plusargs("EVENTS_FILE=%s", events_file)) events_fd = $fopen(events_file, "w");
`ifdef VERILATOR
        if ($value$plusargs("WAVE_FILE=%s", wave_file)) begin
            $dumpfile(wave_file);
            $dumpvars(0, tb_engine_profile);
        end
`endif
        metrics_fd = $fopen(metrics_file, "w");
        if (metrics_fd == 0) $fatal(1, "could not open metrics output");
        $readmemh(board_file, board_payload);

        repeat (4) @(posedge memory_clk);
        system_rst_n = 1'b1;
        while (!engine_rst_n) @(posedge engine_clk);
        repeat (4) @(posedge engine_clk);

        setup_cycles = 0;
        fork
            begin
                while (!profile_active) begin
                    @(posedge engine_clk);
                    setup_cycles++;
                end
            end
            begin
                send_byte(ENGINE_CMD_SET_BOARD);
                for (int idx = 0; idx < 36; idx++) send_byte(board_payload[idx]);
                consume_response(2);
                case (search_kind)
                    0: begin
                        send_byte(ENGINE_CMD_SEARCH_DEPTH);
                        send_byte(search_limit[7:0]);
                    end
                    1: begin
                        send_byte(ENGINE_CMD_SEARCH_NODES);
                        for (int idx = 0; idx < 5; idx++) send_byte(search_limit[idx*8 +: 8]);
                    end
                    default: begin
                        send_byte(ENGINE_CMD_SEARCH_FIXED_TIME);
                        for (int idx = 0; idx < 3; idx++) send_byte(search_limit[idx*8 +: 8]);
                    end
                endcase
            end
        join

        while (!result_seen) @(posedge engine_clk);
        while (!data_out_valid) @(posedge engine_clk);
        while (data_out_valid) begin
            @(posedge engine_clk);
            output_cycles++;
        end

        // Allow best-effort stores to reach SDRAM without including this work
        // in search utilization.
        repeat (20000) begin
            @(posedge engine_clk);
            if (dut.controller.external_tt_gen.tt_load_store.store_fifo_count == 0
                    && !dut.controller.external_tt_gen.tt_load_store.store_write_pending
                    && dut.controller.external_tt_gen.tt_load_store.state == 0
                    && memory_bridge.cmd_empty && memory_bridge.write_empty
                    && memory_bridge.done_empty && memory_controller.state == 16)
                break;
        end
        drain_active = 1'b0;
        write_metrics();
        if (events_fd != 0) $fclose(events_fd);
        $fclose(metrics_fd);
        if (error_flag || tt_memory_error || search_result.error) $fatal(1, "engine profile ended with an error");
        $display("PROFILE_COMPLETE cycles=%0d nodes=%0d", search_cycles, search_result.nodes_count);
        $finish;
    end

    initial begin
        #(64'd10_000_000_000);
        $fatal(1, "engine profile simulation timed out");
    end
endmodule
