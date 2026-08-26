// Dual-class frontend. Noisy and quiet jobs occupy independent lanes while the
// shared pop interface preserves global bucket priority.

import chess_defs::*;
import move_generator_defs::*;

module move_generator #(
    parameter int THREAD_COUNT = 1,
    parameter int BUCKET_0_CAPACITY = 512,
    parameter int BUCKET_1_CAPACITY = 512,
    parameter int BUCKET_2_CAPACITY = 1024,
    parameter int BUCKET_3_CAPACITY = 512,
    parameter int BUCKET_4_CAPACITY = 512,
    parameter int BUCKET_5_CAPACITY = 512,
    parameter int BUCKET_6_CAPACITY = 512,
    parameter int BUCKET_7_CAPACITY = 512,
    parameter int HISTORY_REWARD_PER_DEPTH = 4,
    parameter int HISTORY_MAXIMUM_REWARD = 63,
    parameter int HISTORY_MALUS_DIVISOR = 2,
    parameter int QUIET_THRESHOLD_1 = 16,
    parameter int QUIET_THRESHOLD_2 = 64,
    parameter int QUIET_THRESHOLD_3 = 128,
    parameter int CASTLING_HISTORY_BONUS = 16,
    parameter bit ASSERT_ON_OVERFLOW = 1'b1,
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
    input MoveBucketTops noisy_cmd_bucket_tops,
    output logic noisy_resp_valid,
    output ThreadID noisy_resp_thread,
    output PlyIndex noisy_resp_ply,
    output logic noisy_resp_direct_valid,
    output Move noisy_resp_direct_move,
    output MoveBucketTops noisy_resp_bucket_tops,

    input logic quiet_cmd_valid,
    output logic quiet_cmd_ready,
    input ThreadID quiet_cmd_thread,
    input PlyIndex quiet_cmd_ply,
    input FullBoard quiet_cmd_board,
    input logic quiet_cmd_suppress_valid,
    input Move quiet_cmd_suppress_move,
    input MoveBucketTops quiet_cmd_bucket_tops,
    output logic quiet_resp_valid,
    output ThreadID quiet_resp_thread,
    output PlyIndex quiet_resp_ply,
    output MoveBucketTops quiet_resp_bucket_tops,

    input logic pop_valid,
    output logic pop_ready,
    input ThreadID pop_thread,
    input PlyIndex pop_ply,
    input MoveBucketMask pop_eligible,
    input MoveBucketTops pop_current_tops,
    input MoveBucketTops pop_lower_tops,
    output logic pop_resp_valid,
    output ThreadID pop_resp_thread,
    output PlyIndex pop_resp_ply,
    output logic pop_resp_found,
    output Move pop_resp_move,
    output MoveBucketIndex pop_resp_bucket,
    output MoveBucketTop pop_resp_new_top,

    input logic history_update_valid,
    output logic history_update_ready,
    input Color history_update_color,
    input Position history_update_from,
    input Position history_update_to,
    input PlyIndex history_update_depth,
    input logic [11:0] history_update_failed0,
    input logic [11:0] history_update_failed1,
    input logic [11:0] history_update_failed2,
    input logic [1:0] history_update_failed_count,

    output logic overflow_sticky,
    output ThreadID overflow_thread,
    output MoveBucketIndex overflow_bucket,
    output logic [15:0] overflow_count,
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

    logic noisy_init_busy, quiet_init_busy;
    logic noisy_pop_ready, quiet_pop_ready;
    logic noisy_pop_resp_valid, quiet_pop_resp_valid;
    ThreadID noisy_pop_resp_thread, quiet_pop_resp_thread;
    PlyIndex noisy_pop_resp_ply, quiet_pop_resp_ply;
    logic noisy_pop_resp_found, quiet_pop_resp_found;
    Move noisy_pop_resp_move, quiet_pop_resp_move;
    MoveBucketIndex noisy_pop_resp_bucket, quiet_pop_resp_bucket;
    MoveBucketTop noisy_pop_resp_new_top, quiet_pop_resp_new_top;
    logic quiet_history_update_ready;
    logic noisy_overflow_sticky, quiet_overflow_sticky;
    ThreadID noisy_overflow_thread, quiet_overflow_thread;
    MoveBucketIndex noisy_overflow_bucket, quiet_overflow_bucket;
    logic [15:0] noisy_overflow_count, quiet_overflow_count;
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

    logic pop_use_quiet;
    logic noisy_good_available, quiet_available, noisy_bad_available;

    always_comb begin
        noisy_good_available = 1'b0;
        quiet_available = 1'b0;
        noisy_bad_available = 1'b0;
        for (int bucket = 0; bucket < MOVE_BUCKET_COUNT; bucket++) begin
            automatic logic available = pop_eligible[bucket]
                && pop_current_tops[bucket] != pop_lower_tops[bucket];
            if (bucket >= int'(GOOD_NOISY_LOW_BUCKET)) noisy_good_available |= available;
            else if (bucket >= int'(QUIET_LOW_BUCKET)) quiet_available |= available;
            else noisy_bad_available |= available;
        end
        // Preserve global bucket priority even when a caller supplies ALL_BUCKET_MASK.
        pop_use_quiet = !noisy_good_available
            && (quiet_available
                || (!noisy_bad_available
                    && (pop_eligible & QUIET_BUCKET_MASK) != MoveBucketMask'(0)));
    end

    assign init_busy = noisy_init_busy || quiet_init_busy;
    assign pop_ready = pop_use_quiet ? quiet_pop_ready : noisy_pop_ready;
    assign history_update_ready = quiet_history_update_ready;

    assign pop_resp_valid = noisy_pop_resp_valid || quiet_pop_resp_valid;
    assign pop_resp_thread = noisy_pop_resp_valid ? noisy_pop_resp_thread : quiet_pop_resp_thread;
    assign pop_resp_ply = noisy_pop_resp_valid ? noisy_pop_resp_ply : quiet_pop_resp_ply;
    assign pop_resp_found = noisy_pop_resp_valid ? noisy_pop_resp_found : quiet_pop_resp_found;
    assign pop_resp_move = noisy_pop_resp_valid ? noisy_pop_resp_move : quiet_pop_resp_move;
    assign pop_resp_bucket = noisy_pop_resp_valid ? noisy_pop_resp_bucket : quiet_pop_resp_bucket;
    assign pop_resp_new_top = noisy_pop_resp_valid
        ? noisy_pop_resp_new_top : quiet_pop_resp_new_top;

    assign overflow_sticky = noisy_overflow_sticky || quiet_overflow_sticky;
    assign overflow_thread = noisy_overflow_sticky ? noisy_overflow_thread : quiet_overflow_thread;
    assign overflow_bucket = noisy_overflow_sticky ? noisy_overflow_bucket : quiet_overflow_bucket;
    assign overflow_count = noisy_overflow_count + quiet_overflow_count;
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
        .BUCKET_0_CAPACITY(BUCKET_0_CAPACITY), .BUCKET_1_CAPACITY(BUCKET_1_CAPACITY),
        .BUCKET_2_CAPACITY(BUCKET_2_CAPACITY), .BUCKET_3_CAPACITY(BUCKET_3_CAPACITY),
        .BUCKET_4_CAPACITY(BUCKET_4_CAPACITY), .BUCKET_5_CAPACITY(BUCKET_5_CAPACITY),
        .BUCKET_6_CAPACITY(BUCKET_6_CAPACITY), .BUCKET_7_CAPACITY(BUCKET_7_CAPACITY),
        .GENERATION_COMMAND(MOVE_GEN_GENERATE_NOISY), .OWNED_BUCKETS(NOISY_BUCKET_MASK),
        .HISTORY_REWARD_PER_DEPTH(HISTORY_REWARD_PER_DEPTH),
        .HISTORY_MAXIMUM_REWARD(HISTORY_MAXIMUM_REWARD),
        .HISTORY_MALUS_DIVISOR(HISTORY_MALUS_DIVISOR),
        .QUIET_THRESHOLD_1(QUIET_THRESHOLD_1), .QUIET_THRESHOLD_2(QUIET_THRESHOLD_2),
        .QUIET_THRESHOLD_3(QUIET_THRESHOLD_3), .CASTLING_HISTORY_BONUS(CASTLING_HISTORY_BONUS),
        .ASSERT_ON_OVERFLOW(ASSERT_ON_OVERFLOW), .ENABLE_STATS(ENABLE_STATS)
    ) noisy_lane (
        .clk, .rst_n, .clear, .flush, .init_busy(noisy_init_busy),
        .cmd_valid(noisy_cmd_valid), .cmd_ready(noisy_cmd_ready), .cmd(noisy_cmd),
        .cmd_thread(noisy_cmd_thread), .cmd_ply(noisy_cmd_ply), .cmd_board(noisy_cmd_board),
        .cmd_suppress_valid(noisy_cmd_suppress_valid),
        .cmd_suppress_move(noisy_cmd_suppress_move),
        .cmd_bucket_tops(noisy_cmd_bucket_tops),
        .cmd_resp_valid(noisy_resp_valid), .cmd_resp_thread(noisy_resp_thread),
        .cmd_resp_ply(noisy_resp_ply), .cmd_resp_direct_valid(noisy_resp_direct_valid),
        .cmd_resp_direct_move(noisy_resp_direct_move),
        .cmd_resp_bucket_tops(noisy_resp_bucket_tops),
        .pop_valid(pop_valid && !pop_use_quiet), .pop_ready(noisy_pop_ready),
        .pop_thread, .pop_ply, .pop_eligible(pop_eligible & NOISY_BUCKET_MASK),
        .pop_current_tops, .pop_lower_tops,
        .pop_resp_valid(noisy_pop_resp_valid), .pop_resp_thread(noisy_pop_resp_thread),
        .pop_resp_ply(noisy_pop_resp_ply), .pop_resp_found(noisy_pop_resp_found),
        .pop_resp_move(noisy_pop_resp_move), .pop_resp_bucket(noisy_pop_resp_bucket),
        .pop_resp_new_top(noisy_pop_resp_new_top),
        .history_update_valid(1'b0), .history_update_ready(),
        .history_update_color, .history_update_from, .history_update_to, .history_update_depth,
        .history_update_failed0, .history_update_failed1, .history_update_failed2,
        .history_update_failed_count,
        .overflow_sticky(noisy_overflow_sticky), .overflow_thread(noisy_overflow_thread),
        .overflow_bucket(noisy_overflow_bucket), .overflow_count(noisy_overflow_count),
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
        .BUCKET_0_CAPACITY(BUCKET_0_CAPACITY), .BUCKET_1_CAPACITY(BUCKET_1_CAPACITY),
        .BUCKET_2_CAPACITY(BUCKET_2_CAPACITY), .BUCKET_3_CAPACITY(BUCKET_3_CAPACITY),
        .BUCKET_4_CAPACITY(BUCKET_4_CAPACITY), .BUCKET_5_CAPACITY(BUCKET_5_CAPACITY),
        .BUCKET_6_CAPACITY(BUCKET_6_CAPACITY), .BUCKET_7_CAPACITY(BUCKET_7_CAPACITY),
        .GENERATION_COMMAND(MOVE_GEN_GENERATE_QUIET), .OWNED_BUCKETS(QUIET_BUCKET_MASK),
        .HISTORY_REWARD_PER_DEPTH(HISTORY_REWARD_PER_DEPTH),
        .HISTORY_MAXIMUM_REWARD(HISTORY_MAXIMUM_REWARD),
        .HISTORY_MALUS_DIVISOR(HISTORY_MALUS_DIVISOR),
        .QUIET_THRESHOLD_1(QUIET_THRESHOLD_1), .QUIET_THRESHOLD_2(QUIET_THRESHOLD_2),
        .QUIET_THRESHOLD_3(QUIET_THRESHOLD_3), .CASTLING_HISTORY_BONUS(CASTLING_HISTORY_BONUS),
        .ASSERT_ON_OVERFLOW(ASSERT_ON_OVERFLOW), .ENABLE_STATS(ENABLE_STATS)
    ) quiet_lane (
        .clk, .rst_n, .clear, .flush, .init_busy(quiet_init_busy),
        .cmd_valid(quiet_cmd_valid), .cmd_ready(quiet_cmd_ready),
        .cmd(MOVE_GEN_GENERATE_QUIET),
        .cmd_thread(quiet_cmd_thread), .cmd_ply(quiet_cmd_ply), .cmd_board(quiet_cmd_board),
        .cmd_suppress_valid(quiet_cmd_suppress_valid),
        .cmd_suppress_move(quiet_cmd_suppress_move),
        .cmd_bucket_tops(quiet_cmd_bucket_tops),
        .cmd_resp_valid(quiet_resp_valid), .cmd_resp_thread(quiet_resp_thread),
        .cmd_resp_ply(quiet_resp_ply), .cmd_resp_direct_valid(),
        .cmd_resp_direct_move(),
        .cmd_resp_bucket_tops(quiet_resp_bucket_tops),
        .pop_valid(pop_valid && pop_use_quiet), .pop_ready(quiet_pop_ready),
        .pop_thread, .pop_ply, .pop_eligible(pop_eligible & QUIET_BUCKET_MASK),
        .pop_current_tops, .pop_lower_tops,
        .pop_resp_valid(quiet_pop_resp_valid), .pop_resp_thread(quiet_pop_resp_thread),
        .pop_resp_ply(quiet_pop_resp_ply), .pop_resp_found(quiet_pop_resp_found),
        .pop_resp_move(quiet_pop_resp_move), .pop_resp_bucket(quiet_pop_resp_bucket),
        .pop_resp_new_top(quiet_pop_resp_new_top),
        .history_update_valid, .history_update_ready(quiet_history_update_ready),
        .history_update_color, .history_update_from, .history_update_to, .history_update_depth,
        .history_update_failed0, .history_update_failed1, .history_update_failed2,
        .history_update_failed_count,
        .overflow_sticky(quiet_overflow_sticky), .overflow_thread(quiet_overflow_thread),
        .overflow_bucket(quiet_overflow_bucket), .overflow_count(quiet_overflow_count),
        .stat_noisy_count(quiet_stat_noisy_count), .stat_quiet_count(quiet_stat_quiet_count),
        .stat_destination_count(quiet_stat_destination_count),
        .stat_candidate_count(quiet_stat_candidate_count),
        .stat_history_lookup_count(quiet_stat_history_lookup_count),
        .stat_generation_cycles(quiet_stat_generation_cycles),
        .stat_bucket_count(quiet_stat_bucket_count),
        .stat_bucket_high_water(quiet_stat_bucket_high_water)
    );

endmodule : move_generator
