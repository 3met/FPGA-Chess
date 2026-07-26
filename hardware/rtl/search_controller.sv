// By Emet Behrendt

import general_chess_defs::*;
import chess_helper_funcs::*;
import board_update_pipeline_defs::*;
import engine_defs::*;
import move_generator_defs::*;
import static_evaluator_defs::*;
import tt_defs::*;

module search_controller #(
    parameter int CLOCK_FREQ = 100_000_000,
    parameter int TT_INDEX_BITS = 10,
    parameter int ACTIVE_REPETITION_DEPTH = 100,
    parameter int SEARCH_THREAD_COUNT = THREAD_COUNT,
    parameter int SEARCH_STACK_DEPTH = MAX_PLY_COUNT,
    parameter int unsigned LMR_A_Q8 = 192,
    parameter int unsigned LMR_B_Q8 = 614,
    parameter bit EXTERNAL_TT = 1'b0,
    parameter bit ENABLE_SEARCH_STATS = 1'b0
) (
    input logic clk,
    input logic rst_n,
    input logic req_valid,
    output logic req_ready,
    input EngineControllerRequest req,
    output logic resp_valid,
    output EngineControllerResponse resp,
    input logic [7:0] debug_stat_address,
    output logic [39:0] debug_stat_value,
    input logic tt_memory_ready,
    input logic tt_memory_error,
    output logic tt_mem_req_valid,
    input logic tt_mem_req_ready,
    output logic tt_mem_req_write,
    output TTWordAddress tt_mem_req_address,
    output logic [3:0] tt_mem_req_length,
    output logic tt_mem_write_valid,
    input logic tt_mem_write_ready,
    output logic [15:0] tt_mem_write_data,
    output logic tt_mem_write_last,
    input logic tt_mem_read_valid,
    output logic tt_mem_read_ready,
    input logic [15:0] tt_mem_read_data,
    input logic tt_mem_read_last,
    input logic tt_mem_done_valid,
    output logic tt_mem_done_ready,
    input logic tt_mem_done_error
);

    localparam int BOARD_WAIT_BITS = $clog2(BOARD_UPDATE_PIPELINE_STAGE_CNT + 1);
    localparam int MOVE_WAIT_CYCLES = 2;
    localparam int MOVE_WAIT_BITS = $clog2(MOVE_WAIT_CYCLES + 1);
    localparam int EVAL_WAIT_CYCLES = STATIC_EVAL_PIPELINE_STAGE_CNT;
    localparam int EVAL_WAIT_BITS = $clog2(EVAL_WAIT_CYCLES + 1);
    localparam int SEARCH_BOARD_TAG_PIPE_LEN = (BOARD_UPDATE_PIPELINE_STAGE_CNT <= 1)
        ? 1 : BOARD_UPDATE_PIPELINE_STAGE_CNT;
    localparam int SEARCH_MOVE_TAG_PIPE_LEN = (MOVE_WAIT_CYCLES <= 1) ? 1 : MOVE_WAIT_CYCLES;
    localparam int SEARCH_EVAL_TAG_PIPE_LEN = EVAL_WAIT_CYCLES + 1;
    localparam int THREAD_COUNT_BITS = (SEARCH_THREAD_COUNT <= 1) ? 1 : $clog2(SEARCH_THREAD_COUNT + 1);
    localparam int SEARCH_STACK_ADDR_BITS = (SEARCH_STACK_DEPTH <= 1) ? 1 : $clog2(SEARCH_STACK_DEPTH);
    localparam int SEARCH_DEPTH_BITS = (SEARCH_STACK_DEPTH <= 2) ? 1 : $clog2(SEARCH_STACK_DEPTH);
    localparam int SEARCH_INF_VALUE = 32001;
    localparam int ASPIRATION_DELTA_VALUE = 512;
    localparam EvalScore SEARCH_INF = EvalScore'(SEARCH_INF_VALUE);
    localparam EvalScore ASPIRATION_DELTA = EvalScore'(ASPIRATION_DELTA_VALUE);
    localparam int LMR_LN2_Q8 = 177;
    localparam int LMR_MAX_REMAINING_DEPTH = SEARCH_STACK_DEPTH - 1;
    // Only floor-log2 buckets reachable by a legal configured search depth exist.
    localparam int LMR_DEPTH_BUCKETS = (LMR_MAX_REMAINING_DEPTH <= 1)
        ? 1 : $clog2(LMR_MAX_REMAINING_DEPTH + 1);

`ifndef SYNTHESIS
    initial begin
        if (SEARCH_THREAD_COUNT < 1 || SEARCH_THREAD_COUNT > THREAD_COUNT)
            $fatal(1, "SEARCH_THREAD_COUNT must fit the global ThreadID width");
        if (SEARCH_STACK_DEPTH < 1 || SEARCH_STACK_DEPTH > MAX_PLY_COUNT)
            $fatal(1, "SEARCH_STACK_DEPTH must fit the global PlyIndex width");
    end
`endif

    typedef logic [BOARD_WAIT_BITS-1:0] BoardWaitCount;
    typedef logic [MOVE_WAIT_BITS-1:0] MoveWaitCount;
    typedef logic [EVAL_WAIT_BITS-1:0] EvalWaitCount;
    typedef logic [THREAD_COUNT_BITS-1:0] ThreadCount;
    typedef logic [SEARCH_STACK_ADDR_BITS-1:0] SearchStackRamAddr;
    typedef logic [SEARCH_DEPTH_BITS-1:0] SearchDepth;
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
        EvalScore alpha;
        EvalScore orig_alpha;
        EvalScore beta;
        Move tt_move;
        MoveBucketTops bucket_tops;
        PlyIndex repetition_start;
        SearchDepth remaining_depth;
        logic [7:0] legal_move_count;
        MoveOrderState move_order_state;
        logic direct_attempted;
        logic has_legal;
        logic tt_checked;
        logic has_tt_move;
        logic stand_pat_done;
        logic scout_search;
        logic count_move_on_return;
    } SearchStackEntry;

    typedef enum logic [4:0] {
        ST_IDLE,
        ST_BOARD_ISSUE,
        ST_BOARD_WAIT,
        ST_DIRECT_DONE,
        ST_NEW_CLEAR_START,
        ST_NEW_CLEAR_WAIT,
        ST_NEW_SETUP_ISSUE,
        ST_NEW_SETUP_WAIT,
        ST_NEW_DONE,
        ST_PERFT_GEN_ISSUE,
        ST_PERFT_GEN_WAIT,
        ST_PERFT_PUSH_ISSUE,
        ST_PERFT_PUSH_WAIT,
        ST_PERFT_REVERSE_ISSUE,
        ST_PERFT_REVERSE_WAIT,
        ST_REPETITION_INIT,
        ST_REPETITION_ROOT_WAIT,
        ST_SEARCH_ITER_START,
        ST_SEARCH_RUN,
        ST_RESPOND,
        ST_KILL_DONE
    } SearchControllerState;

    typedef enum logic [1:0] {
        SEARCH_THREAD_IDLE,
        SEARCH_THREAD_ACTIVE,
        SEARCH_THREAD_DONE
    } SearchThreadStatus;

    typedef enum logic [3:0] {
        SEARCH_PHASE_IDLE,
        SEARCH_PHASE_READY,
        SEARCH_PHASE_TT_WAIT,
        SEARCH_PHASE_EVAL_WAIT,
        SEARCH_PHASE_MOVE_WAIT,
        SEARCH_PHASE_BOARD_WAIT,
        SEARCH_PHASE_REVERSE_WAIT,
        SEARCH_PHASE_REPETITION_WAIT,
        SEARCH_PHASE_STORE_PUBLISH,
        SEARCH_PHASE_TERMINAL_WAIT,
        SEARCH_PHASE_DONE
    } SearchThreadPhase;

    // Controller-level request, response, and active-position state.
    SearchControllerState state;
    EngineControllerRequest active_req;
    EngineControllerResponse resp_reg;
    BoardWaitCount board_wait_count;
    MoveWaitCount move_wait_count;

    FullBoard active_board;
    logic active_board_in_check;
    ZobristKey active_zobrist_key;
    EvalScore active_pst_eval;
    logic [6:0] new_setup_index;

    // Perft borrows search context zero and tracks whether each ply starts a node.

    // Per-thread search context and shared-pipeline bookkeeping.
    Move search_best_move[0:SEARCH_THREAD_COUNT-1];
    EvalScore search_root_best_score[0:SEARCH_THREAD_COUNT-1];
    NodeCountType search_nodes;
    NodeCountType search_thread_nodes[0:SEARCH_THREAD_COUNT-1];
    BoardWaitCount search_board_wait_count[0:SEARCH_THREAD_COUNT-1];
    MoveWaitCount search_move_wait_count[0:SEARCH_THREAD_COUNT-1];
    EvalWaitCount search_eval_wait_count[0:SEARCH_THREAD_COUNT-1];
    logic search_board_inflight[0:SEARCH_THREAD_COUNT-1];
    logic search_move_inflight[0:SEARCH_THREAD_COUNT-1];
    logic search_eval_inflight[0:SEARCH_THREAD_COUNT-1];
    logic search_tt_lookup_inflight[0:SEARCH_THREAD_COUNT-1];
    logic search_tt_store_inflight[0:SEARCH_THREAD_COUNT-1];
    logic search_tt_response_pending[0:SEARCH_THREAD_COUNT-1];
    logic search_repetition_pending[0:SEARCH_THREAD_COUNT-1];
    TTLookupResponse search_tt_response[0:SEARCH_THREAD_COUNT-1];
    ThreadID search_board_tag_pipe[0:SEARCH_BOARD_TAG_PIPE_LEN-1];
    BoardOp search_board_op_tag_pipe[0:SEARCH_BOARD_TAG_PIPE_LEN-1];
    PlyIndex search_board_ply_tag_pipe[0:SEARCH_BOARD_TAG_PIPE_LEN-1];
    ThreadID search_move_tag_pipe[0:SEARCH_MOVE_TAG_PIPE_LEN-1];
    logic search_move_in_check_pipe[0:SEARCH_MOVE_TAG_PIPE_LEN-1];
    ThreadID search_eval_tag_pipe[0:SEARCH_EVAL_TAG_PIPE_LEN-1];
    logic search_board_tag_valid_pipe[0:SEARCH_BOARD_TAG_PIPE_LEN-1];
    logic search_move_tag_valid_pipe[0:SEARCH_MOVE_TAG_PIPE_LEN-1];
    logic search_eval_tag_valid_pipe[0:SEARCH_EVAL_TAG_PIPE_LEN-1];
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
    FullBoard search_board[0:SEARCH_THREAD_COUNT-1];
    // Cache the side-to-move check status with each board so move dispatch does
    // not put the round-robin board mux in front of the full attack scan.
    logic search_board_in_check[0:SEARCH_THREAD_COUNT-1];
    ZobristKey search_zobrist_key[0:SEARCH_THREAD_COUNT-1];
    EvalScore search_pst_eval[0:SEARCH_THREAD_COUNT-1];
    SearchStackEntry search_stack_top[0:SEARCH_THREAD_COUNT-1];
    SearchStackEntry search_stack_parent_q[0:SEARCH_THREAD_COUNT-1];
    logic [$bits(SearchStackEntry)-1:0] search_stack_parent_bits[0:SEARCH_THREAD_COUNT-1];
    SearchStackRamAddr search_stack_read_addr[0:SEARCH_THREAD_COUNT-1];
    SearchStackRamAddr search_stack_write_addr[0:SEARCH_THREAD_COUNT-1];
    Move search_return_move[0:SEARCH_THREAD_COUNT-1];
    PlyIndex search_ply[0:SEARCH_THREAD_COUNT-1];
    SearchDepth search_target_depth;
    SearchDepth search_max_depth;
    SearchDepth search_completed_depth;
    Move search_completed_best_move;
    EvalScore search_completed_score;
    EvalScore search_root_alpha;
    EvalScore search_root_beta;
    logic search_aspiration_active;
`ifndef SYNTHESIS
    logic [7:0] search_thread_completed_depth[0:SEARCH_THREAD_COUNT-1];
    Move search_thread_completed_best_move[0:SEARCH_THREAD_COUNT-1];
`endif
    // Scheduler cursors select helper work after giving ready primary work priority.
    ThreadID search_thread_id;
    SearchDispatchCursors search_dispatch;
    SearchThreadMask search_ready_mask;
    SearchThreadMask search_store_mask;
    SearchThreadMask search_board_mask;
    SearchThreadMask search_move_mask;
    SearchThreadMask search_quiet_mask;
    SearchThreadMask search_eval_mask;
    SearchThreadMask search_tt_lookup_mask;
    SearchThreadMask search_return_mask;
    SearchThreadMask search_tt_response_mask;
    SearchThreadStatus search_thread_status[0:SEARCH_THREAD_COUNT-1];
    SearchThreadPhase search_thread_phase[0:SEARCH_THREAD_COUNT-1];
    ThreadCount search_active_thread_count;
    logic search_iteration_has_result;
    Move search_iteration_best_move;
    EvalScore search_iteration_best_score;
    EvalScore search_return_score[0:SEARCH_THREAD_COUNT-1];
    logic search_return_valid[0:SEARCH_THREAD_COUNT-1];
    logic search_return_was_scout[0:SEARCH_THREAD_COUNT-1];
    logic search_return_was_reduced[0:SEARCH_THREAD_COUNT-1];
    logic search_pvs_research[0:SEARCH_THREAD_COUNT-1];
    SearchDepth search_pending_child_depth[0:SEARCH_THREAD_COUNT-1];
    logic search_eval_is_stand_pat[0:SEARCH_THREAD_COUNT-1];
    logic terminal_result_valid_pipe;
    ThreadID terminal_result_thread_pipe;
    PlyIndex terminal_result_ply_pipe;
    EvalScore terminal_result_score_pipe;
