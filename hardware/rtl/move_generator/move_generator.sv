// Dual-class frontend with per-thread readers that preserve global bucket priority.

import chess_defs::*;
import move_generator_defs::*;

module move_generator #(
    parameter int THREAD_COUNT = 1,
    parameter int SEARCH_STACK_DEPTH = 32,
    parameter int MOVE_MEMORY_ENTRIES = 2048,
    parameter int MOVE_BUCKET_0_RATIO = 48,
    parameter int MOVE_BUCKET_1_RATIO = 16,
    parameter int MOVE_BUCKET_2_RATIO = 192,
    parameter int MOVE_BUCKET_3_RATIO = 64,
    parameter int MOVE_BUCKET_4_RATIO = 64,
    parameter int MOVE_BUCKET_5_RATIO = 32,
    parameter int MOVE_BUCKET_6_RATIO = 64,
    parameter int MOVE_BUCKET_7_RATIO = 32,
    parameter int HISTORY_ENTRY_COUNT = 8192,
    parameter int HISTORY_ENTRY_BITS = 8,
    parameter int HISTORY_REWARD_PER_DEPTH = 2,
    parameter int HISTORY_MAXIMUM_REWARD = 31,
    parameter int HISTORY_MALUS_DIVISOR = 2,
    parameter int QUIET_THRESHOLD_1 = 8,
    parameter int QUIET_THRESHOLD_2 = 32,
    parameter int QUIET_THRESHOLD_3 = 64,
    parameter int CASTLING_HISTORY_BONUS = 8,
    parameter bit ENABLE_STATS = 1'b0
) (
    input logic clk,
    input logic rst_n,
    input logic clear,
    input logic flush,
    output logic init_busy,

    input logic noisy_cmd_valid,
    output logic noisy_cmd_ready,
    input MoveGenCommand noisy_cmd,
    input ThreadID noisy_cmd_thread,
    input PlyIndex noisy_cmd_ply,
    input FullBoard noisy_cmd_board,
    input logic noisy_cmd_suppress_valid,
    input Move noisy_cmd_suppress_move,
    output logic noisy_resp_valid,
    output ThreadID noisy_resp_thread,
    output PlyIndex noisy_resp_ply,
    output logic noisy_resp_direct_valid,
    output Move noisy_resp_direct_move,

    input logic quiet_cmd_valid,
    output logic quiet_cmd_ready,
    input ThreadID quiet_cmd_thread,
    input PlyIndex quiet_cmd_ply,
    input FullBoard quiet_cmd_board,
    input logic quiet_cmd_suppress_valid,
    input Move quiet_cmd_suppress_move,
    output logic quiet_resp_valid,
    output ThreadID quiet_resp_thread,
    output PlyIndex quiet_resp_ply,

    input logic pop_valid[THREAD_COUNT],
    output logic pop_ready[THREAD_COUNT],
    input PlyIndex pop_ply[THREAD_COUNT],
    input logic node_init_valid[THREAD_COUNT],
    output logic node_init_ready[THREAD_COUNT],
    input PlyIndex node_init_ply[THREAD_COUNT],
    input logic bad_noisy_enable[THREAD_COUNT],
    output logic pop_resp_valid[THREAD_COUNT],
    input logic pop_resp_ready[THREAD_COUNT],
    output PlyIndex pop_resp_ply[THREAD_COUNT],
    output logic pop_resp_found[THREAD_COUNT],
    output Move pop_resp_move[THREAD_COUNT],
    output MoveBucketIndex pop_resp_bucket[THREAD_COUNT],

    input logic history_update_valid,
    output logic history_update_ready,
    input ThreadID history_update_thread,
    input Color history_update_color,
    input Position history_update_from,
    input Position history_update_to,
    input PlyIndex history_update_depth,
    input logic [11:0] history_update_failed0,
    input logic [11:0] history_update_failed1,
    input logic [11:0] history_update_failed2,
    input logic [1:0] history_update_failed_count,

    output logic overflow_sticky,
    output logic [39:0] stat_noisy_count,
    output logic [39:0] stat_quiet_count,
    output logic [39:0] stat_destination_count,
    output logic [39:0] stat_candidate_count,
    output logic [39:0] stat_history_lookup_count,
    output logic [39:0] stat_generation_cycles,
    output logic [39:0] stat_bucket_count [MOVE_BUCKET_COUNT],
    output MoveBucketTop stat_bucket_high_water [MOVE_BUCKET_COUNT]
);

    localparam MoveBucketMask NOISY_BUCKET_MASK =
        GOOD_NOISY_BUCKET_MASK | BAD_NOISY_BUCKET_MASK;

    logic noisy_init_busy, quiet_init_busy, history_init_busy;
    logic quiet_lane_cmd_ready, noisy_lane_cmd_ready;
    logic noisy_admit, quiet_admit, reader_ready[THREAD_COUNT], reader_valid[THREAD_COUNT];
    logic starting_pop_node[THREAD_COUNT];
    logic quiet_history_update_ready;
    logic live_active[2], write_valid[2];
    ThreadID live_thread[2];
    PlyIndex live_ply[2];
    Move write_move[2];
    MoveBucketIndex write_bucket[2];
    MoveBucketTop write_top[2];
    logic generation_request_valid[2], generation_start_accept[2];
    logic generation_start_valid[2], generation_start_ready[2];
    ThreadID generation_thread[2], generation_start_thread[2];
    PlyIndex generation_ply[2], generation_start_ply[2];
    logic [39:0] noisy_stat_noisy_count, quiet_stat_noisy_count;
    logic [39:0] noisy_stat_quiet_count, quiet_stat_quiet_count;
    logic [39:0] noisy_stat_destination_count, quiet_stat_destination_count;
    logic [39:0] noisy_stat_candidate_count, quiet_stat_candidate_count;
    logic [39:0] noisy_stat_history_lookup_count, quiet_stat_history_lookup_count;
    logic [39:0] noisy_stat_generation_cycles, quiet_stat_generation_cycles;
    logic [39:0] noisy_stat_bucket_count[MOVE_BUCKET_COUNT];
    logic [39:0] quiet_stat_bucket_count[MOVE_BUCKET_COUNT];
    MoveBucketTop noisy_stat_bucket_high_water[MOVE_BUCKET_COUNT];
    MoveBucketTop quiet_stat_bucket_high_water[MOVE_BUCKET_COUNT];

    logic quiet_history_lookup_valid;
    ThreadID quiet_history_lookup_thread;
    Color quiet_history_lookup_color;
    Position quiet_history_lookup_from, quiet_history_lookup_to;
    logic signed [HISTORY_ENTRY_BITS-1:0] quiet_history_lookup_value;

    assign init_busy = noisy_init_busy || quiet_init_busy || history_init_busy;
    // Each thread has one write port. Arbitrate jobs before accepting them;
    // accepted generators never wait for storage or readers.
    assign noisy_admit = !init_busy && !flush && !clear
        && !(live_active[1] && live_thread[1] == noisy_cmd_thread)
        && (noisy_cmd == MOVE_GEN_VALIDATE_DIRECT || generation_start_ready[0]);
    assign noisy_cmd_ready = noisy_lane_cmd_ready && noisy_admit;
    assign quiet_admit = !init_busy && !flush && !clear
        && !(live_active[0] && live_thread[0] == quiet_cmd_thread)
        && !(noisy_cmd_valid && noisy_cmd_ready && noisy_cmd_thread == quiet_cmd_thread)
        && generation_start_ready[1];
    assign quiet_cmd_ready = quiet_lane_cmd_ready && quiet_admit;
    assign history_update_ready = quiet_history_update_ready;
    always_comb for (int tid = 0; tid < THREAD_COUNT; tid++) begin
        starting_pop_node[tid] = (noisy_cmd_valid && noisy_cmd_ready
                && noisy_cmd != MOVE_GEN_VALIDATE_DIRECT
                && noisy_cmd_thread == ThreadID'(tid) && noisy_cmd_ply == pop_ply[tid])
            || (quiet_cmd_valid && quiet_cmd_ready && quiet_cmd_thread == ThreadID'(tid)
                && quiet_cmd_ply == pop_ply[tid]);
        pop_ready[tid] = reader_ready[tid] && !init_busy && !starting_pop_node[tid];
        reader_valid[tid] = pop_valid[tid] && pop_ready[tid];
    end
    assign generation_start_accept[0] = noisy_cmd_valid && noisy_cmd_ready
        && noisy_cmd == MOVE_GEN_GENERATE_NOISY;
    assign generation_start_accept[1] = quiet_cmd_valid && quiet_cmd_ready;
    assign generation_request_valid[0]
        = noisy_cmd_valid && noisy_cmd == MOVE_GEN_GENERATE_NOISY;
    assign generation_request_valid[1] = quiet_cmd_valid;
    assign generation_thread[0] = noisy_cmd_thread;
    assign generation_thread[1] = quiet_cmd_thread;
    assign generation_ply[0] = noisy_cmd_ply;
    assign generation_ply[1] = quiet_cmd_ply;

    // Register accepted generation ownership before updating the pointer RAM,
    // keeping controller scheduling logic off the RAM write-data path.
    always_ff @(posedge clk) begin
        if (!rst_n || clear || flush) begin
            generation_start_valid[0] <= 1'b0;
            generation_start_valid[1] <= 1'b0;
        end else begin
            for (int lane = 0; lane < 2; lane++) begin
                generation_start_valid[lane] <= generation_start_accept[lane];
                if (generation_start_accept[lane]) begin
                    generation_start_thread[lane] <= generation_thread[lane];
                    generation_start_ply[lane] <= generation_ply[lane];
                end
            end
        end
    end

    move_generator_read_pipeline #(
        .THREAD_COUNT(THREAD_COUNT), .SEARCH_STACK_DEPTH(SEARCH_STACK_DEPTH),
        .MEMORY_ENTRIES(MOVE_MEMORY_ENTRIES),
        .BUCKET_RATIOS('{MOVE_BUCKET_0_RATIO, MOVE_BUCKET_1_RATIO,
            MOVE_BUCKET_2_RATIO, MOVE_BUCKET_3_RATIO, MOVE_BUCKET_4_RATIO,
            MOVE_BUCKET_5_RATIO, MOVE_BUCKET_6_RATIO, MOVE_BUCKET_7_RATIO})
    ) reader (
        .clk, .rst_n, .clear, .flush,
        .pop_valid(reader_valid), .pop_ready(reader_ready),
        .pop_ply, .node_init_valid, .node_init_ready, .node_init_ply, .bad_noisy_enable,
        .pop_resp_valid, .pop_resp_ready, .pop_resp_ply, .pop_resp_found,
        .pop_resp_move, .pop_resp_bucket,
        .generation_request_valid, .generation_start_valid, .generation_start_ready,
        .generation_request_thread(generation_thread),
        .generation_request_ply(generation_ply),
        .generation_start_thread, .generation_start_ply,
        .live_active, .live_thread, .live_ply,
        .write_valid, .write_move, .write_bucket, .write_top,
        .overflow_sticky
    );

    // History owns one shared RAM and a private best-effort update pipeline;
    // the quiet generator's synchronous lookups always take read priority.
    move_generator_quiet_history #(
        .HISTORY_ENTRY_COUNT(HISTORY_ENTRY_COUNT),
        .HISTORY_ENTRY_BITS(HISTORY_ENTRY_BITS),
        .REWARD_PER_DEPTH(HISTORY_REWARD_PER_DEPTH),
        .MAXIMUM_REWARD(HISTORY_MAXIMUM_REWARD),
        .MALUS_DIVISOR(HISTORY_MALUS_DIVISOR)
    ) quiet_history (
        .clk, .rst_n, .clear, .init_busy(history_init_busy),
        .lookup_valid(quiet_history_lookup_valid),
        .lookup_thread(quiet_history_lookup_thread),
        .lookup_color(quiet_history_lookup_color),
        .lookup_from(quiet_history_lookup_from),
        .lookup_to(quiet_history_lookup_to),
        .lookup_value(quiet_history_lookup_value),
        .update_valid(history_update_valid), .update_ready(quiet_history_update_ready),
        .update_thread(history_update_thread), .update_color(history_update_color),
        .update_from(history_update_from), .update_to(history_update_to),
        .update_depth(history_update_depth),
        .update_failed0(history_update_failed0), .update_failed1(history_update_failed1),
        .update_failed2(history_update_failed2),
        .update_failed_count(history_update_failed_count)
    );

    assign stat_noisy_count = noisy_stat_noisy_count + quiet_stat_noisy_count;
    assign stat_quiet_count = noisy_stat_quiet_count + quiet_stat_quiet_count;
    assign stat_destination_count =
        noisy_stat_destination_count + quiet_stat_destination_count;
    assign stat_candidate_count = noisy_stat_candidate_count + quiet_stat_candidate_count;
    assign stat_history_lookup_count =
        noisy_stat_history_lookup_count + quiet_stat_history_lookup_count;
    assign stat_generation_cycles =
        noisy_stat_generation_cycles + quiet_stat_generation_cycles;
    always_comb begin
        for (int bucket = 0; bucket < MOVE_BUCKET_COUNT; bucket++) begin
            stat_bucket_count[bucket] = NOISY_BUCKET_MASK[bucket]
                ? noisy_stat_bucket_count[bucket] : quiet_stat_bucket_count[bucket];
            stat_bucket_high_water[bucket] = NOISY_BUCKET_MASK[bucket]
                ? noisy_stat_bucket_high_water[bucket] : quiet_stat_bucket_high_water[bucket];
        end
    end

    move_generator_lane #(
        .THREAD_COUNT(THREAD_COUNT),
        .GENERATION_COMMAND(MOVE_GEN_GENERATE_NOISY),
        .HISTORY_ENTRY_BITS(HISTORY_ENTRY_BITS),
        .QUIET_THRESHOLD_1(QUIET_THRESHOLD_1), .QUIET_THRESHOLD_2(QUIET_THRESHOLD_2),
        .QUIET_THRESHOLD_3(QUIET_THRESHOLD_3), .CASTLING_HISTORY_BONUS(CASTLING_HISTORY_BONUS),
        .ENABLE_STATS(ENABLE_STATS)
    ) noisy_lane (
        .clk, .rst_n, .clear, .flush, .init_busy(noisy_init_busy),
        .cmd_valid(noisy_cmd_valid && noisy_admit), .cmd_ready(noisy_lane_cmd_ready), .cmd(noisy_cmd),
        .cmd_thread(noisy_cmd_thread), .cmd_ply(noisy_cmd_ply), .cmd_board(noisy_cmd_board),
        .cmd_suppress_valid(noisy_cmd_suppress_valid),
        .cmd_suppress_move(noisy_cmd_suppress_move),
        .cmd_resp_valid(noisy_resp_valid), .cmd_resp_thread(noisy_resp_thread),
        .cmd_resp_ply(noisy_resp_ply), .cmd_resp_direct_valid(noisy_resp_direct_valid),
        .cmd_resp_direct_move(noisy_resp_direct_move),
        .live_active(live_active[0]), .live_thread(live_thread[0]),
        .live_ply(live_ply[0]),
        .write_valid(write_valid[0]), .write_move(write_move[0]),
        .write_bucket(write_bucket[0]), .write_top(write_top[0]),
        .history_lookup_valid(), .history_lookup_thread(), .history_lookup_color(),
        .history_lookup_from(), .history_lookup_to(),
        .history_lookup_value(quiet_history_lookup_value),
        .stat_noisy_count(noisy_stat_noisy_count), .stat_quiet_count(noisy_stat_quiet_count),
        .stat_destination_count(noisy_stat_destination_count),
        .stat_candidate_count(noisy_stat_candidate_count),
        .stat_history_lookup_count(noisy_stat_history_lookup_count),
        .stat_generation_cycles(noisy_stat_generation_cycles),
        .stat_bucket_count(noisy_stat_bucket_count),
        .stat_bucket_high_water(noisy_stat_bucket_high_water)
    );

    move_generator_lane #(
        .THREAD_COUNT(THREAD_COUNT),
        .GENERATION_COMMAND(MOVE_GEN_GENERATE_QUIET),
        .HISTORY_ENTRY_BITS(HISTORY_ENTRY_BITS),
        .QUIET_THRESHOLD_1(QUIET_THRESHOLD_1), .QUIET_THRESHOLD_2(QUIET_THRESHOLD_2),
        .QUIET_THRESHOLD_3(QUIET_THRESHOLD_3), .CASTLING_HISTORY_BONUS(CASTLING_HISTORY_BONUS),
        .ENABLE_STATS(ENABLE_STATS)
    ) quiet_lane (
        .clk, .rst_n, .clear, .flush, .init_busy(quiet_init_busy),
        .cmd_valid(quiet_cmd_valid && quiet_admit), .cmd_ready(quiet_lane_cmd_ready),
        .cmd(MOVE_GEN_GENERATE_QUIET),
        .cmd_thread(quiet_cmd_thread), .cmd_ply(quiet_cmd_ply), .cmd_board(quiet_cmd_board),
        .cmd_suppress_valid(quiet_cmd_suppress_valid),
        .cmd_suppress_move(quiet_cmd_suppress_move),
        .cmd_resp_valid(quiet_resp_valid), .cmd_resp_thread(quiet_resp_thread),
        .cmd_resp_ply(quiet_resp_ply), .cmd_resp_direct_valid(),
        .cmd_resp_direct_move(),
        .live_active(live_active[1]), .live_thread(live_thread[1]),
        .live_ply(live_ply[1]),
        .write_valid(write_valid[1]), .write_move(write_move[1]),
        .write_bucket(write_bucket[1]), .write_top(write_top[1]),
        .history_lookup_valid(quiet_history_lookup_valid),
        .history_lookup_thread(quiet_history_lookup_thread),
        .history_lookup_color(quiet_history_lookup_color),
        .history_lookup_from(quiet_history_lookup_from),
        .history_lookup_to(quiet_history_lookup_to),
        .history_lookup_value(quiet_history_lookup_value),
        .stat_noisy_count(quiet_stat_noisy_count), .stat_quiet_count(quiet_stat_quiet_count),
        .stat_destination_count(quiet_stat_destination_count),
        .stat_candidate_count(quiet_stat_candidate_count),
        .stat_history_lookup_count(quiet_stat_history_lookup_count),
        .stat_generation_cycles(quiet_stat_generation_cycles),
        .stat_bucket_count(quiet_stat_bucket_count),
        .stat_bucket_high_water(quiet_stat_bucket_high_water)
    );

endmodule : move_generator
