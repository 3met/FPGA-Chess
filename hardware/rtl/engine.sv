// FPGA-Chess
// Complete vendor-neutral engine core.

import engine_defs::*;
import tt_defs::*;

module engine #(
    parameter logic [63:0] BUILD_ID = 64'h0000_0000_0000_0000,
    parameter int CLOCK_FREQ = 100_000_000,
    parameter int SEARCH_THREAD_COUNT = general_chess_defs::THREAD_COUNT,
    parameter int SEARCH_STACK_DEPTH = general_chess_defs::MAX_PLY_COUNT,
    parameter int TT_TAG_BITS = TT_DEFAULT_TAG_BITS,
    parameter int unsigned LMR_A_Q8 = 192,
    parameter int unsigned LMR_B_Q8 = 614,
    parameter int ASPIRATION_HALF_WINDOW = 64,
    parameter int LMR_MINIMUM_DEPTH = 3,
    parameter int LMR_MINIMUM_MOVE_NUMBER = 3,
    parameter int NULL_MINIMUM_DEPTH = 3,
    parameter int NULL_DEEP_DEPTH_THRESHOLD = 7,
    parameter int NULL_SHALLOW_REDUCTION = 2,
    parameter int NULL_DEEP_REDUCTION = 3,
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
    parameter int TT_STALE_DEPTH_TOLERANCE = 4,
    parameter bit EXTERNAL_TT = 1'b0,
    parameter bit ENABLE_SEARCH_STATS = 1'b0
) (
    input logic clk,
    input logic rst_n,
    input logic [7:0] data_in,
    input logic data_in_valid,
    input logic ready_for_result,
    output logic error_flag,
    output logic ready,
    output logic [7:0] data_out,
    output logic data_out_valid,
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

    logic controller_req_valid;
    logic controller_req_ready;
    EngineControllerRequest controller_req;
    logic controller_resp_valid;
    EngineControllerResponse controller_resp;
    logic [7:0] debug_stat_address;
    logic [39:0] debug_stat_value;

    engine_command_layer #(
        .BUILD_ID(BUILD_ID),
        .CLOCK_FREQ(CLOCK_FREQ),
        .SEARCH_THREAD_COUNT(SEARCH_THREAD_COUNT),
        .SEARCH_STACK_DEPTH(SEARCH_STACK_DEPTH)
    ) command_layer (
        .clk(clk),
        .rst_n(rst_n),
        .data_in(data_in),
        .data_in_valid(data_in_valid),
        .ready_for_result(ready_for_result),
        .error_flag(error_flag),
        .ready(ready),
        .data_out(data_out),
        .data_out_valid(data_out_valid),
        .search_req_valid(controller_req_valid),
        .search_req_ready(controller_req_ready),
        .search_req(controller_req),
        .search_resp_valid(controller_resp_valid),
        .search_resp(controller_resp),
        .debug_stat_address(debug_stat_address),
        .debug_stat_value(debug_stat_value)
    );

    search_controller #(
        .CLOCK_FREQ(CLOCK_FREQ),
        .SEARCH_THREAD_COUNT(SEARCH_THREAD_COUNT),
        .SEARCH_STACK_DEPTH(SEARCH_STACK_DEPTH),
        .TT_TAG_BITS(TT_TAG_BITS),
        .LMR_A_Q8(LMR_A_Q8),
        .LMR_B_Q8(LMR_B_Q8),
        .ASPIRATION_HALF_WINDOW(ASPIRATION_HALF_WINDOW),
        .LMR_MINIMUM_DEPTH(LMR_MINIMUM_DEPTH),
        .LMR_MINIMUM_MOVE_NUMBER(LMR_MINIMUM_MOVE_NUMBER),
        .NULL_MINIMUM_DEPTH(NULL_MINIMUM_DEPTH),
        .NULL_DEEP_DEPTH_THRESHOLD(NULL_DEEP_DEPTH_THRESHOLD),
        .NULL_SHALLOW_REDUCTION(NULL_SHALLOW_REDUCTION),
        .NULL_DEEP_REDUCTION(NULL_DEEP_REDUCTION),
        .MOVE_OVERHEAD_MS(MOVE_OVERHEAD_MS),
        .MINIMUM_SEARCH_MS(MINIMUM_SEARCH_MS),
        .INCREMENT_NUMERATOR(INCREMENT_NUMERATOR),
        .INCREMENT_DENOMINATOR(INCREMENT_DENOMINATOR),
        .REMAINING_TIME_NUMERATOR(REMAINING_TIME_NUMERATOR),
        .REMAINING_TIME_DENOMINATOR(REMAINING_TIME_DENOMINATOR),
        .HISTORY_REWARD_PER_DEPTH(HISTORY_REWARD_PER_DEPTH),
        .HISTORY_MAXIMUM_REWARD(HISTORY_MAXIMUM_REWARD),
        .HISTORY_MALUS_DIVISOR(HISTORY_MALUS_DIVISOR),
        .QUIET_THRESHOLD_1(QUIET_THRESHOLD_1),
        .QUIET_THRESHOLD_2(QUIET_THRESHOLD_2),
        .QUIET_THRESHOLD_3(QUIET_THRESHOLD_3),
        .CASTLING_HISTORY_BONUS(CASTLING_HISTORY_BONUS),
        .TT_VALIDATE_MINIMUM_DEPTH(TT_VALIDATE_MINIMUM_DEPTH),
        .TT_VALIDATE_BYPASS_HALFMOVES(TT_VALIDATE_BYPASS_HALFMOVES),
        .TT_STALE_DEPTH_TOLERANCE(TT_STALE_DEPTH_TOLERANCE),
        .EXTERNAL_TT(EXTERNAL_TT),
        .ENABLE_SEARCH_STATS(ENABLE_SEARCH_STATS)
    ) controller (
        .clk(clk),
        .rst_n(rst_n),
        .req_valid(controller_req_valid),
        .req_ready(controller_req_ready),
        .req(controller_req),
        .resp_valid(controller_resp_valid),
        .resp(controller_resp),
        .debug_stat_address(debug_stat_address),
        .debug_stat_value(debug_stat_value),
        .tt_memory_ready(tt_memory_ready), .tt_memory_error(tt_memory_error),
        .tt_mem_req_valid(tt_mem_req_valid), .tt_mem_req_ready(tt_mem_req_ready),
        .tt_mem_req_write(tt_mem_req_write), .tt_mem_req_address(tt_mem_req_address), .tt_mem_req_length(tt_mem_req_length),
        .tt_mem_write_valid(tt_mem_write_valid), .tt_mem_write_ready(tt_mem_write_ready),
        .tt_mem_write_data(tt_mem_write_data), .tt_mem_write_last(tt_mem_write_last),
        .tt_mem_read_valid(tt_mem_read_valid), .tt_mem_read_ready(tt_mem_read_ready),
        .tt_mem_read_data(tt_mem_read_data), .tt_mem_read_last(tt_mem_read_last),
        .tt_mem_done_valid(tt_mem_done_valid), .tt_mem_done_ready(tt_mem_done_ready), .tt_mem_done_error(tt_mem_done_error)
    );

endmodule : engine