`ifdef FPGA_CHESS_PROFILE
    // One-cycle semantic event used only by the external simulation profiler.
    logic profile_terminal_event;
    logic [1:0] profile_terminal_kind;
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
    EvalScore board_update_pst_in;
    Move board_update_move;
    logic [6:0] board_update_set_data;
    ThreadID board_update_thread_id;
    PlyIndex board_update_ply;
    FullBoard board_update_out;
    ZobristKey board_update_zobrist_out;
    EvalScore board_update_pst_out;
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
    logic move_cmd_suppress_valid;
    Move move_cmd_suppress_move;
    MoveBucketTops move_cmd_tops;
    logic move_cmd_resp_valid;
    ThreadID move_cmd_resp_thread;
    PlyIndex move_cmd_resp_ply;
    logic move_cmd_resp_direct_valid;
    Move move_cmd_resp_direct_move;
    MoveBucketTops move_cmd_resp_tops;
    logic move_quiet_cmd_valid;
    logic move_quiet_cmd_ready;
    ThreadID move_quiet_cmd_thread;
    PlyIndex move_quiet_cmd_ply;
    FullBoard move_quiet_cmd_board;
    logic move_quiet_cmd_suppress_valid;
    Move move_quiet_cmd_suppress_move;
    MoveBucketTops move_quiet_cmd_tops;
    logic move_quiet_resp_valid;
    ThreadID move_quiet_resp_thread;
    PlyIndex move_quiet_resp_ply;
    MoveBucketTops move_quiet_resp_tops;
    logic move_pop_valid;
    logic move_pop_ready;
    ThreadID move_pop_thread;
    PlyIndex move_pop_ply;
    MoveBucketMask move_pop_eligible;
    MoveBucketTops move_pop_current_tops;
    MoveBucketTops move_pop_lower_tops;
    logic move_pop_resp_valid;
    ThreadID move_pop_resp_thread;
    PlyIndex move_pop_resp_ply;
    logic move_pop_resp_found;
    Move move_pop_resp_move;
    MoveBucketIndex move_pop_resp_bucket;
    MoveBucketTop move_pop_resp_new_top;
    logic move_history_update_valid;
    logic move_history_update_ready;
    Color move_history_update_color;
    Position move_history_update_from;
    Position move_history_update_to;
    logic [5:0] move_history_update_depth;
    logic move_init_busy;
    logic move_overflow_sticky;
    ThreadID move_overflow_thread;
    MoveBucketIndex move_overflow_bucket;
    logic [15:0] move_overflow_count;
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
    logic [5:0] history_update_pending_depth[0:SEARCH_THREAD_COUNT-1];

    // Shared static-evaluator pipeline request and result signals.
    Tile eval_board_tiles[64];
    EvalScore eval_base;
    EvalScore static_eval_out;

    // Shared transposition-table frontend request and result signals.
    logic tt_clear;
    logic tt_clear_busy;
    logic tt_lookup_req_valid;
    logic tt_lookup_req_ready;
    TTLookupRequest tt_lookup_req;
    logic tt_lookup_resp_valid;
    TTLookupResponse tt_lookup_resp;
    logic tt_cache_access;
    logic tt_cache_hit;
    logic tt_cache_access_is_store;
    logic tt_store_req_valid;
    logic tt_store_req_ready;
    TTStoreRequest tt_store_req;
    TTAge tt_age;

    // Operation timer and scheduler-selected pipeline issues.
    logic timer_rst;
    logic timer_run;
    TimeType elapsed_ms;
    TimeType search_budget_ms;
    EngineControllerRequest setup_req_comb;
    logic search_board_issue_valid;
    logic search_move_issue_valid;
    logic search_quiet_issue_valid;
    logic search_eval_issue_valid;
    logic search_tt_lookup_issue_valid;
    logic search_tt_store_issue_valid;
    ThreadID search_board_issue_thread;
    ThreadID search_move_issue_thread;
    ThreadID search_quiet_issue_thread;
    ThreadID search_eval_issue_thread;
    ThreadID search_tt_lookup_issue_thread;
    ThreadID search_tt_store_issue_thread;
    logic move_board_bypass_valid;
    ThreadID move_board_bypass_thread;
    Move move_board_bypass_move;

    // Repetition checker request, response, and epoch state.
    localparam int REPETITION_EPOCH_BITS = 4;
    logic [REPETITION_EPOCH_BITS-1:0] repetition_epoch;
    logic repetition_init_start;
    logic repetition_init_busy;
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
    assign req_ready = (req_valid && req.operation == ENGINE_CTRL_KILL && state != ST_IDLE)
        || (state == ST_IDLE)
        || (state == ST_KILL_DONE);

    // Keep each thread in a separate one-dimensional RAM instance so both
    // Quartus and Vivado recognize the packed node records as block memory.
    genvar stack_tid;
    generate
        for (stack_tid = 0; stack_tid < SEARCH_THREAD_COUNT; stack_tid = stack_tid + 1) begin : gen_search_stack_ram
            assign search_stack_write_addr[stack_tid] = SearchStackRamAddr'(search_ply[stack_tid]);
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
        .move_in(board_update_move),
        .set_data(board_update_set_data),
        .thread_id(board_update_thread_id),
        .search_ply(board_update_ply),
        .board_out(board_update_out),
        .zobrist_key_out(board_update_zobrist_out),
        .pst_eval_out(board_update_pst_out),
        .mover_in_check_out(board_update_mover_in_check)
    );

    assign board_update_side_in_check = side_in_check(board_update_out);

    repetition_checker #(
        .SEARCH_THREAD_COUNT(SEARCH_THREAD_COUNT), .SEARCH_STACK_DEPTH(SEARCH_STACK_DEPTH),
        .ACTIVE_HISTORY_DEPTH(ACTIVE_REPETITION_DEPTH), .EPOCH_BITS(REPETITION_EPOCH_BITS)
    ) repetition_checker_inst (
        .clk(clk), .rst_n(rst_n), .flush(state == ST_KILL_DONE),
        .active_history_reset(repetition_history_reset), .active_history_write(repetition_history_write),
        .active_history_key(repetition_history_key), .init_start(repetition_init_start),
        .init_busy(repetition_init_busy), .init_done(repetition_init_done), .init_failed(repetition_init_failed),
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
        .ENABLE_STATS(ENABLE_SEARCH_STATS)
    ) move_generator (
        .clk(clk),
        .rst_n(rst_n),
        .clear(state == ST_NEW_CLEAR_START),
        .flush((req_valid && req.operation == ENGINE_CTRL_KILL && state != ST_IDLE)
            || state == ST_NEW_CLEAR_START),
        .init_busy(move_init_busy),
        .noisy_cmd_valid(move_cmd_valid), .noisy_cmd_ready(move_cmd_ready),
        .noisy_cmd(move_cmd),
        .noisy_cmd_thread(move_cmd_thread), .noisy_cmd_ply(move_cmd_ply),
        .noisy_cmd_board(move_cmd_board),
        .noisy_cmd_suppress_valid(move_cmd_suppress_valid),
        .noisy_cmd_suppress_move(move_cmd_suppress_move),
        .noisy_cmd_bucket_tops(move_cmd_tops),
        .noisy_resp_valid(move_cmd_resp_valid), .noisy_resp_thread(move_cmd_resp_thread),
        .noisy_resp_ply(move_cmd_resp_ply),
        .noisy_resp_direct_valid(move_cmd_resp_direct_valid),
        .noisy_resp_direct_move(move_cmd_resp_direct_move),
        .noisy_resp_bucket_tops(move_cmd_resp_tops),
        .quiet_cmd_valid(move_quiet_cmd_valid), .quiet_cmd_ready(move_quiet_cmd_ready),
        .quiet_cmd_thread(move_quiet_cmd_thread), .quiet_cmd_ply(move_quiet_cmd_ply),
        .quiet_cmd_board(move_quiet_cmd_board),
        .quiet_cmd_suppress_valid(move_quiet_cmd_suppress_valid),
        .quiet_cmd_suppress_move(move_quiet_cmd_suppress_move),
        .quiet_cmd_bucket_tops(move_quiet_cmd_tops),
        .quiet_resp_valid(move_quiet_resp_valid),
        .quiet_resp_thread(move_quiet_resp_thread), .quiet_resp_ply(move_quiet_resp_ply),
        .quiet_resp_bucket_tops(move_quiet_resp_tops),
        .pop_valid(move_pop_valid), .pop_ready(move_pop_ready),
        .pop_thread(move_pop_thread), .pop_ply(move_pop_ply), .pop_eligible(move_pop_eligible),
        .pop_current_tops(move_pop_current_tops), .pop_lower_tops(move_pop_lower_tops),
        .pop_resp_valid(move_pop_resp_valid), .pop_resp_thread(move_pop_resp_thread),
        .pop_resp_ply(move_pop_resp_ply), .pop_resp_found(move_pop_resp_found),
        .pop_resp_move(move_pop_resp_move), .pop_resp_bucket(move_pop_resp_bucket),
        .pop_resp_new_top(move_pop_resp_new_top),
        .history_update_valid(move_history_update_valid), .history_update_ready(move_history_update_ready),
        .history_update_color(move_history_update_color), .history_update_from(move_history_update_from),
        .history_update_to(move_history_update_to), .history_update_depth(move_history_update_depth),
        .overflow_sticky(move_overflow_sticky), .overflow_thread(move_overflow_thread),
        .overflow_bucket(move_overflow_bucket), .overflow_count(move_overflow_count),
        .stat_noisy_count(move_stat_noisy_count), .stat_quiet_count(move_stat_quiet_count),
        .stat_destination_count(move_stat_destination_count), .stat_candidate_count(move_stat_candidate_count),
        .stat_history_lookup_count(move_stat_history_lookup_count),
        .stat_generation_cycles(move_stat_generation_cycles),
        .stat_bucket_count(move_stat_bucket_count), .stat_bucket_high_water(move_stat_bucket_high_water)
    );

    generate
        if (EXTERNAL_TT) begin : external_tt_gen
            tt_external_load_store tt_load_store (
                .clk(clk), .rst_n(rst_n), .memory_ready(tt_memory_ready), .memory_error(tt_memory_error),
                .clear(tt_clear), .clear_busy(tt_clear_busy),
                .lookup_req_valid(tt_lookup_req_valid), .lookup_req_ready(tt_lookup_req_ready),
                .lookup_req(tt_lookup_req), .lookup_resp_valid(tt_lookup_resp_valid), .lookup_resp(tt_lookup_resp),
                .cache_access(tt_cache_access), .cache_hit(tt_cache_hit),
                .cache_access_is_store(tt_cache_access_is_store),
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
        end else begin : internal_tt_gen
            tt_load_store #(
                .TT_INDEX_BITS(TT_INDEX_BITS)
            ) tt_load_store (
                .clk(clk), .rst_n(rst_n), .clear(tt_clear), .clear_busy(tt_clear_busy),
                .lookup_req_valid(tt_lookup_req_valid), .lookup_req_ready(tt_lookup_req_ready),
                .lookup_req(tt_lookup_req), .lookup_resp_valid(tt_lookup_resp_valid), .lookup_resp(tt_lookup_resp),
                .cache_access(tt_cache_access), .cache_hit(tt_cache_hit),
                .cache_access_is_store(tt_cache_access_is_store),
                .store_req_valid(tt_store_req_valid), .store_req_ready(tt_store_req_ready), .store_req(tt_store_req));
            assign tt_mem_req_valid = 1'b0;
            assign tt_mem_req_write = 1'b0;
            assign tt_mem_req_address = '0;
            assign tt_mem_req_length = '0;
            assign tt_mem_write_valid = 1'b0;
            assign tt_mem_write_data = '0;
            assign tt_mem_write_last = 1'b0;
            assign tt_mem_read_ready = 1'b0;
            assign tt_mem_done_ready = 1'b0;
        end
    endgenerate

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
                end else if (state == ST_IDLE && req_valid
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
                    if (tt_cache_access && !tt_cache_access_is_store) begin
                        stat_cache_lookups <= stat_cache_lookups + 40'd1;
                        if (tt_cache_hit) stat_cache_hits <= stat_cache_hits + 40'd1;
                    end
                    if (state == ST_SEARCH_RUN) begin
                        stat_search_cycle <= stat_search_cycle + 40'd1;
                        for (int tid = 0; tid < SEARCH_THREAD_COUNT; tid++) begin
                            if (search_thread_phase[tid] >= SEARCH_PHASE_READY
                                    && search_thread_phase[tid] <= SEARCH_PHASE_DONE) begin
                                stat_phase_cycles[tid][search_thread_phase[tid] - SEARCH_PHASE_READY]
                                    <= stat_phase_cycles[tid][search_thread_phase[tid] - SEARCH_PHASE_READY] + 40'd1;
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
            ENGINE_STAT_MOVE_OVERFLOWS:   debug_stat_value = {24'd0, move_overflow_count};
            ENGINE_STAT_MOVE_OVERFLOW_ID: debug_stat_value = {
                32'd0, move_overflow_sticky, move_overflow_thread, move_overflow_bucket
            };
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

    timer #(
        .CLOCK_FREQ(CLOCK_FREQ)
    ) search_timer (
        .clk(clk),
        .rst(timer_rst),
        .run(timer_run),
        .time_ms(elapsed_ms)
    );

    static_evaluator static_evaluator (
        .clk(clk),
        .board_tiles(eval_board_tiles),
        .base_eval(eval_base),
        .static_eval(static_eval_out)
    );

    function automatic logic is_null_move(input Move move);
        return move.from_pos == Position'(0) && move.to_pos == Position'(0);
    endfunction : is_null_move

    function automatic logic is_direct_setup_op(input BoardOp op);
        return op == BOARD_SET_TILE_OP
            || op == BOARD_SET_TURN_OP
            || op == BOARD_SET_CASTLE_PERMS_OP
            || op == BOARD_SET_EN_PASSANT_OP
            || op == BOARD_SET_HALFMOVE_CLOCK_OP;
    endfunction : is_direct_setup_op

    function automatic logic is_line_attacker(input PieceType piece, input Direction dir);
        return (piece == QUEEN || (piece == ROOK && isDirCardinal(dir)) || (piece == BISHOP && isDirDiag(dir)));
    endfunction : is_line_attacker

    function automatic Position find_king(input FullBoard board, input Color king_color);
        automatic Position king_pos;

        // A legal chess board has exactly one king of each colour. OR-ing the
        // matching square indices lets synthesis use a balanced reduction
        // instead of a 64-entry priority mux.
        king_pos = Position'(0);
        for (int pos = 0; pos < 64; pos++) begin
            if (board.tiles[pos] == Tile'({king_color, KING})) begin
                king_pos |= Position'(pos);
            end
        end
        return king_pos;
    endfunction : find_king

    function automatic logic square_attacked(input FullBoard board, input Position square, input Color attacker_color);
        automatic Position test_pos;
        automatic Tile test_tile;

        if (attacker_color == WHITE) begin
            if (isShiftOnBoard(square, SOUTH_WEST, 3'd1)
                    && board.tiles[shiftPos(square, SOUTH_WEST, 3'd1)] == WHITE_PAWN) return 1'b1;
            if (isShiftOnBoard(square, SOUTH_EAST, 3'd1)
                    && board.tiles[shiftPos(square, SOUTH_EAST, 3'd1)] == WHITE_PAWN) return 1'b1;
        end else begin
            if (isShiftOnBoard(square, NORTH_WEST, 3'd1)
                    && board.tiles[shiftPos(square, NORTH_WEST, 3'd1)] == BLACK_PAWN) return 1'b1;
            if (isShiftOnBoard(square, NORTH_EAST, 3'd1)
                    && board.tiles[shiftPos(square, NORTH_EAST, 3'd1)] == BLACK_PAWN) return 1'b1;
        end

        for (int knight_dir = 0; knight_dir < 8; knight_dir++) begin
            if (isKnightShiftOnBoard(square, KnightDirection'(knight_dir))) begin
                test_pos = shiftKnightPos(square, KnightDirection'(knight_dir));
                if (board.tiles[test_pos] == Tile'({attacker_color, KNIGHT})) return 1'b1;
            end
        end

        for (int dir_idx = 0; dir_idx < 8; dir_idx++) begin
            automatic Direction dir = Direction'(dir_idx);
            for (int distance = 1; distance < 8; distance++) begin
                if (isShiftOnBoard(square, dir, distance[2:0])) begin
                    test_pos = shiftPos(square, dir, distance[2:0]);
                    test_tile = board.tiles[test_pos];
                    if (test_tile.piece_type != NULL_PIECE) begin
                        if (test_tile.piece_color == attacker_color) begin
                            if (distance == 1 && test_tile.piece_type == KING) return 1'b1;
                            if (is_line_attacker(test_tile.piece_type, dir)) return 1'b1;
                        end
                        break;
                    end
                end
            end
        end

        return 1'b0;
    endfunction : square_attacked

    function automatic logic side_in_check(input FullBoard board);
        return square_attacked(board, find_king(board, board.turn), Color'(~board.turn));
    endfunction : side_in_check

    function automatic logic committed_move_is_irreversible(
        input FullBoard before_board,
        input FullBoard after_board,
        input Move move
    );
        automatic Tile start_tile;
        automatic Tile end_tile;

        start_tile = before_board.tiles[move.from_pos];
        end_tile = before_board.tiles[move.to_pos];
        return start_tile.piece_type == PAWN
            || end_tile.piece_type != NULL_PIECE
            || before_board.castle_perms != after_board.castle_perms;
    endfunction : committed_move_is_irreversible

    function automatic EvalScore terminal_no_move_score(input logic in_check, input PlyIndex ply);
        if (in_check) begin
            return EvalScore'(int'(ply) - int'(MATE_SCORE));
        end
        return DRAW_EVAL_SCORE;
    endfunction : terminal_no_move_score

    function automatic Tile start_tile(input int pos);
        case (pos)
            0: return WHITE_ROOK;
            1: return WHITE_KNIGHT;
            2: return WHITE_BISHOP;
            3: return WHITE_QUEEN;
            4: return WHITE_KING;
            5: return WHITE_BISHOP;
            6: return WHITE_KNIGHT;
            7: return WHITE_ROOK;
            8, 9, 10, 11, 12, 13, 14, 15: return WHITE_PAWN;
            48, 49, 50, 51, 52, 53, 54, 55: return BLACK_PAWN;
            56: return BLACK_ROOK;
            57: return BLACK_KNIGHT;
            58: return BLACK_BISHOP;
            59: return BLACK_QUEEN;
            60: return BLACK_KING;
            61: return BLACK_BISHOP;
            62: return BLACK_KNIGHT;
            63: return BLACK_ROOK;
            default: return EMPTY_TILE;
        endcase
    endfunction : start_tile

    function automatic logic [3:0] start_tile_bits(input int pos);
        automatic Tile tile;

        tile = start_tile(pos);
        if (tile.piece_type == NULL_PIECE) begin
            return 4'h0;
        end
        return tile;
    endfunction : start_tile_bits

    function automatic EngineControllerRequest new_game_setup_request(input logic [6:0] idx);
        automatic EngineControllerRequest setup_req;

        setup_req = EngineControllerRequest'('0);
        setup_req.operation = ENGINE_CTRL_DIRECT_BOARD;
        setup_req.direct_board_op = BOARD_IDLE_OP;
        if (idx < 7'd64) begin
            setup_req.direct_board_op = BOARD_SET_TILE_OP;
            setup_req.move.to_pos = Position'(idx[5:0]);
            setup_req.board_wr_data = {3'b000, start_tile_bits(int'(idx))};
        end else if (idx == 7'd64) begin
            setup_req.direct_board_op = BOARD_SET_CASTLE_PERMS_OP;
            setup_req.board_wr_data = 7'b000_1111;
        end else if (idx == 7'd65) begin
            setup_req.direct_board_op = BOARD_SET_EN_PASSANT_OP;
            setup_req.board_wr_data = 7'd0;
        end else if (idx == 7'd66) begin
            setup_req.direct_board_op = BOARD_SET_TURN_OP;
            setup_req.board_wr_data = 7'd0;
        end else begin
            setup_req.direct_board_op = BOARD_SET_HALFMOVE_CLOCK_OP;
            setup_req.board_wr_data = 7'd0;
        end
        return setup_req;
    endfunction : new_game_setup_request

    function automatic TimeType clock_budget(input EngineControllerRequest request);
        automatic TimeType stm_time;
        automatic TimeType stm_inc;
        automatic TimeType usable;
        automatic logic [TIME_BITS+1:0] increment_scaled;
        automatic logic [TIME_BITS:0] budget;

        stm_time = (active_board.turn == WHITE) ? request.wtime : request.btime;
        stm_inc = (active_board.turn == WHITE) ? request.winc : request.binc;
        usable = (stm_time > TimeType'(20)) ? (stm_time - TimeType'(20)) : TimeType'(0);
        // Spend the documented target share of both the increment and remaining
        // clock so increment games do not consistently finish with excess time.
        increment_scaled = {2'b00, stm_inc} * 2'd3;
        budget = (increment_scaled >> 2) + {1'b0, (usable >> 5)};
        if (budget > {1'b0, usable}) begin
            return usable;
        end
        if (budget != '0 && budget < TimeType'(10)) begin
            return (usable < TimeType'(10)) ? usable : TimeType'(10);
        end
        return TimeType'(budget);
    endfunction : clock_budget

    function automatic EvalScore pov_eval(input FullBoard board, input EvalScore white_relative_eval);
        return (board.turn == WHITE) ? white_relative_eval : -white_relative_eval;
    endfunction : pov_eval

    // Clamp aspiration bounds before narrowing them to the score representation.
    function automatic EvalScore aspiration_lower_bound(input EvalScore score);
        automatic integer bound;
        bound = int'(score) - int'(ASPIRATION_DELTA);
        return (bound <= -SEARCH_INF_VALUE) ? -SEARCH_INF : EvalScore'(bound);
    endfunction : aspiration_lower_bound

    function automatic EvalScore aspiration_upper_bound(input EvalScore score);
        automatic integer bound;
        bound = int'(score) + int'(ASPIRATION_DELTA);
        return (bound >= SEARCH_INF_VALUE) ? SEARCH_INF : EvalScore'(bound);
    endfunction : aspiration_upper_bound

    // Every newly entered node starts from the same empty search record.
    function automatic SearchStackEntry empty_search_stack_entry();
        automatic SearchStackEntry entry;
        entry.move = NULL_MOVE;
        entry.best_move = NULL_MOVE;
        entry.best_score = -SEARCH_INF;
        entry.alpha = -SEARCH_INF;
        entry.orig_alpha = -SEARCH_INF;
        entry.beta = SEARCH_INF;
        entry.tt_move = NULL_MOVE;
        entry.bucket_tops = MoveBucketTops'(0);
        entry.repetition_start = PlyIndex'(0);
        entry.remaining_depth = SearchDepth'(0);
        entry.legal_move_count = 8'd0;
        entry.move_order_state = MOVE_ORDER_DIRECT;
        entry.direct_attempted = 1'b0;
        entry.has_legal = 1'b0;
        entry.tt_checked = 1'b0;
        entry.has_tt_move = 1'b0;
        entry.stand_pat_done = 1'b0;
        entry.scout_search = 1'b0;
        entry.count_move_on_return = 1'b0;
        return entry;
    endfunction : empty_search_stack_entry

    function automatic logic search_stop_requested();
        if (active_req.operation == ENGINE_CTRL_SEARCH_NODES && search_nodes >= active_req.node_limit) begin
            return 1'b1;
        end
        if ((active_req.operation == ENGINE_CTRL_SEARCH_FIXED_TIME || active_req.operation == ENGINE_CTRL_SEARCH_ON_CLOCK)
                && elapsed_ms >= search_budget_ms) begin
            return 1'b1;
        end
        return 1'b0;
    endfunction : search_stop_requested

    function automatic logic search_in_qsearch(input ThreadID thread);
        return search_stack_top[thread].remaining_depth == SearchDepth'(0);
    endfunction : search_in_qsearch

    // Constant-folded Q8 approximation used to populate the small LMR ROM.
    function automatic logic [7:0] lmr_table_value_for_params(
        input longint unsigned a_q8,
        input longint unsigned b_q8,
        input int depth_bucket,
        input int move_bucket
    );
        automatic longint unsigned numerator;
        automatic longint unsigned reduction_q8;
        automatic longint unsigned rounded;
        numerator = longint'(LMR_LN2_Q8) * longint'(LMR_LN2_Q8)
            * longint'(depth_bucket) * longint'(move_bucket);
        // Round the complete rational expression once, rather than rounding
        // the logarithmic term separately before adding A.
        if (b_q8 == 0) return 8'd0;
        reduction_q8 = a_q8 * b_q8 + numerator;
        rounded = (reduction_q8 + (longint'(128) * b_q8)) / (longint'(256) * b_q8);
        return rounded > 255 ? 8'hff : 8'(rounded);
    endfunction : lmr_table_value_for_params

    function automatic logic [7:0] lmr_table_value(input int depth_bucket, input int move_bucket);
        return lmr_table_value_for_params(LMR_A_Q8, LMR_B_Q8, depth_bucket, move_bucket);
    endfunction : lmr_table_value

    function automatic logic [2:0] floor_log2_8(input logic [7:0] value);
        for (int bit_index = 7; bit_index >= 0; bit_index--)
            if (value[bit_index]) return 3'(bit_index);
        return 3'd0;
    endfunction : floor_log2_8

    function automatic logic [7:0] max_raw_lmr_table_value();
        automatic logic [7:0] maximum;
        maximum = 8'd0;
        for (int depth_bucket = 0; depth_bucket < LMR_DEPTH_BUCKETS; depth_bucket++)
            for (int move_bucket = 0; move_bucket < 8; move_bucket++)
                if (lmr_table_value(depth_bucket, move_bucket) > maximum)
                    maximum = lmr_table_value(depth_bucket, move_bucket);
        return maximum;
    endfunction : max_raw_lmr_table_value

    localparam logic [7:0] LMR_TABLE_MAX_VALUE = max_raw_lmr_table_value();
    localparam int LMR_TABLE_VALUE_BITS = (LMR_TABLE_MAX_VALUE <= 1)
        ? 1 : $clog2(LMR_TABLE_MAX_VALUE + 1);
    // A case lookup gives every simulator and synthesis tool the same
    // constant-folded table without runtime logarithms, multiplication, or
    // division. Depth buckets above five are unreachable with MAX_PLY_COUNT=64.
    function automatic SearchDepth lmr_reduction(
        input logic [2:0] depth_bucket,
        input logic [2:0] move_bucket
    );
        case ({depth_bucket, move_bucket})
            6'o00: return SearchDepth'(lmr_table_value(0, 0));
            6'o01: return SearchDepth'(lmr_table_value(0, 1));
            6'o02: return SearchDepth'(lmr_table_value(0, 2));
            6'o03: return SearchDepth'(lmr_table_value(0, 3));
            6'o04: return SearchDepth'(lmr_table_value(0, 4));
            6'o05: return SearchDepth'(lmr_table_value(0, 5));
            6'o06: return SearchDepth'(lmr_table_value(0, 6));
            6'o07: return SearchDepth'(lmr_table_value(0, 7));
            6'o10: return SearchDepth'(lmr_table_value(1, 0));
            6'o11: return SearchDepth'(lmr_table_value(1, 1));
            6'o12: return SearchDepth'(lmr_table_value(1, 2));
            6'o13: return SearchDepth'(lmr_table_value(1, 3));
            6'o14: return SearchDepth'(lmr_table_value(1, 4));
            6'o15: return SearchDepth'(lmr_table_value(1, 5));
            6'o16: return SearchDepth'(lmr_table_value(1, 6));
            6'o17: return SearchDepth'(lmr_table_value(1, 7));
            6'o20: return SearchDepth'(lmr_table_value(2, 0));
            6'o21: return SearchDepth'(lmr_table_value(2, 1));
            6'o22: return SearchDepth'(lmr_table_value(2, 2));
            6'o23: return SearchDepth'(lmr_table_value(2, 3));
            6'o24: return SearchDepth'(lmr_table_value(2, 4));
            6'o25: return SearchDepth'(lmr_table_value(2, 5));
            6'o26: return SearchDepth'(lmr_table_value(2, 6));
            6'o27: return SearchDepth'(lmr_table_value(2, 7));
            6'o30: return SearchDepth'(lmr_table_value(3, 0));
            6'o31: return SearchDepth'(lmr_table_value(3, 1));
            6'o32: return SearchDepth'(lmr_table_value(3, 2));
            6'o33: return SearchDepth'(lmr_table_value(3, 3));
            6'o34: return SearchDepth'(lmr_table_value(3, 4));
            6'o35: return SearchDepth'(lmr_table_value(3, 5));
            6'o36: return SearchDepth'(lmr_table_value(3, 6));
            6'o37: return SearchDepth'(lmr_table_value(3, 7));
            6'o40: return SearchDepth'(lmr_table_value(4, 0));
            6'o41: return SearchDepth'(lmr_table_value(4, 1));
            6'o42: return SearchDepth'(lmr_table_value(4, 2));
            6'o43: return SearchDepth'(lmr_table_value(4, 3));
            6'o44: return SearchDepth'(lmr_table_value(4, 4));
            6'o45: return SearchDepth'(lmr_table_value(4, 5));
            6'o46: return SearchDepth'(lmr_table_value(4, 6));
            6'o47: return SearchDepth'(lmr_table_value(4, 7));
            6'o50: return SearchDepth'(lmr_table_value(5, 0));
            6'o51: return SearchDepth'(lmr_table_value(5, 1));
            6'o52: return SearchDepth'(lmr_table_value(5, 2));
            6'o53: return SearchDepth'(lmr_table_value(5, 3));
            6'o54: return SearchDepth'(lmr_table_value(5, 4));
            6'o55: return SearchDepth'(lmr_table_value(5, 5));
            6'o56: return SearchDepth'(lmr_table_value(5, 6));
            6'o57: return SearchDepth'(lmr_table_value(5, 7));
            default: return SearchDepth'(0);
        endcase
    endfunction : lmr_reduction
    generate
        if (LMR_B_Q8 == 0) begin : gen_invalid_lmr_denominator
            initial $fatal(1, "LMR_B_Q8 must be nonzero");
        end
        if (LMR_TABLE_VALUE_BITS > SEARCH_DEPTH_BITS) begin : gen_oversized_lmr_table_value
            initial $fatal(1, "LMR table value does not fit SearchDepth");
        end
    endgenerate

    function automatic SearchDepth lmr_child_depth(input ThreadID thread);
        automatic SearchDepth depth;
        automatic logic [7:0] move_index;
        automatic SearchDepth reduction;
        automatic logic [2:0] depth_bucket;
        depth = search_stack_top[thread].remaining_depth;
        move_index = search_stack_top[thread].legal_move_count == 8'hff
            ? 8'hff : search_stack_top[thread].legal_move_count + 8'd1;
        depth_bucket = floor_log2_8(depth);
        reduction = lmr_reduction(depth_bucket, floor_log2_8(move_index));
        if (reduction >= depth) reduction = depth - SearchDepth'(1);
        return depth - SearchDepth'(1) - reduction;
    endfunction : lmr_child_depth

    // LMR deliberately has no tactical move classification: every main-search
    // move follows the same eligibility policy.
    function automatic logic lmr_eligible(
        input PlyIndex ply,
        input SearchDepth remaining_depth,
        input logic [7:0] legal_move_count,
        input logic is_research
    );
        return ply != PlyIndex'(0) && remaining_depth >= SearchDepth'(3)
            && legal_move_count >= 8'd2 && !is_research;
    endfunction : lmr_eligible

    function automatic logic search_needs_research(
        input logic was_scout,
        input logic was_reduced,
        input EvalScore score,
        input EvalScore alpha,
        input EvalScore beta
    );
        // Every alpha-raising reduced scout is verified at full depth, including
        // apparent beta cutoffs. Ordinary PVS scouts retain cutoff behavior.
        return was_scout && score > alpha && (score < beta || was_reduced);
    endfunction : search_needs_research

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
        return search_thread_status[thread_index] == SEARCH_THREAD_ACTIVE
            && search_thread_phase[thread_index] == SEARCH_PHASE_READY;
    endfunction : search_thread_ready

    function automatic logic search_thread_store_pending(input int thread_index);
        return search_thread_status[thread_index] == SEARCH_THREAD_ACTIVE
            && search_thread_phase[thread_index] == SEARCH_PHASE_STORE_PUBLISH
            && search_tt_store_inflight[thread_index];
    endfunction : search_thread_store_pending

    function automatic logic search_thread_store_complete(input int thread_index);
        return search_thread_status[thread_index] == SEARCH_THREAD_ACTIVE
            && search_thread_phase[thread_index] == SEARCH_PHASE_STORE_PUBLISH
            && search_tt_store_inflight[thread_index]
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
        return search_thread_status[thread_index] == SEARCH_THREAD_ACTIVE
            && search_thread_phase[thread_index] == SEARCH_PHASE_MOVE_WAIT
            && search_return_valid[thread_index]
            && !search_move_inflight[thread_index];
    endfunction : search_thread_return_pending

    function automatic logic search_thread_tt_response_pending(input int thread_index);
        return search_thread_status[thread_index] == SEARCH_THREAD_ACTIVE
            && search_thread_phase[thread_index] == SEARCH_PHASE_TT_WAIT
            && search_tt_response_pending[thread_index]
            && !search_tt_lookup_inflight[thread_index];
    endfunction : search_thread_tt_response_pending

    function automatic logic search_thread_board_pending(input int thread_index);
        return search_thread_status[thread_index] == SEARCH_THREAD_ACTIVE
            && search_thread_phase[thread_index] == SEARCH_PHASE_BOARD_WAIT
            && !search_board_inflight[thread_index];
    endfunction : search_thread_board_pending

    function automatic logic search_thread_reverse_pending(input int thread_index);
        return search_thread_status[thread_index] == SEARCH_THREAD_ACTIVE
            && search_thread_phase[thread_index] == SEARCH_PHASE_REVERSE_WAIT
            && !search_board_inflight[thread_index];
    endfunction : search_thread_reverse_pending

    function automatic logic search_thread_terminal_draw_ready(input int thread_index);
        return search_thread_status[thread_index] == SEARCH_THREAD_ACTIVE
            && search_thread_phase[thread_index] == SEARCH_PHASE_READY
            && search_board[thread_index].halfmove_clock >= HalfmoveClock'(100);
    endfunction : search_thread_terminal_draw_ready

    function automatic logic search_thread_tt_lookup_ready(input int thread_index);
        return search_thread_status[thread_index] == SEARCH_THREAD_ACTIVE
            && search_thread_phase[thread_index] == SEARCH_PHASE_READY
            && !search_thread_terminal_draw_ready(thread_index)
            && !search_in_qsearch(ThreadID'(thread_index))
            && !search_stack_top[thread_index].tt_checked
            && should_probe_search_tt(ThreadID'(thread_index), search_ply[thread_index])
            && !search_tt_lookup_inflight[thread_index];
    endfunction : search_thread_tt_lookup_ready

    function automatic logic search_thread_eval_ready(input int thread_index);
        return search_thread_status[thread_index] == SEARCH_THREAD_ACTIVE
            && search_thread_phase[thread_index] == SEARCH_PHASE_READY
            && !search_thread_terminal_draw_ready(thread_index)
            && !search_thread_tt_lookup_ready(thread_index)
            && !search_eval_inflight[thread_index]
            && ((search_in_qsearch(ThreadID'(thread_index))
                    && !search_stack_top[thread_index].stand_pat_done)
                || int'(search_ply[thread_index]) >= SEARCH_STACK_DEPTH - 1);
    endfunction : search_thread_eval_ready

    function automatic logic search_thread_move_issue_ready(input int thread_index);
        automatic MoveOrderState order_state = search_stack_top[thread_index].move_order_state;
        return search_thread_status[thread_index] == SEARCH_THREAD_ACTIVE
            && search_thread_phase[thread_index] == SEARCH_PHASE_READY
            && !search_thread_terminal_draw_ready(thread_index)
            && !search_thread_tt_lookup_ready(thread_index)
            && !search_thread_eval_ready(thread_index)
            && search_stack_top[thread_index].move_order_state != MOVE_ORDER_DONE
            && order_state != MOVE_ORDER_GENERATE_QUIET
            && ((order_state != MOVE_ORDER_DIRECT
                    && order_state != MOVE_ORDER_GENERATE_NOISY)
                || move_cmd_ready)
            && !search_move_inflight[thread_index];
    endfunction : search_thread_move_issue_ready

    function automatic logic search_thread_quiet_issue_ready(input int thread_index);
        return search_thread_status[thread_index] == SEARCH_THREAD_ACTIVE
            && search_thread_phase[thread_index] == SEARCH_PHASE_READY
            && !search_thread_terminal_draw_ready(thread_index)
            && !search_thread_tt_lookup_ready(thread_index)
            && !search_thread_eval_ready(thread_index)
            && search_stack_top[thread_index].move_order_state == MOVE_ORDER_GENERATE_QUIET
            && move_quiet_cmd_ready
            && !search_move_inflight[thread_index];
    endfunction : search_thread_quiet_issue_ready

    function automatic logic should_probe_search_tt(input ThreadID thread, input PlyIndex ply);
        return !(ply == PlyIndex'(0) && thread != ThreadID'(0));
    endfunction : should_probe_search_tt

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
        if (search_stack_top[thread].has_tt_move)
            return search_stack_top[thread].tt_move;
        if (search_ply[thread] == PlyIndex'(0) && !search_in_qsearch(thread))
            return root_hint_for_thread(thread);
        return NULL_MOVE;
    endfunction : ordering_move_for_thread

    function automatic logic move_state_uses_pop(input MoveOrderState move_state);
        return move_state == MOVE_ORDER_GOOD_NOISY
            || move_state == MOVE_ORDER_QUIET
            || move_state == MOVE_ORDER_BAD_NOISY;
    endfunction : move_state_uses_pop

    function automatic logic move_tiebreak_less(input Move candidate, input Move current);
        if (is_null_move(current)) begin
            return !is_null_move(candidate);
        end
        if (candidate.from_pos != current.from_pos) begin
            return candidate.from_pos < current.from_pos;
        end
        if (candidate.to_pos != current.to_pos) begin
            return candidate.to_pos < current.to_pos;
        end
        return candidate.promo_piece < current.promo_piece;
    endfunction : move_tiebreak_less

    // History applies only to ordinary non-captures and castling. Promotions
    // and the empty-destination pawn diagonal used by en passant are noisy.
    function automatic logic is_quiet_move(input FullBoard board, input Move move);
        automatic Tile source_tile;
        automatic Tile destination_tile;
        automatic logic pawn_promotion;
        automatic logic pawn_diagonal;

        source_tile = board.tiles[move.from_pos];
        destination_tile = board.tiles[move.to_pos];
        pawn_promotion = source_tile.piece_type == PAWN
            && (move.to_pos[5:3] == BoardRank'(0) || move.to_pos[5:3] == BoardRank'(7));
        pawn_diagonal = source_tile.piece_type == PAWN
            && move.from_pos[2:0] != move.to_pos[2:0];
        return destination_tile.piece_type == NULL_PIECE && !pawn_promotion && !pawn_diagonal;
    endfunction : is_quiet_move

    function automatic logic root_result_better(
        input ThreadID thread,
        input EvalScore candidate_score,
        input Move candidate_move,
        input logic has_current,
        input EvalScore current_score,
        input Move current_move
    );
        return thread == ThreadID'(0) && (!has_current
            || candidate_score > current_score
            || (candidate_score == current_score && move_tiebreak_less(candidate_move, current_move)));
    endfunction : root_result_better

    function automatic TTDepth search_remaining_depth(input ThreadID thread);
        return TTDepth'(search_stack_top[thread].remaining_depth);
    endfunction : search_remaining_depth

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

    always_comb begin
        setup_req_comb = new_game_setup_request(new_setup_index);
        search_ready_mask = '0;
        search_store_mask = '0;
        search_board_mask = '0;
        search_move_mask = '0;
        search_quiet_mask = '0;
        search_eval_mask = '0;
        search_tt_lookup_mask = '0;
        search_return_mask = '0;
        search_tt_response_mask = '0;
        for (int idx = 0; idx < SEARCH_THREAD_COUNT; idx++) begin
            search_ready_mask[idx] = search_thread_ready(idx);
            search_store_mask[idx] = search_thread_store_pending(idx);
            search_board_mask[idx] = search_thread_board_pending(idx)
                || search_thread_reverse_pending(idx);
            search_move_mask[idx] = search_thread_move_issue_ready(idx);
            search_quiet_mask[idx] = search_thread_quiet_issue_ready(idx);
            search_eval_mask[idx] = search_thread_eval_ready(idx);
            search_tt_lookup_mask[idx] = search_thread_tt_lookup_ready(idx);
            search_return_mask[idx] = search_thread_return_pending(idx);
            search_tt_response_mask[idx] = search_thread_tt_response_pending(idx);
        end
        move_board_bypass_valid = state == ST_SEARCH_RUN
            && ((move_pop_resp_valid && move_pop_resp_found)
                || (move_cmd_resp_valid && move_cmd_resp_direct_valid));
        move_board_bypass_thread = move_pop_resp_valid && move_pop_resp_found
            ? move_pop_resp_thread : move_cmd_resp_thread;
        move_board_bypass_move = move_pop_resp_valid && move_pop_resp_found
            ? move_pop_resp_move : move_cmd_resp_direct_move;
        search_board_issue_valid = (state == ST_SEARCH_RUN)
            && (move_board_bypass_valid
                || |search_board_mask);
        search_move_issue_valid = (state == ST_SEARCH_RUN)
            && |search_move_mask;
        search_quiet_issue_valid = (state == ST_SEARCH_RUN)
            && |search_quiet_mask;
        search_eval_issue_valid = (state == ST_SEARCH_RUN)
            && |search_eval_mask;
        search_tt_lookup_issue_valid = (state == ST_SEARCH_RUN)
            && |search_tt_lookup_mask;
        search_tt_store_issue_valid = (state == ST_SEARCH_RUN)
            && |search_store_mask;
        search_board_issue_thread = search_board_issue_valid
            ? move_board_bypass_valid
                ? move_board_bypass_thread
                : search_select_thread(search_board_mask, search_dispatch.board)
            : ThreadID'(0);
        search_move_issue_thread = search_move_issue_valid
            ? search_select_thread(search_move_mask, search_dispatch.move)
            : ThreadID'(0);
        search_quiet_issue_thread = search_quiet_issue_valid
            ? search_select_thread(search_quiet_mask, search_dispatch.quiet)
            : ThreadID'(0);
        search_eval_issue_thread = search_eval_issue_valid
            ? search_select_thread(search_eval_mask, search_dispatch.eval)
            : ThreadID'(0);
        search_tt_lookup_issue_thread = search_tt_lookup_issue_valid
            ? search_select_thread(search_tt_lookup_mask, search_dispatch.tt_lookup)
            : ThreadID'(0);
        search_tt_store_issue_thread = search_tt_store_issue_valid
            ? search_select_thread(search_store_mask, search_dispatch.tt_store)
            : ThreadID'(0);

        board_update_op = BOARD_IDLE_OP;
        board_update_in = active_board;
        board_update_zobrist_in = active_zobrist_key;
        board_update_pst_in = active_pst_eval;
        board_update_move = active_req.move;
        board_update_set_data = active_req.board_wr_data;
        board_update_thread_id = (state == ST_SEARCH_RUN) ? search_board_issue_thread : ThreadID'(0);
        board_update_ply = PlyIndex'(0);

        if (state == ST_BOARD_ISSUE) begin
            board_update_op = active_req.direct_board_op;
        end else if (state == ST_NEW_SETUP_ISSUE) begin
            board_update_op = setup_req_comb.direct_board_op;
            board_update_move = setup_req_comb.move;
            board_update_set_data = setup_req_comb.board_wr_data;
        end else if (state == ST_PERFT_GEN_WAIT
                && move_pop_resp_valid && move_pop_resp_thread == ThreadID'(0)
                && move_pop_resp_found) begin
            board_update_op = BOARD_PUSH_MOVE_OP;
            board_update_in = search_board[0];
            board_update_zobrist_in = search_zobrist_key[0];
            board_update_pst_in = search_pst_eval[0];
            board_update_move = move_pop_resp_move;
            board_update_ply = search_ply[0];
        end else if (state == ST_PERFT_PUSH_ISSUE || state == ST_PERFT_REVERSE_ISSUE) begin
            board_update_op = (state == ST_PERFT_REVERSE_ISSUE) ? BOARD_REVERSE_MOVE_OP : BOARD_PUSH_MOVE_OP;
            // Perft serially borrows search context zero instead of owning a duplicate position.
            board_update_in = search_board[0];
            board_update_zobrist_in = search_zobrist_key[0];
            board_update_pst_in = search_pst_eval[0];
            board_update_move = search_pending_move[0];
            board_update_ply = search_ply[0];
        end else if (search_board_issue_valid) begin
            board_update_op = !move_board_bypass_valid
                    && search_thread_phase[search_board_issue_thread] == SEARCH_PHASE_REVERSE_WAIT
                ? BOARD_REVERSE_MOVE_OP : BOARD_PUSH_MOVE_OP;
            board_update_in = search_board[search_board_issue_thread];
            board_update_zobrist_in = search_zobrist_key[search_board_issue_thread];
            board_update_pst_in = search_pst_eval[search_board_issue_thread];
            board_update_move = move_board_bypass_valid
                ? move_board_bypass_move : search_pending_move[search_board_issue_thread];
            board_update_ply = search_ply[search_board_issue_thread];
        end

        move_cmd_valid = 1'b0;
        move_cmd = MOVE_GEN_GENERATE_NOISY;
        move_cmd_thread = ThreadID'(0);
        move_cmd_ply = PlyIndex'(0);
        move_cmd_board = active_board;
        move_cmd_suppress_valid = 1'b0;
        move_cmd_suppress_move = NULL_MOVE;
        move_cmd_tops = MoveBucketTops'(0);
        move_quiet_cmd_valid = 1'b0;
        move_quiet_cmd_thread = ThreadID'(0);
        move_quiet_cmd_ply = PlyIndex'(0);
        move_quiet_cmd_board = active_board;
        move_quiet_cmd_suppress_valid = 1'b0;
        move_quiet_cmd_suppress_move = NULL_MOVE;
        move_quiet_cmd_tops = MoveBucketTops'(0);
        move_pop_valid = 1'b0;
        move_pop_thread = ThreadID'(0);
        move_pop_ply = PlyIndex'(0);
        move_pop_eligible = MoveBucketMask'(0);
        move_pop_current_tops = MoveBucketTops'(0);
        move_pop_lower_tops = MoveBucketTops'(0);
        move_history_update_valid = 1'b0;
        move_history_update_color = WHITE;
        move_history_update_from = Position'(0);
        move_history_update_to = Position'(0);
        move_history_update_depth = 6'd0;
        for (int idx = 0; idx < SEARCH_THREAD_COUNT; idx++) begin
            if (!move_history_update_valid && history_update_pending[idx]) begin
                move_history_update_valid = 1'b1;
                move_history_update_color = history_update_pending_color[idx];
                move_history_update_from = history_update_pending_from[idx];
                move_history_update_to = history_update_pending_to[idx];
                move_history_update_depth = history_update_pending_depth[idx];
            end
        end

        if (state == ST_PERFT_GEN_ISSUE) begin
            move_cmd_thread = ThreadID'(0);
            move_cmd_ply = search_ply[0];
            move_cmd_board = search_board[0];
            move_cmd_tops = search_stack_top[0].bucket_tops;
            move_pop_thread = ThreadID'(0);
            move_pop_ply = search_ply[0];
            move_pop_current_tops = search_stack_top[0].bucket_tops;
            move_pop_lower_tops = search_ply[0] == PlyIndex'(0)
                ? MoveBucketTops'(0) : search_stack_parent_q[0].bucket_tops;
            case (search_stack_top[0].move_order_state)
                MOVE_ORDER_GENERATE_NOISY: begin
                    move_cmd = MOVE_GEN_GENERATE_NOISY;
                    move_cmd_valid = 1'b1;
                end
                MOVE_ORDER_GOOD_NOISY: begin
                    move_pop_eligible = GOOD_NOISY_BUCKET_MASK | BAD_NOISY_BUCKET_MASK;
                    move_pop_valid = 1'b1;
                end
                MOVE_ORDER_GENERATE_QUIET: begin
                    move_quiet_cmd_valid = 1'b1;
                    move_quiet_cmd_thread = ThreadID'(0);
                    move_quiet_cmd_ply = search_ply[0];
                    move_quiet_cmd_board = search_board[0];
                    move_quiet_cmd_tops = search_stack_top[0].bucket_tops;
                end
                MOVE_ORDER_QUIET: begin
                    move_pop_eligible = QUIET_BUCKET_MASK;
                    move_pop_valid = 1'b1;
                end
                default: begin end
            endcase
        end else if (search_move_issue_valid) begin
            automatic MoveOrderState order_state = search_stack_top[search_move_issue_thread].move_order_state;
            automatic Move order_move = ordering_move_for_thread(search_move_issue_thread);
            move_cmd_thread = search_move_issue_thread;
            move_cmd_ply = search_ply[search_move_issue_thread];
            move_cmd_board = search_board[search_move_issue_thread];
            move_cmd_tops = search_stack_top[search_move_issue_thread].bucket_tops;
            move_cmd_suppress_valid = search_stack_top[search_move_issue_thread].direct_attempted;
            move_cmd_suppress_move = search_stack_top[search_move_issue_thread].tt_move;
            move_pop_thread = search_move_issue_thread;
            move_pop_ply = search_ply[search_move_issue_thread];
            move_pop_current_tops = search_stack_top[search_move_issue_thread].bucket_tops;
            move_pop_lower_tops = search_ply[search_move_issue_thread] == PlyIndex'(0)
                ? MoveBucketTops'(0) : search_stack_parent_q[search_move_issue_thread].bucket_tops;
            if (move_state_uses_pop(order_state)) begin
                move_pop_valid = 1'b1;
                case (order_state)
                    MOVE_ORDER_GOOD_NOISY: move_pop_eligible = GOOD_NOISY_BUCKET_MASK;
                    MOVE_ORDER_QUIET: move_pop_eligible = QUIET_BUCKET_MASK;
                    default: move_pop_eligible = BAD_NOISY_BUCKET_MASK;
                endcase
            end else begin
                move_cmd_valid = 1'b1;
                if (order_state == MOVE_ORDER_DIRECT && !is_null_move(order_move)) begin
                    move_cmd = MOVE_GEN_VALIDATE_DIRECT;
                    move_cmd_suppress_valid = 1'b1;
                    move_cmd_suppress_move = order_move;
                end else begin
                    move_cmd = MOVE_GEN_GENERATE_NOISY;
                end
            end
        end

        if (state == ST_SEARCH_RUN && search_quiet_issue_valid) begin
            move_quiet_cmd_valid = 1'b1;
            move_quiet_cmd_thread = search_quiet_issue_thread;
            move_quiet_cmd_ply = search_ply[search_quiet_issue_thread];
            move_quiet_cmd_board = search_board[search_quiet_issue_thread];
            move_quiet_cmd_suppress_valid =
                search_stack_top[search_quiet_issue_thread].direct_attempted;
            move_quiet_cmd_suppress_move =
                search_stack_top[search_quiet_issue_thread].tt_move;
            move_quiet_cmd_tops =
                search_stack_top[search_quiet_issue_thread].bucket_tops;
        end

        eval_base = (state == ST_SEARCH_RUN)
            ? search_pst_eval[search_eval_issue_thread]
            : search_pst_eval[search_thread_id];
        for (int pos = 0; pos < 64; pos++) begin
            eval_board_tiles[pos] = (state == ST_SEARCH_RUN)
                ? search_board[search_eval_issue_thread].tiles[pos]
                : search_board[search_thread_id].tiles[pos];
        end

        tt_clear = state == ST_NEW_CLEAR_START;
        tt_lookup_req_valid = search_tt_lookup_issue_valid;
        tt_lookup_req = TTLookupRequest'('0);
        tt_lookup_req.thread_id = (state == ST_SEARCH_RUN) ? search_tt_lookup_issue_thread : search_thread_id;
        tt_lookup_req.zobrist_key = search_zobrist_key[tt_lookup_req.thread_id];
        tt_lookup_req.depth = search_remaining_depth(tt_lookup_req.thread_id);
        tt_lookup_req.alpha = search_stack_top[tt_lookup_req.thread_id].alpha;
        tt_lookup_req.beta = search_stack_top[tt_lookup_req.thread_id].beta;
        tt_lookup_req.ply = search_ply[tt_lookup_req.thread_id];

        tt_store_req_valid = search_tt_store_issue_valid;
        tt_store_req = TTStoreRequest'('0);
        tt_store_req.zobrist_key = search_zobrist_key[search_tt_store_issue_thread];
        tt_store_req.depth = search_remaining_depth(search_tt_store_issue_thread);
        tt_store_req.score = search_return_score[search_tt_store_issue_thread];
        tt_store_req.bound_type = tt_bound_for_score(
            search_return_score[search_tt_store_issue_thread],
            search_stack_top[search_tt_store_issue_thread].orig_alpha,
            search_stack_top[search_tt_store_issue_thread].beta
        );
        tt_store_req.best_move = search_stack_top[search_tt_store_issue_thread].best_move;
        tt_store_req.age = tt_age;
        tt_store_req.ply = search_ply[search_tt_store_issue_thread];

        timer_rst = (state == ST_IDLE);
        timer_run = ((state == ST_PERFT_GEN_ISSUE)
            || (state == ST_PERFT_GEN_WAIT)
            || (state == ST_PERFT_PUSH_ISSUE)
            || (state == ST_PERFT_PUSH_WAIT)
            || (state == ST_PERFT_REVERSE_ISSUE)
            || (state == ST_PERFT_REVERSE_WAIT))
            || (state == ST_SEARCH_ITER_START)
            || (state == ST_SEARCH_RUN);
    end

    always_ff @(posedge clk) begin
        if (!rst_n) begin
            state <= ST_IDLE;
            active_req <= EngineControllerRequest'('0);
            resp_reg <= EngineControllerResponse'('0);
            resp_valid <= 1'b0;
            board_wait_count <= BoardWaitCount'(0);
            move_wait_count <= MoveWaitCount'(0);
            active_board <= FullBoard'('0);
            active_board_in_check <= 1'b0;
            active_zobrist_key <= ZobristKey'(0);
            active_pst_eval <= EvalScore'(0);
            repetition_epoch <= '0;
            repetition_init_start <= 1'b0;
            repetition_history_reset <= 1'b0;
            repetition_history_write <= 1'b0;
            repetition_history_key <= '0;
            repetition_line_write_valid <= 1'b0;
            repetition_line_write_thread <= '0;
            repetition_line_write_ply <= '0;
            repetition_line_write_key <= '0;
            repetition_req_valid <= 1'b0;
            repetition_req_thread <= '0;
            repetition_req_ply <= '0;
            repetition_req_start_ply <= '0;
            repetition_req_key <= '0;
            new_setup_index <= 7'd0;
            search_nodes <= NodeCountType'(0);
            search_target_depth <= SearchDepth'(0);
            search_max_depth <= SearchDepth'(0);
            search_completed_depth <= SearchDepth'(0);
            search_completed_best_move <= NULL_MOVE;
            search_completed_score <= EvalScore'(0);
            search_root_alpha <= -SEARCH_INF;
            search_root_beta <= SEARCH_INF;
            search_aspiration_active <= 1'b0;
            search_thread_id <= ThreadID'(0);
            search_dispatch <= '0;
`ifndef SYNTHESIS
            search_board_result_thread_id <= ThreadID'(0);
            search_move_result_thread_id <= ThreadID'(0);
            search_eval_result_thread_id <= ThreadID'(0);
            search_board_result_valid <= 1'b0;
            search_move_result_valid <= 1'b0;
            search_eval_result_valid <= 1'b0;
