// By Emet Behrendt

import chess_defs::*;
import chess_helpers::*;
import board_update_pipeline_defs::*;
import engine_defs::*;
import search_defs::*;
import move_generator_defs::*;
import nnue_defs::*;
import tt_defs::*;

module search_controller #(
    parameter int CLOCK_FREQ = 100_000_000,
    parameter int TT_TAG_BITS = TT_DEFAULT_TAG_BITS,
    parameter int TT_ENTRY_COUNT = 2 * (TT_EXTERNAL_WORD_COUNT
        / (TT_WAYS*((TT_TAG_BITS+TT_ENTRY_PAYLOAD_BITS+TT_WORD_BITS-1)/TT_WORD_BITS)) / 2),
    // Queue storage is selected by the device profile.
    parameter int TT_CACHE_INDEX_BITS = 10,
    parameter int TT_STORE_FIFO_DEPTH = 256,
    parameter int TT_OUTSTANDING_DEPTH = 8,
    parameter int TT_RESPONSE_FIFO_DEPTH = 64,
    parameter int TT_WRITEBACK_FIFO_DEPTH = 8,
    parameter int ACTIVE_REPETITION_DEPTH = 100,
    parameter int SEARCH_THREAD_COUNT = THREAD_COUNT,
    parameter int SEARCH_STACK_DEPTH = MAX_PLY_COUNT,
    parameter int unsigned LMR_A_Q8 = 192,
    parameter int unsigned LMR_B_Q8 = 614,
    parameter int ASPIRATION_STARTING_DELTA = 15,
    parameter int unsigned ASPIRATION_DELTA_MULTIPLIER_Q3 = 12,
    parameter int LMR_MINIMUM_DEPTH = 3,
    parameter int LMR_MINIMUM_MOVE_NUMBER = 3,
    parameter int NULL_MINIMUM_DEPTH = 3,
    parameter int NULL_DEEP_DEPTH_THRESHOLD = 7,
    parameter int NULL_SHALLOW_REDUCTION = 2,
    parameter int NULL_DEEP_REDUCTION = 3,
    parameter int RFP_BASE_MARGIN = 64,
    parameter int RFP_MARGIN_PER_DEPTH = 128,
    parameter int RFP_MAXIMUM_DEPTH = 5,
    // Scores use 1/128-pawn units, so 192 is a 150-centipawn margin.
    parameter int FUTILITY_BASE_MARGIN = 192,
    parameter int FUTILITY_MARGIN_PER_DEPTH = 192,
    parameter int FUTILITY_MAXIMUM_DEPTH = 3,
    // Scores use 1/128-pawn units, so 384 is a 300-centipawn margin.
    parameter int QDELTA_MARGIN = 384,
    parameter int MOVES_TO_GO_BUFFER = 2,
    parameter int DEFAULT_MOVES_DIVISOR = 20,
    parameter int INCREMENT_NUMERATOR = 4,
    parameter int INCREMENT_DENOMINATOR = 5,
    parameter int HARD_BASE_MULTIPLIER = 4,
    parameter int HARD_TIME_NUMERATOR = 4,
    parameter int HARD_TIME_DENOMINATOR = 5,
    parameter int SOFT_FACTOR_DEFAULT = 4,
    parameter int SOFT_FACTOR_MINIMUM = 2,
    parameter int SOFT_FACTOR_MAXIMUM = 8,
    parameter int STABLE_DEPTH_THRESHOLD = 3,
    // Scores use 1/128-pawn units, so 64 is a 50-centipawn drop.
    parameter int SCORE_DROP_THRESHOLD = 64,
    parameter int NEXT_DEPTH_NUMERATOR = 3,
    parameter int NEXT_DEPTH_DENOMINATOR = 5,
    parameter int SINGLE_LEGAL_MOVE_MS = 10,
    parameter int MOVE_MEMORY_ENTRIES = 2048,
    parameter int MOVE_BUCKET_0_RATIO = 64,
    parameter int MOVE_BUCKET_1_RATIO = 48,
    parameter int MOVE_BUCKET_2_RATIO = 16,
    parameter int MOVE_BUCKET_3_RATIO = 112,
    parameter int MOVE_BUCKET_4_RATIO = 112,
    parameter int MOVE_BUCKET_5_RATIO = 64,
    parameter int MOVE_BUCKET_6_RATIO = 64,
    parameter int MOVE_BUCKET_7_RATIO = 32,
    parameter int HISTORY_ENTRY_COUNT = 8192,
    parameter int HISTORY_ENTRY_BITS = 8,
    parameter int HISTORY_DEFAULT_SCORE = 0,
    parameter int HISTORY_REWARD_PER_DEPTH = 2,
    parameter int HISTORY_MAXIMUM_REWARD = 31,
    parameter int HISTORY_MALUS_DIVISOR = 2,
    parameter int QUIET_THRESHOLD_1 = 0,
    parameter int QUIET_THRESHOLD_2 = 16,
    parameter int QUIET_THRESHOLD_3 = 64,
    parameter int CASTLING_HISTORY_BONUS = 8,
    parameter int TT_VALIDATE_MINIMUM_DEPTH = 8,
    parameter int TT_VALIDATE_BYPASS_HALFMOVES = 4,
    parameter int TT_STALE_DEPTH_TOLERANCE = 4,
    parameter bit ENABLE_SEARCH_STATS = 1'b0
) (
    input logic clk,
    input logic tt_memory_clk,
    input logic tt_memory_rst_n,
    input logic rst_n,
    input logic req_valid,
    output logic req_ready,
    input EngineControllerRequest req,
    output logic resp_valid,
    input logic resp_ready,
    output EngineControllerResponse resp,
    input logic [7:0] debug_stat_address,
    output logic [39:0] debug_stat_value,
    input logic tt_memory_ready,
    input logic tt_memory_error,
    output logic tt_mem_req_valid,
    input logic tt_mem_req_ready,
    output logic tt_mem_req_write,
    output TTWordAddress tt_mem_req_address,
    output TTBurstLength tt_mem_req_length,
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


    // Keep one controller hierarchy and clocked state owner while grouping the
    // implementation by responsibility. Include order preserves declaration scope.
    `include "hardware/rtl/search/search_state.svh"
    `include "hardware/rtl/search/search_pipelines.svh"
    `include "hardware/rtl/search/search_policy.svh"
    `include "hardware/rtl/search/search_helpers.svh"
    `include "hardware/rtl/search/search_results.svh"
    `include "hardware/rtl/search/search_scheduler.svh"
    `include "hardware/rtl/search/search_requests.svh"
    `include "hardware/rtl/search/search_nnue_requests.svh"
    `include "hardware/rtl/search/search_control.svh"

endmodule : search_controller
