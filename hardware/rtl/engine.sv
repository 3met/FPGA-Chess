// FPGA-Chess
// Complete vendor-neutral engine core.

import engine_defs::*;
import tt_defs::*;

module engine #(
    parameter int CLOCK_FREQ = 100_000_000,
    parameter int SEARCH_THREAD_COUNT = general_chess_defs::THREAD_COUNT,
    parameter int SEARCH_STACK_DEPTH = general_chess_defs::MAX_PLY_COUNT,
    parameter int unsigned LMR_A_Q8 = 192,
    parameter int unsigned LMR_B_Q8 = 614,
    parameter bit EXTERNAL_TT = 1'b0,
    parameter bit ENABLE_SEARCH_STATS = 1'b0
) (
    input wire clk,
    input wire rst_n,
    input logic [7:0] data_in,
    input logic data_in_valid,
    input logic kill,
    input logic ready_for_result,
    output logic error_flag,
    output logic ready,
    output logic [7:0] data_out,
    output logic data_out_valid,
    input logic tt_memory_ready, input logic tt_memory_error,
    output logic tt_mem_req_valid, input logic tt_mem_req_ready,
    output logic tt_mem_req_write, output TTWordAddress tt_mem_req_address, output logic [3:0] tt_mem_req_length,
    output logic tt_mem_write_valid, input logic tt_mem_write_ready,
    output logic [15:0] tt_mem_write_data, output logic tt_mem_write_last,
    input logic tt_mem_read_valid, output logic tt_mem_read_ready,
    input logic [15:0] tt_mem_read_data, input logic tt_mem_read_last,
    input logic tt_mem_done_valid, output logic tt_mem_done_ready, input logic tt_mem_done_error
);

    logic controller_req_valid;
    logic controller_req_ready;
    EngineControllerRequest controller_req;
    logic controller_resp_valid;
    EngineControllerResponse controller_resp;
    logic [7:0] debug_stat_address;
    logic [39:0] debug_stat_value;

    engine_command_layer command_layer (
        .clk(clk),
        .rst_n(rst_n),
        .data_in(data_in),
        .data_in_valid(data_in_valid),
        .kill(kill),
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
        .LMR_A_Q8(LMR_A_Q8),
        .LMR_B_Q8(LMR_B_Q8),
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