`endif
            search_active_thread_count <= ThreadCount'(0);
            search_iteration_has_result <= 1'b0;
            search_iteration_best_move <= NULL_MOVE;
            search_iteration_best_score <= -SEARCH_INF;
            search_budget_ms <= TimeType'(0);
            tt_age <= TTAge'(0);
            terminal_result_valid_pipe <= 1'b0;
            terminal_result_thread_pipe <= ThreadID'(0);
            terminal_result_ply_pipe <= PlyIndex'(0);
            terminal_result_score_pipe <= EvalScore'(0);
`ifdef FPGA_CHESS_PROFILE
            profile_terminal_event <= 1'b0;
            profile_terminal_kind <= 2'd0;
            profile_beta_cutoff_event <= 1'b0;
            profile_beta_cutoff_thread <= ThreadID'(0);
            profile_beta_cutoff_ply <= PlyIndex'(0);
            profile_beta_cutoff_rank <= 8'd0;
            profile_beta_cutoff_move <= NULL_MOVE;
`endif
            for (int tid = 0; tid < SEARCH_THREAD_COUNT; tid++) begin
                search_best_move[tid] <= NULL_MOVE;
                search_root_best_score[tid] <= -SEARCH_INF;
                search_thread_status[tid] <= SEARCH_THREAD_IDLE;
                search_thread_phase[tid] <= SEARCH_PHASE_IDLE;
                search_thread_nodes[tid] <= NodeCountType'(0);
                search_thread_completed_depth[tid] <= 8'd0;
                search_thread_completed_best_move[tid] <= NULL_MOVE;
                search_board_wait_count[tid] <= BoardWaitCount'(0);
                search_move_wait_count[tid] <= MoveWaitCount'(0);
                search_eval_wait_count[tid] <= EvalWaitCount'(0);
                search_board_inflight[tid] <= 1'b0;
                search_move_inflight[tid] <= 1'b0;
                search_eval_inflight[tid] <= 1'b0;
                search_tt_lookup_inflight[tid] <= 1'b0;
                search_tt_store_inflight[tid] <= 1'b0;
                search_tt_response_pending[tid] <= 1'b0;
                search_repetition_pending[tid] <= 1'b0;
                search_tt_response[tid] <= TTLookupResponse'('0);
                search_pending_move[tid] <= NULL_MOVE;
                search_board[tid] <= FullBoard'('0);
                search_board_in_check[tid] <= 1'b0;
                search_zobrist_key[tid] <= ZobristKey'(0);
                search_pst_eval[tid] <= EvalScore'(0);
                search_ply[tid] <= PlyIndex'(0);
                search_return_score[tid] <= EvalScore'(0);
                search_return_valid[tid] <= 1'b0;
                search_return_was_scout[tid] <= 1'b0;
                search_return_was_reduced[tid] <= 1'b0;
                search_pvs_research[tid] <= 1'b0;
                search_eval_is_stand_pat[tid] <= 1'b0;
                search_stack_top[tid] <= empty_search_stack_entry();
                search_return_move[tid] <= NULL_MOVE;
                history_update_pending[tid] <= 1'b0;
                history_update_pending_color[tid] <= WHITE;
                history_update_pending_from[tid] <= Position'(0);
                history_update_pending_to[tid] <= Position'(0);
                history_update_pending_depth[tid] <= 6'd0;
            end
            for (int idx = 0; idx < SEARCH_BOARD_TAG_PIPE_LEN; idx++) begin
                search_board_tag_pipe[idx] <= ThreadID'(0);
                search_board_op_tag_pipe[idx] <= BOARD_IDLE_OP;
                search_board_ply_tag_pipe[idx] <= PlyIndex'(0);
                search_board_tag_valid_pipe[idx] <= 1'b0;
            end
            for (int idx = 0; idx < SEARCH_MOVE_TAG_PIPE_LEN; idx++) begin
                search_move_tag_pipe[idx] <= ThreadID'(0);
                search_move_tag_valid_pipe[idx] <= 1'b0;
                search_move_in_check_pipe[idx] <= 1'b0;
            end
            for (int idx = 0; idx < SEARCH_EVAL_TAG_PIPE_LEN; idx++) begin
                search_eval_tag_pipe[idx] <= ThreadID'(0);
                search_eval_tag_valid_pipe[idx] <= 1'b0;
            end
        end else begin
            resp_valid <= 1'b0;
            repetition_init_start <= 1'b0;
            repetition_history_reset <= 1'b0;
            repetition_history_write <= 1'b0;
            repetition_line_write_valid <= 1'b0;
            repetition_req_valid <= 1'b0;
            search_board_result_valid <= 1'b0;
            search_move_result_valid <= 1'b0;
            search_eval_result_valid <= 1'b0;
            terminal_result_valid_pipe <= 1'b0;
`ifdef FPGA_CHESS_PROFILE
            profile_terminal_event <= 1'b0;
            profile_beta_cutoff_event <= 1'b0;
`endif

            if (move_history_update_valid && move_history_update_ready) begin
                automatic logic cleared_history_update;

                cleared_history_update = 1'b0;
                for (int tid = 0; tid < SEARCH_THREAD_COUNT; tid++) begin
                    if (!cleared_history_update && history_update_pending[tid]) begin
                        history_update_pending[tid] <= 1'b0;
                        cleared_history_update = 1'b1;
                    end
                end
            end

            // A Kill or New Game can retire a search while an external-memory
            // response is still returning. Accept only the response belonging
            // to this thread's currently outstanding lookup.
            if (tt_lookup_resp_valid
                    && search_tt_lookup_inflight[tt_lookup_resp.thread_id]
                    && search_thread_phase[tt_lookup_resp.thread_id] == SEARCH_PHASE_TT_WAIT) begin
                search_tt_response[tt_lookup_resp.thread_id] <= tt_lookup_resp;
                search_tt_response_pending[tt_lookup_resp.thread_id] <= 1'b1;
                search_tt_lookup_inflight[tt_lookup_resp.thread_id] <= 1'b0;
            end

            if (repetition_resp_valid && repetition_resp_epoch == repetition_epoch
                    && search_repetition_pending[repetition_resp_thread]) begin
                search_repetition_pending[repetition_resp_thread] <= 1'b0;
                if (repetition_resp_is_draw) begin
                    search_return_score[repetition_resp_thread] <= DRAW_EVAL_SCORE;
                    search_return_valid[repetition_resp_thread] <= 1'b1;
                    search_thread_phase[repetition_resp_thread] <= SEARCH_PHASE_REVERSE_WAIT;
                end else begin
                    search_thread_phase[repetition_resp_thread] <= SEARCH_PHASE_READY;
                end
            end

            if (req_valid && req.operation == ENGINE_CTRL_KILL && state != ST_IDLE) begin
                repetition_epoch <= repetition_epoch + 1'b1;
                terminal_result_valid_pipe <= 1'b0;
                resp_reg <= EngineControllerResponse'('0);
                resp_reg.end_reason <= ENGINE_END_KILLED;
                for (int tid = 0; tid < SEARCH_THREAD_COUNT; tid++) begin
                    search_board_wait_count[tid] <= BoardWaitCount'(0);
                    search_move_wait_count[tid] <= MoveWaitCount'(0);
                    search_eval_wait_count[tid] <= EvalWaitCount'(0);
                    search_board_inflight[tid] <= 1'b0;
                    search_move_inflight[tid] <= 1'b0;
                    search_eval_inflight[tid] <= 1'b0;
                    search_tt_lookup_inflight[tid] <= 1'b0;
                    search_tt_store_inflight[tid] <= 1'b0;
                    search_tt_response_pending[tid] <= 1'b0;
                    search_repetition_pending[tid] <= 1'b0;
                    search_return_was_scout[tid] <= 1'b0;
                    search_return_was_reduced[tid] <= 1'b0;
                    search_pvs_research[tid] <= 1'b0;
                    history_update_pending[tid] <= 1'b0;
                    search_thread_status[tid] <= SEARCH_THREAD_IDLE;
                    search_thread_phase[tid] <= SEARCH_PHASE_IDLE;
                end
                for (int idx = 0; idx < SEARCH_BOARD_TAG_PIPE_LEN; idx++) begin
                    search_board_tag_pipe[idx] <= ThreadID'(0);
                    search_board_op_tag_pipe[idx] <= BOARD_IDLE_OP;
                    search_board_ply_tag_pipe[idx] <= PlyIndex'(0);
                    search_board_tag_valid_pipe[idx] <= 1'b0;
                end
                for (int idx = 0; idx < SEARCH_MOVE_TAG_PIPE_LEN; idx++) begin
                    search_move_tag_pipe[idx] <= ThreadID'(0);
                    search_move_tag_valid_pipe[idx] <= 1'b0;
                    search_move_in_check_pipe[idx] <= 1'b0;
                end
                for (int idx = 0; idx < SEARCH_EVAL_TAG_PIPE_LEN; idx++) begin
                    search_eval_tag_pipe[idx] <= ThreadID'(0);
                    search_eval_tag_valid_pipe[idx] <= 1'b0;
                end
                state <= ST_KILL_DONE;
            end else begin
            case (state)
                ST_IDLE: begin
                    if (req_valid) begin
                        active_req <= req;
                        case (req.operation)
                            ENGINE_CTRL_DIRECT_BOARD: begin
                                if (req.direct_board_op == BOARD_REVERSE_MOVE_OP) begin
                                    resp_reg <= EngineControllerResponse'('0);
                                    resp_reg.error <= 1'b1;
                                    resp_reg.end_reason <= ENGINE_END_ERROR;
                                    state <= ST_DIRECT_DONE;
                                end else begin
                                    state <= ST_BOARD_ISSUE;
                                end
                            end

                            ENGINE_CTRL_NEW_GAME: begin
                                repetition_epoch <= repetition_epoch + 1'b1;
                                search_best_move[search_thread_id] <= NULL_MOVE;
                                search_nodes <= NodeCountType'(0);
                                search_dispatch <= '0;
                                search_active_thread_count <= ThreadCount'(0);
                                for (int tid = 0; tid < SEARCH_THREAD_COUNT; tid++) begin
                                    search_thread_nodes[tid] <= NodeCountType'(0);
                                    search_thread_status[tid] <= SEARCH_THREAD_IDLE;
                                    search_thread_phase[tid] <= SEARCH_PHASE_IDLE;
                                    search_board_wait_count[tid] <= BoardWaitCount'(0);
                                    search_move_wait_count[tid] <= MoveWaitCount'(0);
                                    search_eval_wait_count[tid] <= EvalWaitCount'(0);
                                    search_board_inflight[tid] <= 1'b0;
                                    search_move_inflight[tid] <= 1'b0;
                                    search_eval_inflight[tid] <= 1'b0;
                                    search_tt_lookup_inflight[tid] <= 1'b0;
                                    search_tt_store_inflight[tid] <= 1'b0;
                                    search_tt_response_pending[tid] <= 1'b0;
                                    history_update_pending[tid] <= 1'b0;
                                end
                                for (int idx = 0; idx < SEARCH_BOARD_TAG_PIPE_LEN; idx++) begin
                                    search_board_tag_pipe[idx] <= ThreadID'(0);
                                    search_board_op_tag_pipe[idx] <= BOARD_IDLE_OP;
                                    search_board_ply_tag_pipe[idx] <= PlyIndex'(0);
                                    search_board_tag_valid_pipe[idx] <= 1'b0;
                                end
                                for (int idx = 0; idx < SEARCH_MOVE_TAG_PIPE_LEN; idx++) begin
                                    search_move_tag_pipe[idx] <= ThreadID'(0);
                                    search_move_tag_valid_pipe[idx] <= 1'b0;
                                    search_move_in_check_pipe[idx] <= 1'b0;
                                end
                                for (int idx = 0; idx < SEARCH_EVAL_TAG_PIPE_LEN; idx++) begin
                                    search_eval_tag_pipe[idx] <= ThreadID'(0);
                                    search_eval_tag_valid_pipe[idx] <= 1'b0;
                                end
                                tt_age <= tt_age + TTAge'(1);
                                state <= ST_NEW_CLEAR_START;
                            end

                            ENGINE_CTRL_PERFT: begin
                                if (req.depth_limit >= 8'(SEARCH_STACK_DEPTH)) begin
                                    resp_reg <= EngineControllerResponse'('0);
                                    resp_reg.error <= 1'b1;
                                    resp_reg.end_reason <= ENGINE_END_ERROR;
                                    state <= ST_RESPOND;
                                end else begin
                                    // Perft borrows the idle first search context and leaves the game board intact.
                                    search_board[0] <= active_board;
                                    search_zobrist_key[0] <= active_zobrist_key;
                                    search_pst_eval[0] <= active_pst_eval;
                                    search_pending_move[0] <= NULL_MOVE;
                                    search_stack_top[0] <= empty_search_stack_entry();
                                    search_stack_top[0].move_order_state <= MOVE_ORDER_GENERATE_NOISY;
                                    search_ply[0] <= PlyIndex'(0);
                                    search_nodes <= (req.depth_limit == 8'd0) ? NodeCountType'(1) : NodeCountType'(0);
                                    if (req.depth_limit == 8'd0) begin
                                        resp_reg <= EngineControllerResponse'('0);
                                        resp_reg.nodes_count <= NodeCountType'(1);
                                        resp_reg.completed_depth <= 8'd0;
                                        resp_reg.end_reason <= ENGINE_END_DEPTH_LIMIT;
                                        state <= ST_RESPOND;
                                    end else begin
                                        state <= ST_PERFT_GEN_ISSUE;
                                    end
                                end
                            end

                            ENGINE_CTRL_SEARCH_DEPTH,
                            ENGINE_CTRL_SEARCH_FIXED_TIME,
                            ENGINE_CTRL_SEARCH_ON_CLOCK,
                            ENGINE_CTRL_SEARCH_NODES: begin
                                if (requested_search_depth(req) >= 8'(SEARCH_STACK_DEPTH)) begin
                                    resp_reg <= EngineControllerResponse'('0);
                                    resp_reg.error <= 1'b1;
                                    resp_reg.end_reason <= ENGINE_END_ERROR;
                                    state <= ST_RESPOND;
                                end else begin
                                    search_ply[search_thread_id] <= PlyIndex'(0);
                                    search_max_depth <= requested_search_depth(req);
                                    search_target_depth <= (requested_search_depth(req) == SearchDepth'(0))
                                        ? SearchDepth'(0) : SearchDepth'(1);
                                    search_completed_depth <= SearchDepth'(0);
                                    search_completed_best_move <= NULL_MOVE;
                                    search_completed_score <= EvalScore'(0);
                                    search_root_alpha <= -SEARCH_INF;
                                    search_root_beta <= SEARCH_INF;
                                    search_aspiration_active <= 1'b0;
                                    search_thread_id <= ThreadID'(0);
                                    search_dispatch <= '0;
                                    search_active_thread_count <= ThreadCount'(0);
                                    search_iteration_has_result <= 1'b0;
                                    search_iteration_best_move <= NULL_MOVE;
                                    search_iteration_best_score <= -SEARCH_INF;
                                    search_nodes <= NodeCountType'(0);
                                    search_best_move[search_thread_id] <= NULL_MOVE;
                                    search_pending_move[search_thread_id] <= NULL_MOVE;
                                    search_return_score[search_thread_id] <= EvalScore'(0);
                                    search_return_valid[search_thread_id] <= 1'b0;
                                    search_return_was_scout[search_thread_id] <= 1'b0;
                                    search_return_was_reduced[search_thread_id] <= 1'b0;
                                    search_pvs_research[search_thread_id] <= 1'b0;
                                    search_eval_is_stand_pat[search_thread_id] <= 1'b0;
                                    tt_age <= tt_age + TTAge'(1);
                                    if (req.operation == ENGINE_CTRL_SEARCH_FIXED_TIME) begin
                                        search_budget_ms <= req.time_limit;
                                    end else if (req.operation == ENGINE_CTRL_SEARCH_ON_CLOCK) begin
                                        search_budget_ms <= clock_budget(req);
                                    end else begin
                                        search_budget_ms <= TimeType'('1);
                                    end
                                    for (int tid = 0; tid < SEARCH_THREAD_COUNT; tid++) begin
                                        search_thread_nodes[tid] <= NodeCountType'(0);
                                        search_thread_status[tid] <= SEARCH_THREAD_IDLE;
                                        search_thread_phase[tid] <= SEARCH_PHASE_IDLE;
                                        search_thread_completed_depth[tid] <= 8'd0;
                                        search_thread_completed_best_move[tid] <= NULL_MOVE;
                                        search_board_wait_count[tid] <= BoardWaitCount'(0);
                                        search_move_wait_count[tid] <= MoveWaitCount'(0);
                                        search_eval_wait_count[tid] <= EvalWaitCount'(0);
                                        search_board_inflight[tid] <= 1'b0;
                                        search_move_inflight[tid] <= 1'b0;
                                        search_eval_inflight[tid] <= 1'b0;
                                        search_tt_lookup_inflight[tid] <= 1'b0;
                                        search_tt_store_inflight[tid] <= 1'b0;
                                        search_tt_response_pending[tid] <= 1'b0;
                                        search_repetition_pending[tid] <= 1'b0;
                                        search_return_was_scout[tid] <= 1'b0;
                                        search_return_was_reduced[tid] <= 1'b0;
                                        search_pvs_research[tid] <= 1'b0;
                                    end
                                    for (int idx = 0; idx < SEARCH_BOARD_TAG_PIPE_LEN; idx++) begin
                                        search_board_tag_pipe[idx] <= ThreadID'(0);
                                        search_board_op_tag_pipe[idx] <= BOARD_IDLE_OP;
                                        search_board_ply_tag_pipe[idx] <= PlyIndex'(0);
                                        search_board_tag_valid_pipe[idx] <= 1'b0;
                                    end
                                    for (int idx = 0; idx < SEARCH_MOVE_TAG_PIPE_LEN; idx++) begin
                                        search_move_tag_pipe[idx] <= ThreadID'(0);
                                        search_move_tag_valid_pipe[idx] <= 1'b0;
                                        search_move_in_check_pipe[idx] <= 1'b0;
                                    end
                                    for (int idx = 0; idx < SEARCH_EVAL_TAG_PIPE_LEN; idx++) begin
                                        search_eval_tag_pipe[idx] <= ThreadID'(0);
                                        search_eval_tag_valid_pipe[idx] <= 1'b0;
                                    end
                                    repetition_epoch <= repetition_epoch + 1'b1;
                                    repetition_init_start <= 1'b1;
                                    state <= ST_REPETITION_INIT;
                                end
                            end

                            ENGINE_CTRL_KILL: begin
                                repetition_epoch <= repetition_epoch + 1'b1;
                                resp_reg <= EngineControllerResponse'('0);
                                resp_reg.end_reason <= ENGINE_END_KILLED;
                                search_dispatch <= '0;
                                search_active_thread_count <= ThreadCount'(0);
                                for (int tid = 0; tid < SEARCH_THREAD_COUNT; tid++) begin
                                    search_board_wait_count[tid] <= BoardWaitCount'(0);
                                    search_move_wait_count[tid] <= MoveWaitCount'(0);
                                    search_eval_wait_count[tid] <= EvalWaitCount'(0);
                                    search_board_inflight[tid] <= 1'b0;
                                    search_move_inflight[tid] <= 1'b0;
                                    search_eval_inflight[tid] <= 1'b0;
                                    search_tt_lookup_inflight[tid] <= 1'b0;
                                    search_tt_store_inflight[tid] <= 1'b0;
                                    search_tt_response_pending[tid] <= 1'b0;
                                    search_thread_status[tid] <= SEARCH_THREAD_IDLE;
                                    search_thread_phase[tid] <= SEARCH_PHASE_IDLE;
                                end
                                for (int idx = 0; idx < SEARCH_BOARD_TAG_PIPE_LEN; idx++) begin
                                    search_board_tag_pipe[idx] <= ThreadID'(0);
                                    search_board_op_tag_pipe[idx] <= BOARD_IDLE_OP;
                                    search_board_ply_tag_pipe[idx] <= PlyIndex'(0);
                                    search_board_tag_valid_pipe[idx] <= 1'b0;
                                end
                                for (int idx = 0; idx < SEARCH_MOVE_TAG_PIPE_LEN; idx++) begin
                                    search_move_tag_pipe[idx] <= ThreadID'(0);
                                    search_move_tag_valid_pipe[idx] <= 1'b0;
                                    search_move_in_check_pipe[idx] <= 1'b0;
                                end
                                for (int idx = 0; idx < SEARCH_EVAL_TAG_PIPE_LEN; idx++) begin
                                    search_eval_tag_pipe[idx] <= ThreadID'(0);
                                    search_eval_tag_valid_pipe[idx] <= 1'b0;
                                end
                                state <= ST_KILL_DONE;
                            end

                            default: begin
                                resp_reg <= EngineControllerResponse'('0);
                                resp_reg.error <= 1'b1;
                                resp_reg.end_reason <= ENGINE_END_ERROR;
                                state <= ST_RESPOND;
                            end
                        endcase
                    end
                end

                ST_BOARD_ISSUE: begin
                    board_wait_count <= BoardWaitCount'(BOARD_UPDATE_PIPELINE_STAGE_CNT - 1);
                    state <= ST_BOARD_WAIT;
                end

                ST_BOARD_WAIT: begin
                    if (board_wait_count == BoardWaitCount'(0)) begin
                        active_board <= board_update_out;
                        active_board_in_check <= board_update_side_in_check;
                        active_zobrist_key <= board_update_zobrist_out;
                        active_pst_eval <= board_update_pst_out;
                        if (active_req.direct_board_op == BOARD_COMMIT_MOVE_OP) begin
                            if (committed_move_is_irreversible(active_board, board_update_out, active_req.move)) begin
                                repetition_history_reset <= 1'b1;
                                repetition_history_key <= board_update_zobrist_out;
                            end else begin
                                repetition_history_write <= 1'b1;
                                repetition_history_key <= board_update_zobrist_out;
                            end
                        end else if (is_direct_setup_op(active_req.direct_board_op)) begin
                            repetition_history_reset <= 1'b1;
                            repetition_history_key <= board_update_zobrist_out;
                        end
                        resp_reg <= EngineControllerResponse'('0);
                        state <= ST_DIRECT_DONE;
                    end else begin
                        board_wait_count <= board_wait_count - BoardWaitCount'(1);
                    end
                end

                ST_DIRECT_DONE: begin
                    resp_valid <= 1'b1;
                    state <= ST_IDLE;
                end

                ST_NEW_CLEAR_START: begin
                    state <= ST_NEW_CLEAR_WAIT;
                end

                ST_NEW_CLEAR_WAIT: begin
                if (!tt_clear_busy && !move_init_busy) begin
                        new_setup_index <= 7'd0;
                        state <= ST_NEW_SETUP_ISSUE;
                    end
                end

                ST_NEW_SETUP_ISSUE: begin
                    board_wait_count <= BoardWaitCount'(BOARD_UPDATE_PIPELINE_STAGE_CNT - 1);
                    state <= ST_NEW_SETUP_WAIT;
                end

                ST_NEW_SETUP_WAIT: begin
                    if (board_wait_count == BoardWaitCount'(0)) begin
                        active_board <= board_update_out;
                        active_board_in_check <= board_update_side_in_check;
                        active_zobrist_key <= board_update_zobrist_out;
                        active_pst_eval <= board_update_pst_out;
                        if (new_setup_index == 7'd67) begin
                            repetition_history_reset <= 1'b1;
                            repetition_history_key <= board_update_zobrist_out;
                            resp_reg <= EngineControllerResponse'('0);
                            state <= ST_NEW_DONE;
                        end else begin
                            new_setup_index <= new_setup_index + 7'd1;
                            state <= ST_NEW_SETUP_ISSUE;
                        end
                    end else begin
                        board_wait_count <= board_wait_count - BoardWaitCount'(1);
                    end
                end

                ST_NEW_DONE: begin
                    resp_valid <= 1'b1;
                    state <= ST_IDLE;
                end

                ST_PERFT_GEN_ISSUE: begin
                    if (search_stack_top[0].move_order_state == MOVE_ORDER_DONE) begin
                        if (search_ply[0] == PlyIndex'(0)) begin
                            resp_reg <= EngineControllerResponse'('0);
                            resp_reg.nodes_count <= search_nodes;
                            resp_reg.completed_depth <= active_req.depth_limit;
                            resp_reg.end_reason <= ENGINE_END_DEPTH_LIMIT;
                            state <= ST_RESPOND;
                        end else begin
                            state <= ST_PERFT_REVERSE_ISSUE;
                        end
                    end else if ((move_cmd_valid && move_cmd_ready)
                            || (move_quiet_cmd_valid && move_quiet_cmd_ready)
                            || (move_pop_valid && move_pop_ready)) begin
                        state <= ST_PERFT_GEN_WAIT;
                    end
                end

                ST_PERFT_GEN_WAIT: begin
                    if (move_cmd_resp_valid && move_cmd_resp_thread == ThreadID'(0)) begin
                        search_stack_top[0].bucket_tops <= move_cmd_resp_tops;
                        search_stack_top[0].move_order_state <= MOVE_ORDER_GOOD_NOISY;
                        state <= ST_PERFT_GEN_ISSUE;
                    end else if (move_quiet_resp_valid
                            && move_quiet_resp_thread == ThreadID'(0)) begin
                        search_stack_top[0].bucket_tops <= move_quiet_resp_tops;
                        search_stack_top[0].move_order_state <= MOVE_ORDER_QUIET;
                        state <= ST_PERFT_GEN_ISSUE;
                    end else if (move_pop_resp_valid && move_pop_resp_thread == ThreadID'(0)) begin
                        if (move_pop_resp_found) begin
                            search_stack_top[0].bucket_tops[move_pop_resp_bucket] <= move_pop_resp_new_top;
                            search_pending_move[0] <= move_pop_resp_move;
                            board_wait_count <= BoardWaitCount'(BOARD_UPDATE_PIPELINE_STAGE_CNT - 1);
                            state <= ST_PERFT_PUSH_WAIT;
                        end else begin
                            if (search_stack_top[0].move_order_state == MOVE_ORDER_GOOD_NOISY)
                                search_stack_top[0].move_order_state <= MOVE_ORDER_GENERATE_QUIET;
                            else
                                search_stack_top[0].move_order_state <= MOVE_ORDER_DONE;
                            state <= ST_PERFT_GEN_ISSUE;
                        end
                    end
                end

                ST_PERFT_PUSH_ISSUE: begin
                    board_wait_count <= BoardWaitCount'(BOARD_UPDATE_PIPELINE_STAGE_CNT - 1);
                    state <= ST_PERFT_PUSH_WAIT;
                end

                ST_PERFT_PUSH_WAIT: begin
                    if (board_wait_count == BoardWaitCount'(0)) begin
                        if (board_update_mover_in_check) begin
                            state <= ST_PERFT_GEN_ISSUE;
                        end else if (int'(search_ply[0]) + 1 >= int'(active_req.depth_limit)) begin
                            search_nodes <= search_nodes + NodeCountType'(1);
                            state <= ST_PERFT_GEN_ISSUE;
                        end else begin
                            automatic MoveBucketTops inherited_tops = search_stack_top[0].bucket_tops;
                            search_board[0] <= board_update_out;
                            search_zobrist_key[0] <= board_update_zobrist_out;
                            search_pst_eval[0] <= board_update_pst_out;
                            search_stack_top[0] <= empty_search_stack_entry();
                            search_stack_top[0].bucket_tops <= inherited_tops;
                            search_stack_top[0].move_order_state <= MOVE_ORDER_GENERATE_NOISY;
                            search_ply[0] <= search_ply[0] + PlyIndex'(1);
                            state <= ST_PERFT_GEN_ISSUE;
                        end
                    end else begin
                        board_wait_count <= board_wait_count - BoardWaitCount'(1);
                    end
                end

                ST_PERFT_REVERSE_ISSUE: begin
                    board_wait_count <= BoardWaitCount'(BOARD_UPDATE_PIPELINE_STAGE_CNT - 1);
                    state <= ST_PERFT_REVERSE_WAIT;
                end

                ST_PERFT_REVERSE_WAIT: begin
                    if (board_wait_count == BoardWaitCount'(0)) begin
                        search_board[0] <= board_update_out;
                        search_zobrist_key[0] <= board_update_zobrist_out;
                        search_pst_eval[0] <= board_update_pst_out;
                        search_stack_top[0] <= search_stack_parent_q[0];
                        search_ply[0] <= search_ply[0] - PlyIndex'(1);
                        state <= ST_PERFT_GEN_ISSUE;
                    end else begin
                        board_wait_count <= board_wait_count - BoardWaitCount'(1);
                    end
                end

                ST_REPETITION_INIT: begin
                    if (repetition_init_failed) begin
                        resp_reg <= EngineControllerResponse'('0);
                        resp_reg.error <= 1'b1;
                        resp_reg.end_reason <= ENGINE_END_ERROR;
                        state <= ST_RESPOND;
                    // A repeated search starts from INIT_READY; wait for the
                    // one-cycle start pulse to be consumed before accepting done.
                    end else if (repetition_init_done && !repetition_init_start) begin
                        repetition_req_valid <= 1'b1;
                        repetition_req_thread <= ThreadID'(0);
                        repetition_req_ply <= PlyIndex'(0);
                        repetition_req_start_ply <= PlyIndex'(0);
                        repetition_req_key <= active_zobrist_key;
                        state <= ST_REPETITION_ROOT_WAIT;
                    end
                end

                ST_REPETITION_ROOT_WAIT: begin
                    if (repetition_resp_valid && repetition_resp_epoch == repetition_epoch) begin
                        if (repetition_resp_is_draw) begin
                            resp_reg <= EngineControllerResponse'('0);
                            resp_reg.score <= DRAW_EVAL_SCORE;
                            resp_reg.best_move <= NULL_MOVE;
                            resp_reg.end_reason <= ENGINE_END_DEPTH_LIMIT;
                            state <= ST_RESPOND;
                        end else begin
                            state <= ST_SEARCH_ITER_START;
                        end
                    end
                end

                ST_SEARCH_ITER_START: begin
                    for (int tid = 0; tid < SEARCH_THREAD_COUNT; tid++) begin
                        search_thread_status[tid] <= SEARCH_THREAD_ACTIVE;
                        search_thread_phase[tid] <= SEARCH_PHASE_READY;
                        search_board[tid] <= active_board;
                        search_board_in_check[tid] <= active_board_in_check;
                        search_zobrist_key[tid] <= active_zobrist_key;
                        search_pst_eval[tid] <= active_pst_eval;
                        search_ply[tid] <= PlyIndex'(0);
                        search_best_move[tid] <= NULL_MOVE;
                        search_root_best_score[tid] <= -SEARCH_INF;
                        search_pending_move[tid] <= NULL_MOVE;
                        search_return_score[tid] <= EvalScore'(0);
                        search_return_valid[tid] <= 1'b0;
                        search_return_was_scout[tid] <= 1'b0;
                        search_return_was_reduced[tid] <= 1'b0;
                        search_pvs_research[tid] <= 1'b0;
                        search_eval_is_stand_pat[tid] <= 1'b0;
                        search_stack_top[tid] <= empty_search_stack_entry();
                        search_stack_top[tid].remaining_depth <= search_target_depth;
                        search_stack_top[tid].alpha <= search_root_alpha;
                        search_stack_top[tid].orig_alpha <= search_root_alpha;
                        search_stack_top[tid].beta <= search_root_beta;
                        search_return_move[tid] <= NULL_MOVE;
                    end
                    search_thread_id <= ThreadID'(0);
                    search_dispatch <= '0;
                    search_active_thread_count <= ThreadCount'(SEARCH_THREAD_COUNT);
                    state <= ST_SEARCH_RUN;
                end

                ST_SEARCH_RUN: begin
                    automatic ThreadCount active_count_next;
                    automatic logic iteration_has_result_next;
                    automatic Move iteration_best_move_next;
                    automatic EvalScore iteration_best_score_next;
                    automatic NodeCountType nodes_next;
                    automatic logic node_stop_next;
                    automatic logic time_stop_next;

                    active_count_next = search_active_thread_count;
                    iteration_has_result_next = search_iteration_has_result;
                    iteration_best_move_next = search_iteration_best_move;
                    iteration_best_score_next = search_iteration_best_score;
                    nodes_next = search_nodes;

                    // The two generators may complete together, but one thread owns only one move operation.
                    if (move_cmd_resp_valid && move_quiet_resp_valid)
                        assert (move_cmd_resp_thread != move_quiet_resp_thread)
                            else $fatal(1, "simultaneous move responses targeted one thread");

                    for (int tid = 0; tid < SEARCH_THREAD_COUNT; tid++) begin
                        if (search_board_wait_count[tid] != BoardWaitCount'(0)) begin
                            search_board_wait_count[tid] <= search_board_wait_count[tid] - BoardWaitCount'(1);
                        end
                        if (search_move_wait_count[tid] != MoveWaitCount'(0)) begin
                            search_move_wait_count[tid] <= search_move_wait_count[tid] - MoveWaitCount'(1);
                        end
                        if (search_eval_wait_count[tid] != EvalWaitCount'(0)) begin
                            search_eval_wait_count[tid] <= search_eval_wait_count[tid] - EvalWaitCount'(1);
                        end
                    end

                    for (int idx = SEARCH_BOARD_TAG_PIPE_LEN - 1; idx > 0; idx--) begin
                        search_board_tag_pipe[idx] <= search_board_tag_pipe[idx - 1];
                        search_board_op_tag_pipe[idx] <= search_board_op_tag_pipe[idx - 1];
                        search_board_ply_tag_pipe[idx] <= search_board_ply_tag_pipe[idx - 1];
                        search_board_tag_valid_pipe[idx] <= search_board_tag_valid_pipe[idx - 1];
                    end
                    search_board_tag_pipe[0] <= search_board_issue_thread;
                    search_board_op_tag_pipe[0] <= board_update_op;
                    search_board_ply_tag_pipe[0] <= board_update_ply;
                    search_board_tag_valid_pipe[0] <= search_board_issue_valid;
                    for (int idx = 0; idx < SEARCH_MOVE_TAG_PIPE_LEN; idx++) begin
                        search_move_tag_valid_pipe[idx] <= 1'b0;
                    end
                    for (int idx = SEARCH_EVAL_TAG_PIPE_LEN - 1; idx > 0; idx--) begin
                        search_eval_tag_pipe[idx] <= search_eval_tag_pipe[idx - 1];
                        search_eval_tag_valid_pipe[idx] <= search_eval_tag_valid_pipe[idx - 1];
                    end
                    search_eval_tag_pipe[0] <= search_eval_issue_thread;
                    search_eval_tag_valid_pipe[0] <= search_eval_issue_valid;

                    if (search_stop_requested()) begin
                        automatic Move stop_best_move;
                        automatic EvalScore stop_score;

                        stop_best_move = NULL_MOVE;
                        stop_score = EvalScore'(0);
                        if (search_completed_depth != SearchDepth'(0)) begin
                            stop_best_move = search_completed_best_move;
                            stop_score = search_completed_score;
                        end
                        // A returned root child from the deeper in-progress iteration
                        // is usable even though that iteration's depth is not complete.
                        if (!is_null_move(search_best_move[0])
                                && (search_completed_depth == SearchDepth'(0)
                                    || search_root_best_score[0] > search_completed_score)) begin
                            stop_best_move = search_best_move[0];
                            stop_score = search_root_best_score[0];
                        end

                        resp_reg <= EngineControllerResponse'('0);
                        resp_reg.best_move <= stop_best_move;
                        resp_reg.score <= stop_score;
                        resp_reg.nodes_count <= search_nodes;
                        resp_reg.completed_depth <= search_completed_depth;
                        resp_reg.end_reason <= (active_req.operation == ENGINE_CTRL_SEARCH_NODES && search_nodes >= active_req.node_limit)
                            ? ENGINE_END_NODE_LIMIT
                            : ENGINE_END_TIME_LIMIT;
                        state <= ST_RESPOND;
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
                                search_tt_store_inflight[terminal_thread_id] <= 1'b1;
                            end else if (terminal_ply == PlyIndex'(0)) begin
                                search_thread_status[terminal_thread_id] <= SEARCH_THREAD_DONE;
                                search_thread_phase[terminal_thread_id] <= SEARCH_PHASE_DONE;
                                search_thread_completed_depth[terminal_thread_id] <= search_target_depth;
                                search_thread_completed_best_move[terminal_thread_id] <= search_best_move[terminal_thread_id];
                                if (root_result_better(
                                    terminal_thread_id,
                                    node_score,
                                    search_best_move[terminal_thread_id],
                                    iteration_has_result_next,
                                    iteration_best_score_next,
                                    iteration_best_move_next)) begin
                                    iteration_best_move_next = search_best_move[terminal_thread_id];
                                    iteration_best_score_next = node_score;
                                end
                                if (terminal_thread_id == ThreadID'(0)) iteration_has_result_next = 1'b1;
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

                            board_thread_id = search_board_tag_pipe[SEARCH_BOARD_TAG_PIPE_LEN - 1];
                            reverse_complete = search_board_op_tag_pipe[SEARCH_BOARD_TAG_PIPE_LEN - 1] == BOARD_REVERSE_MOVE_OP;
                            board_ply = search_board_ply_tag_pipe[SEARCH_BOARD_TAG_PIPE_LEN - 1];
                            child_ply = board_ply + PlyIndex'(1);
`ifndef SYNTHESIS
                            search_board_result_thread_id <= board_thread_id;
                            search_board_result_valid <= 1'b1;
`endif
                            search_board_wait_count[board_thread_id] <= BoardWaitCount'(0);
                            search_board_inflight[board_thread_id] <= 1'b0;
                            if (reverse_complete) begin
                                search_board[board_thread_id] <= board_update_out;
                                search_board_in_check[board_thread_id] <= board_update_side_in_check;
                                search_zobrist_key[board_thread_id] <= board_update_zobrist_out;
                                search_pst_eval[board_thread_id] <= board_update_pst_out;
                                search_return_move[board_thread_id] <= search_stack_top[board_thread_id].move;
                                search_return_was_scout[board_thread_id] <= search_stack_top[board_thread_id].scout_search;
                                search_return_was_reduced[board_thread_id]
                                    <= search_stack_top[board_thread_id].remaining_depth + SearchDepth'(1)
                                        < search_stack_parent_q[board_thread_id].remaining_depth;
                                search_stack_top[board_thread_id] <= search_stack_parent_q[board_thread_id];
                                if (search_stack_top[board_thread_id].count_move_on_return
                                        && search_stack_parent_q[board_thread_id].legal_move_count != 8'hff) begin
                                    search_stack_top[board_thread_id].legal_move_count
                                        <= search_stack_parent_q[board_thread_id].legal_move_count + 8'd1;
                                end
                                search_ply[board_thread_id] <= board_ply - PlyIndex'(1);
                                search_thread_phase[board_thread_id] <= SEARCH_PHASE_MOVE_WAIT;
                            end else if (board_update_mover_in_check) begin
                                // The board pipeline is stateless. Ignore the
                                // speculative result; its history entry will be
                                // overwritten by the next candidate at this ply.
                                search_thread_phase[board_thread_id] <= SEARCH_PHASE_READY;
                            end else begin
                                // A node is entered only after a speculative push
                                // proves legal. Count that committed child here so
                                // TT cutoffs, draws, and terminal children count too.
                                nodes_next += NodeCountType'(1);
                                search_thread_nodes[board_thread_id] <= search_thread_nodes[board_thread_id] + NodeCountType'(1);
                                search_board[board_thread_id] <= board_update_out;
                                search_board_in_check[board_thread_id] <= board_update_side_in_check;
                                search_zobrist_key[board_thread_id] <= board_update_zobrist_out;
                                search_pst_eval[board_thread_id] <= board_update_pst_out;
                                repetition_line_write_valid <= 1'b1;
                                repetition_line_write_thread <= board_thread_id;
                                repetition_line_write_ply <= child_ply;
                                repetition_line_write_key <= board_update_zobrist_out;
                                repetition_req_valid <= 1'b1;
                                repetition_req_thread <= board_thread_id;
                                repetition_req_ply <= child_ply;
                                repetition_req_start_ply <= committed_move_is_irreversible(
                                    search_board[board_thread_id], board_update_out, search_pending_move[board_thread_id]
                                ) ? child_ply : search_stack_top[board_thread_id].repetition_start;
                                repetition_req_key <= board_update_zobrist_out;
                                search_repetition_pending[board_thread_id] <= 1'b1;
                                search_stack_top[board_thread_id].move <= search_pending_move[board_thread_id];
                                search_stack_top[board_thread_id].best_move <= NULL_MOVE;
                                search_stack_top[board_thread_id].best_score <= -SEARCH_INF;
                                // Search the first child (and any required re-search) with the full
                                // window. Later main-search children use a one-point PVS scout window.
                                if (!search_pvs_research[board_thread_id]
                                        && search_stack_top[board_thread_id].has_legal
                                        && !search_in_qsearch(board_thread_id)) begin
                                    search_stack_top[board_thread_id].alpha <= -(search_stack_top[board_thread_id].alpha + EvalScore'(1));
                                    search_stack_top[board_thread_id].orig_alpha <= -(search_stack_top[board_thread_id].alpha + EvalScore'(1));
                                    search_stack_top[board_thread_id].beta <= -search_stack_top[board_thread_id].alpha;
                                    search_stack_top[board_thread_id].scout_search <= 1'b1;
                                end else begin
                                    search_stack_top[board_thread_id].alpha <= -search_stack_top[board_thread_id].beta;
                                    search_stack_top[board_thread_id].orig_alpha <= -search_stack_top[board_thread_id].beta;
                                    search_stack_top[board_thread_id].beta <= -search_stack_top[board_thread_id].alpha;
                                    search_stack_top[board_thread_id].scout_search <= 1'b0;
                                end
                                search_pvs_research[board_thread_id] <= 1'b0;
                                search_stack_top[board_thread_id].remaining_depth <= search_pending_child_depth[board_thread_id];
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
                                search_stack_top[board_thread_id].direct_attempted <= 1'b0;
                                search_stack_top[board_thread_id].tt_checked <= 1'b0;
                                search_stack_top[board_thread_id].has_tt_move <= 1'b0;
                                search_stack_top[board_thread_id].stand_pat_done <= 1'b0;
                                search_eval_is_stand_pat[board_thread_id] <= 1'b0;
                                search_return_valid[board_thread_id] <= 1'b0;
                                search_ply[board_thread_id] <= child_ply;
                                search_thread_phase[board_thread_id] <= SEARCH_PHASE_REPETITION_WAIT;
                            end
                        end

                        if (move_cmd_resp_valid) begin
                            automatic ThreadID move_thread_id;
                            move_thread_id = move_cmd_resp_thread;
                            search_move_result_thread_id <= move_thread_id;
                            search_move_result_valid <= 1'b1;
                            search_move_wait_count[move_thread_id] <= MoveWaitCount'(0);
                            search_move_inflight[move_thread_id] <= 1'b0;
                            search_stack_top[move_thread_id].bucket_tops <= move_cmd_resp_tops;
                            if (search_stack_top[move_thread_id].move_order_state == MOVE_ORDER_DIRECT) begin
                                search_stack_top[move_thread_id].move_order_state <= MOVE_ORDER_GENERATE_NOISY;
                                if (move_cmd_resp_direct_valid) begin
                                    search_stack_top[move_thread_id].direct_attempted <= 1'b1;
                                    search_stack_top[move_thread_id].tt_move <= move_cmd_resp_direct_move;
                                    search_pending_move[move_thread_id] <= move_cmd_resp_direct_move;
                                    search_thread_phase[move_thread_id] <= SEARCH_PHASE_BOARD_WAIT;
                                end else begin
                                    search_thread_phase[move_thread_id] <= SEARCH_PHASE_READY;
                                end
                            end else begin
                                search_stack_top[move_thread_id].move_order_state <= MOVE_ORDER_GOOD_NOISY;
                                search_thread_phase[move_thread_id] <= SEARCH_PHASE_READY;
                            end
                        end

                        if (move_quiet_resp_valid) begin
                            automatic ThreadID move_thread_id;
                            move_thread_id = move_quiet_resp_thread;
                            search_move_result_thread_id <= move_thread_id;
                            search_move_result_valid <= 1'b1;
                            search_move_wait_count[move_thread_id] <= MoveWaitCount'(0);
                            search_move_inflight[move_thread_id] <= 1'b0;
                            search_stack_top[move_thread_id].bucket_tops
                                <= move_quiet_resp_tops;
                            search_stack_top[move_thread_id].move_order_state
                                <= MOVE_ORDER_QUIET;
                            search_thread_phase[move_thread_id] <= SEARCH_PHASE_READY;
                        end

                        if (move_pop_resp_valid) begin
                            automatic ThreadID move_thread_id;
                            move_thread_id = move_pop_resp_thread;
                            search_move_result_thread_id <= move_thread_id;
                            search_move_result_valid <= 1'b1;
                            search_move_wait_count[move_thread_id] <= MoveWaitCount'(0);
                            search_move_inflight[move_thread_id] <= 1'b0;
                            if (move_pop_resp_found) begin
                                search_stack_top[move_thread_id].bucket_tops[move_pop_resp_bucket]
                                    <= move_pop_resp_new_top;
                                search_pending_move[move_thread_id] <= move_pop_resp_move;
                                search_thread_phase[move_thread_id] <= SEARCH_PHASE_BOARD_WAIT;
                            end else begin
                                case (search_stack_top[move_thread_id].move_order_state)
                                    MOVE_ORDER_GOOD_NOISY:
                                        search_stack_top[move_thread_id].move_order_state
                                            <= search_in_qsearch(move_thread_id)
                                                ? MOVE_ORDER_BAD_NOISY : MOVE_ORDER_GENERATE_QUIET;
                                    MOVE_ORDER_QUIET:
                                        search_stack_top[move_thread_id].move_order_state <= MOVE_ORDER_BAD_NOISY;
                                    default:
                                        search_stack_top[move_thread_id].move_order_state <= MOVE_ORDER_DONE;
                                endcase
                                search_thread_phase[move_thread_id] <= SEARCH_PHASE_READY;
                            end
                        end

                        if (search_eval_tag_valid_pipe[SEARCH_EVAL_TAG_PIPE_LEN - 1]) begin
                            automatic EvalScore eval_score;
                            automatic ThreadID eval_thread_id;
                            automatic PlyIndex eval_ply;

                            eval_thread_id = search_eval_tag_pipe[SEARCH_EVAL_TAG_PIPE_LEN - 1];
                            eval_ply = search_ply[eval_thread_id];
                            search_eval_result_thread_id <= eval_thread_id;
                            search_eval_result_valid <= 1'b1;
                            search_eval_wait_count[eval_thread_id] <= EvalWaitCount'(0);
                            search_eval_inflight[eval_thread_id] <= 1'b0;
                            eval_score = pov_eval(search_board[eval_thread_id], static_eval_out);

                            if (search_eval_is_stand_pat[eval_thread_id]) begin
                                search_stack_top[eval_thread_id].stand_pat_done <= 1'b1;
                                search_stack_top[eval_thread_id].best_score <= eval_score;
                                if (eval_score > search_stack_top[eval_thread_id].alpha) begin
                                    search_stack_top[eval_thread_id].alpha <= eval_score;
                                end
                                if (eval_score >= search_stack_top[eval_thread_id].beta) begin
                                    search_return_score[eval_thread_id] <= eval_score;
                                    search_return_valid[eval_thread_id] <= 1'b1;
                                    if (eval_ply == PlyIndex'(0)) begin
                                        search_thread_status[eval_thread_id] <= SEARCH_THREAD_DONE;
                                        search_thread_phase[eval_thread_id] <= SEARCH_PHASE_DONE;
                                        search_thread_completed_depth[eval_thread_id] <= search_target_depth;
                                        search_thread_completed_best_move[eval_thread_id] <= NULL_MOVE;
                                        if (root_result_better(
                                                eval_thread_id,
                                                eval_score,
                                                NULL_MOVE,
                                                iteration_has_result_next,
                                                iteration_best_score_next,
                                                iteration_best_move_next)) begin
                                            iteration_best_move_next = NULL_MOVE;
                                            iteration_best_score_next = eval_score;
                                        end
                                        if (eval_thread_id == ThreadID'(0)) iteration_has_result_next = 1'b1;
                                        if (active_count_next != ThreadCount'(0)) active_count_next -= ThreadCount'(1);
                                    end else begin
                                        search_thread_phase[eval_thread_id] <= SEARCH_PHASE_REVERSE_WAIT;
                                    end
                                end else begin
                                    search_thread_phase[eval_thread_id] <= SEARCH_PHASE_READY;
                                end
                            end else begin
                                search_return_score[eval_thread_id] <= eval_score;
                                search_return_valid[eval_thread_id] <= 1'b1;
                                if (eval_ply == PlyIndex'(0)) begin
                                    search_thread_status[eval_thread_id] <= SEARCH_THREAD_DONE;
                                    search_thread_phase[eval_thread_id] <= SEARCH_PHASE_DONE;
                                    search_thread_completed_depth[eval_thread_id] <= search_target_depth;
                                    search_thread_completed_best_move[eval_thread_id] <= NULL_MOVE;
                                    if (root_result_better(
                                            eval_thread_id,
                                            eval_score,
                                            NULL_MOVE,
                                            iteration_has_result_next,
                                            iteration_best_score_next,
                                            iteration_best_move_next)) begin
                                        iteration_best_move_next = NULL_MOVE;
                                        iteration_best_score_next = eval_score;
                                    end
                                    if (eval_thread_id == ThreadID'(0)) iteration_has_result_next = 1'b1;
                                    if (active_count_next != ThreadCount'(0)) active_count_next -= ThreadCount'(1);
                                end else begin
                                    search_thread_phase[eval_thread_id] <= SEARCH_PHASE_REVERSE_WAIT;
                                end
                            end
                        end

                        if (|search_tt_response_mask) begin
                            automatic EvalScore tt_alpha_after;
                            automatic logic tt_cutoff;
                            automatic ThreadID lookup_thread_id;
                            automatic PlyIndex lookup_ply;
                            automatic TTLookupResponse lookup_resp;

                            lookup_thread_id = search_select_thread(
                                search_tt_response_mask,
                                search_dispatch.tt_response
                            );
                            lookup_resp = search_tt_response[lookup_thread_id];
                            lookup_ply = search_ply[lookup_thread_id];
                            tt_alpha_after = search_stack_top[lookup_thread_id].alpha;
                            tt_cutoff = 1'b0;
                            search_thread_id <= lookup_thread_id;
                            search_dispatch.tt_response <= search_thread_after(lookup_thread_id);
                            search_tt_response_pending[lookup_thread_id] <= 1'b0;

                            // A matching TT move remains useful for ordering even when the
                            // stored depth is too shallow for its score/bound to be usable.
                            if (lookup_resp.hit) begin
                                search_stack_top[lookup_thread_id].tt_move <= lookup_resp.best_move;
                                search_stack_top[lookup_thread_id].has_tt_move <= !is_null_move(lookup_resp.best_move);
                            end
                            if (lookup_resp.hit && lookup_resp.depth >= search_remaining_depth(lookup_thread_id)) begin
                                if (lookup_resp.bound_type == TT_BOUND_EXACT) begin
                                    search_return_score[lookup_thread_id] <= lookup_resp.score;
                                    search_return_valid[lookup_thread_id] <= 1'b1;
                                    tt_cutoff = 1'b1;
                                end else if (lookup_resp.bound_type == TT_BOUND_LOWER) begin
                                    if (lookup_resp.score > search_stack_top[lookup_thread_id].alpha) begin
                                        tt_alpha_after = lookup_resp.score;
                                        search_stack_top[lookup_thread_id].alpha <= lookup_resp.score;
                                    end
                                    if (tt_alpha_after >= search_stack_top[lookup_thread_id].beta) begin
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
                            end

                            if (tt_cutoff) begin
                                if (lookup_ply == PlyIndex'(0)) begin
                                    search_thread_status[lookup_thread_id] <= SEARCH_THREAD_DONE;
                                    search_thread_phase[lookup_thread_id] <= SEARCH_PHASE_DONE;
                                    search_thread_completed_depth[lookup_thread_id] <= search_target_depth;
                                    search_thread_completed_best_move[lookup_thread_id] <= lookup_resp.best_move;
                                    if (root_result_better(
                                            lookup_thread_id,
                                            lookup_resp.score,
                                            lookup_resp.best_move,
                                            iteration_has_result_next,
                                            iteration_best_score_next,
                                            iteration_best_move_next)) begin
                                        iteration_best_move_next = lookup_resp.best_move;
                                        iteration_best_score_next = lookup_resp.score;
                                    end
                                    if (lookup_thread_id == ThreadID'(0)) iteration_has_result_next = 1'b1;
                                    if (active_count_next != ThreadCount'(0)) active_count_next -= ThreadCount'(1);
                                end else begin
                                    search_thread_phase[lookup_thread_id] <= SEARCH_PHASE_REVERSE_WAIT;
                                end
                            end else begin
                                search_thread_phase[lookup_thread_id] <= SEARCH_PHASE_READY;
                            end
                        end

                        if (|search_return_mask) begin
                            automatic ThreadID return_thread_id;
                            automatic EvalScore parent_score;
                            automatic PlyIndex return_ply;

                            return_thread_id = search_select_thread(
                                search_return_mask,
                                search_dispatch.return_result
                            );
                            return_ply = search_ply[return_thread_id];
                            parent_score = -search_return_score[return_thread_id];
                            search_thread_id <= return_thread_id;
                            search_dispatch.return_result <= search_thread_after(return_thread_id);
                            if (search_needs_research(
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
                                if (!search_stack_top[return_thread_id].has_legal
                                        || parent_score > search_stack_top[return_thread_id].best_score) begin
                                    search_stack_top[return_thread_id].best_score <= parent_score;
                                    search_stack_top[return_thread_id].best_move <= search_return_move[return_thread_id];
                                    if (return_ply == PlyIndex'(0)) begin
                                        search_best_move[return_thread_id] <= search_return_move[return_thread_id];
                                        search_root_best_score[return_thread_id] <= parent_score;
                                    end
                                end
                                search_stack_top[return_thread_id].has_legal <= 1'b1;
                                if (parent_score > search_stack_top[return_thread_id].alpha) begin
                                    search_stack_top[return_thread_id].alpha <= parent_score;
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
                                            <= 6'(search_stack_top[return_thread_id].remaining_depth);
                                    end
                                    search_return_score[return_thread_id] <= parent_score;
                                    search_return_valid[return_thread_id] <= 1'b1;
                                    if (should_store_search_tt(return_thread_id, return_ply)) begin
                                        search_thread_phase[return_thread_id] <= SEARCH_PHASE_STORE_PUBLISH;
                                        search_tt_store_inflight[return_thread_id] <= 1'b1;
                                    end else if (return_ply == PlyIndex'(0)) begin
                                        automatic Move root_move;

                                        root_move = (is_null_move(search_best_move[return_thread_id]) && !is_null_move(search_return_move[return_thread_id]))
                                            ? search_return_move[return_thread_id]
                                            : search_best_move[return_thread_id];
                                        search_thread_status[return_thread_id] <= SEARCH_THREAD_DONE;
                                        search_thread_phase[return_thread_id] <= SEARCH_PHASE_DONE;
                                        search_thread_completed_depth[return_thread_id] <= search_target_depth;
                                        search_thread_completed_best_move[return_thread_id] <= root_move;
                                        if (root_result_better(
                                                return_thread_id,
                                                parent_score,
                                                root_move,
                                                iteration_has_result_next,
                                                iteration_best_score_next,
                                                iteration_best_move_next)) begin
                                            iteration_best_move_next = root_move;
                                            iteration_best_score_next = parent_score;
                                        end
                                        if (return_thread_id == ThreadID'(0)) iteration_has_result_next = 1'b1;
                                        if (active_count_next != ThreadCount'(0)) active_count_next -= ThreadCount'(1);
                                    end else begin
                                        search_thread_phase[return_thread_id] <= SEARCH_PHASE_REVERSE_WAIT;
                                    end
                                end else begin
                                    search_thread_phase[return_thread_id] <= SEARCH_PHASE_READY;
                                end
                            end
                        end

                        if (|search_ready_mask) begin
                            automatic ThreadID terminal_thread_id;
                            automatic logic found_terminal;
                            automatic logic terminal_is_no_move;

                            found_terminal = 1'b0;
                            terminal_is_no_move = 1'b0;
                            terminal_thread_id = ThreadID'(0);
                            for (int offset = 0; offset < SEARCH_THREAD_COUNT; offset++) begin
                                automatic int idx = search_wrap_thread_index(int'(search_dispatch.main) + offset);
                                if (!found_terminal && search_thread_ready(idx)
                                        && search_stack_top[idx].move_order_state == MOVE_ORDER_DONE) begin
                                    found_terminal = 1'b1;
                                    terminal_is_no_move = 1'b1;
                                    terminal_thread_id = ThreadID'(idx);
                                end
                            end
                            for (int offset = 0; offset < SEARCH_THREAD_COUNT; offset++) begin
                                automatic int idx = search_wrap_thread_index(int'(search_dispatch.main) + offset);
                                if (!found_terminal && search_thread_terminal_draw_ready(idx)) begin
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
                                    search_thread_status[terminal_thread_id] <= SEARCH_THREAD_DONE;
                                    search_thread_phase[terminal_thread_id] <= SEARCH_PHASE_DONE;
                                    search_thread_completed_depth[terminal_thread_id] <= search_target_depth;
                                    search_thread_completed_best_move[terminal_thread_id] <= NULL_MOVE;
                                    if (root_result_better(
                                            terminal_thread_id,
                                            DRAW_EVAL_SCORE,
                                            NULL_MOVE,
                                            iteration_has_result_next,
                                            iteration_best_score_next,
                                            iteration_best_move_next)) begin
                                        iteration_best_move_next = NULL_MOVE;
                                        iteration_best_score_next = DRAW_EVAL_SCORE;
                                    end
                                    if (terminal_thread_id == ThreadID'(0)) iteration_has_result_next = 1'b1;
                                    if (active_count_next != ThreadCount'(0)) active_count_next -= ThreadCount'(1);
                                end else if (!terminal_is_no_move) begin
                                    search_thread_phase[terminal_thread_id] <= SEARCH_PHASE_REVERSE_WAIT;
                                end
                            end
                        end

                        if (search_tt_lookup_issue_valid && tt_lookup_req_ready) begin
                            search_thread_id <= search_tt_lookup_issue_thread;
                            search_stack_top[search_tt_lookup_issue_thread].tt_checked <= 1'b1;
                            search_thread_phase[search_tt_lookup_issue_thread] <= SEARCH_PHASE_TT_WAIT;
                            search_tt_lookup_inflight[search_tt_lookup_issue_thread] <= 1'b1;
                            search_dispatch.tt_lookup <= search_thread_after(search_tt_lookup_issue_thread);
                        end

                        if (search_eval_issue_valid) begin
                            search_thread_id <= search_eval_issue_thread;
                            search_eval_wait_count[search_eval_issue_thread] <= EvalWaitCount'(EVAL_WAIT_CYCLES);
                            search_thread_phase[search_eval_issue_thread] <= SEARCH_PHASE_EVAL_WAIT;
                            search_eval_inflight[search_eval_issue_thread] <= 1'b1;
                            search_eval_is_stand_pat[search_eval_issue_thread] <= search_in_qsearch(search_eval_issue_thread)
                                && !search_stack_top[search_eval_issue_thread].stand_pat_done;
                            search_dispatch.eval <= search_thread_after(search_eval_issue_thread);
                        end

                        if (search_move_issue_valid
                                && ((move_cmd_valid && move_cmd_ready)
                                    || (move_pop_valid && move_pop_ready))) begin
                            search_thread_id <= search_move_issue_thread;
                            search_move_wait_count[search_move_issue_thread] <= MoveWaitCount'(MOVE_WAIT_CYCLES);
                            search_thread_phase[search_move_issue_thread] <= SEARCH_PHASE_MOVE_WAIT;
                            search_move_inflight[search_move_issue_thread] <= 1'b1;
                            if (search_stack_top[search_move_issue_thread].move_order_state == MOVE_ORDER_DIRECT
                                    && move_cmd == MOVE_GEN_GENERATE_NOISY) begin
                                search_stack_top[search_move_issue_thread].move_order_state
                                    <= MOVE_ORDER_GENERATE_NOISY;
                            end else if (move_cmd_valid && move_cmd == MOVE_GEN_VALIDATE_DIRECT) begin
                                search_stack_top[search_move_issue_thread].tt_move <= move_cmd_suppress_move;
                                search_stack_top[search_move_issue_thread].has_tt_move <= 1'b1;
                            end
                            search_dispatch.move <= search_thread_after(search_move_issue_thread);
                        end

                        if (search_quiet_issue_valid
                                && move_quiet_cmd_valid && move_quiet_cmd_ready) begin
                            search_thread_id <= search_quiet_issue_thread;
                            search_move_wait_count[search_quiet_issue_thread]
                                <= MoveWaitCount'(MOVE_WAIT_CYCLES);
                            search_thread_phase[search_quiet_issue_thread]
                                <= SEARCH_PHASE_MOVE_WAIT;
                            search_move_inflight[search_quiet_issue_thread] <= 1'b1;
                            search_dispatch.quiet
                                <= search_thread_after(search_quiet_issue_thread);
                        end

                        if (search_board_issue_valid) begin
                            search_thread_id <= search_board_issue_thread;
                            search_board_wait_count[search_board_issue_thread] <= BoardWaitCount'(BOARD_UPDATE_PIPELINE_STAGE_CNT - 1);
                            search_thread_phase[search_board_issue_thread] <= SEARCH_PHASE_BOARD_WAIT;
                            search_board_inflight[search_board_issue_thread] <= 1'b1;
                            if (search_thread_phase[search_board_issue_thread] != SEARCH_PHASE_REVERSE_WAIT) begin
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
                                    search_pending_child_depth[search_board_issue_thread] <= lmr_child_depth(search_board_issue_thread);
`ifndef SYNTHESIS
                                    assert (floor_log2_8(8'(search_stack_top[search_board_issue_thread].remaining_depth))
                                            < LMR_DEPTH_BUCKETS);
                                    assert (lmr_child_depth(search_board_issue_thread)
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
                            search_tt_store_inflight[store_thread_id] <= 1'b0;
                            search_return_valid[store_thread_id] <= 1'b1;
                            if (store_ply == PlyIndex'(0)) begin
                                search_thread_status[store_thread_id] <= SEARCH_THREAD_DONE;
                                search_thread_phase[store_thread_id] <= SEARCH_PHASE_DONE;
                                search_thread_completed_depth[store_thread_id] <= search_target_depth;
                                search_thread_completed_best_move[store_thread_id] <= search_stack_top[store_thread_id].best_move;
                                if (root_result_better(
                                        store_thread_id,
                                        search_return_score[store_thread_id],
                                        search_stack_top[store_thread_id].best_move,
                                        iteration_has_result_next,
                                        iteration_best_score_next,
                                        iteration_best_move_next)) begin
                                    iteration_best_move_next = search_stack_top[store_thread_id].best_move;
                                    iteration_best_score_next = search_return_score[store_thread_id];
                                end
                                if (store_thread_id == ThreadID'(0)) iteration_has_result_next = 1'b1;
                                if (active_count_next != ThreadCount'(0)) active_count_next -= ThreadCount'(1);
                            end else begin
                                search_thread_phase[store_thread_id] <= SEARCH_PHASE_REVERSE_WAIT;
                            end
                        end

                        search_nodes <= nodes_next;
                        search_active_thread_count <= active_count_next;
                        search_iteration_has_result <= iteration_has_result_next;
                        search_iteration_best_move <= iteration_best_move_next;
                        search_iteration_best_score <= iteration_best_score_next;

                        node_stop_next = active_req.operation == ENGINE_CTRL_SEARCH_NODES && nodes_next >= active_req.node_limit;
                        time_stop_next = (active_req.operation == ENGINE_CTRL_SEARCH_FIXED_TIME || active_req.operation == ENGINE_CTRL_SEARCH_ON_CLOCK)
                            && elapsed_ms >= search_budget_ms;
                        if (active_count_next == ThreadCount'(0) && iteration_has_result_next) begin
                            if (search_aspiration_active
                                    && (iteration_best_score_next <= search_root_alpha
                                        || iteration_best_score_next >= search_root_beta)) begin
                                // A failed narrow pass is only a bound. Retry the same
                                // depth once with the full window before publishing it.
                                search_root_alpha <= -SEARCH_INF;
                                search_root_beta <= SEARCH_INF;
                                search_aspiration_active <= 1'b0;
                                search_active_thread_count <= ThreadCount'(0);
                                search_iteration_has_result <= 1'b0;
                                search_iteration_best_move <= NULL_MOVE;
                                search_iteration_best_score <= -SEARCH_INF;
                                if (node_stop_next || time_stop_next) begin
                                    resp_reg <= EngineControllerResponse'('0);
                                    resp_reg.best_move <= search_completed_best_move;
                                    resp_reg.score <= search_completed_score;
                                    resp_reg.nodes_count <= nodes_next;
                                    resp_reg.completed_depth <= search_completed_depth;
                                    resp_reg.end_reason <= node_stop_next ? ENGINE_END_NODE_LIMIT : ENGINE_END_TIME_LIMIT;
                                    state <= ST_RESPOND;
                                end else begin
                                    state <= ST_SEARCH_ITER_START;
                                end
                            end else begin
                                search_completed_depth <= search_target_depth;
                                search_completed_best_move <= iteration_best_move_next;
                                search_completed_score <= iteration_best_score_next;
                                resp_reg <= EngineControllerResponse'('0);
                                resp_reg.best_move <= iteration_best_move_next;
                                resp_reg.score <= iteration_best_score_next;
                                resp_reg.nodes_count <= nodes_next;
                                resp_reg.completed_depth <= search_target_depth;
                                if (active_req.operation == ENGINE_CTRL_SEARCH_DEPTH && search_target_depth >= search_max_depth) begin
                                    resp_reg.end_reason <= ENGINE_END_DEPTH_LIMIT;
                                    state <= ST_RESPOND;
                                end else if (node_stop_next) begin
                                    resp_reg.end_reason <= ENGINE_END_NODE_LIMIT;
                                    state <= ST_RESPOND;
                                end else if (time_stop_next) begin
                                    resp_reg.end_reason <= ENGINE_END_TIME_LIMIT;
                                    state <= ST_RESPOND;
                                end else if (search_target_depth >= search_max_depth) begin
                                    resp_reg.end_reason <= ENGINE_END_DEPTH_LIMIT;
                                    state <= ST_RESPOND;
                                end else begin
                                    search_target_depth <= search_target_depth + SearchDepth'(1);
                                    if (active_req.operation == ENGINE_CTRL_SEARCH_DEPTH) begin
                                        search_root_alpha <= aspiration_lower_bound(iteration_best_score_next);
                                        search_root_beta <= aspiration_upper_bound(iteration_best_score_next);
                                        search_aspiration_active <= 1'b1;
                                    end else begin
                                        // A failed retry can consume a move deadline, so bounded
                                        // searches retain the full root window.
                                        search_root_alpha <= -SEARCH_INF;
                                        search_root_beta <= SEARCH_INF;
                                        search_aspiration_active <= 1'b0;
                                    end
                                    search_thread_id <= ThreadID'(0);
                                    search_dispatch <= '0;
                                    search_active_thread_count <= ThreadCount'(0);
                                    search_iteration_has_result <= 1'b0;
                                    search_iteration_best_move <= NULL_MOVE;
                                    search_iteration_best_score <= -SEARCH_INF;
                                    state <= ST_SEARCH_ITER_START;
                                end
                            end
                        end else begin
                            state <= ST_SEARCH_RUN;
                        end
                    end
                end

                ST_RESPOND: begin
                    resp_valid <= 1'b1;
                    state <= ST_IDLE;
                end

                ST_KILL_DONE: begin
                    resp_valid <= 1'b1;
                    state <= ST_IDLE;
                end

                default: begin
                    resp_reg <= EngineControllerResponse'('0);
                    resp_reg.error <= 1'b1;
                    resp_reg.end_reason <= ENGINE_END_ERROR;
                    state <= ST_RESPOND;
                end
            endcase
            end
        end
    end

endmodule : search_controller
