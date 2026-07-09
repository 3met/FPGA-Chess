// FPGA-Chess
// Complete vendor-neutral engine core.

import engine_defs::*;

module engine #(
    parameter int CLOCK_FREQ = 100_000_000,
    parameter int SEARCH_THREAD_COUNT = general_chess_defs::THREAD_COUNT,
    parameter int SEARCH_STACK_DEPTH = general_chess_defs::MAX_PLY_COUNT,
    parameter bit ENABLE_PERFT = 1'b1,
    parameter bit ENABLE_ZOBRIST = 1'b1,
    parameter bit ENABLE_TT = 1'b1,
    parameter bit ENABLE_PST = 1'b1
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
    output logic data_out_valid
);

    logic controller_req_valid;
    logic controller_req_ready;
    EngineControllerRequest controller_req;
    logic controller_resp_valid;
    EngineControllerResponse controller_resp;

    engine_command_layer #(
        .ENABLE_PERFT(ENABLE_PERFT)
    ) command_layer (
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
        .search_resp(controller_resp)
    );

    search_controller #(
        .CLOCK_FREQ(CLOCK_FREQ),
        .SEARCH_THREAD_COUNT(SEARCH_THREAD_COUNT),
        .SEARCH_STACK_DEPTH(SEARCH_STACK_DEPTH),
        .ENABLE_PERFT(ENABLE_PERFT),
        .ENABLE_ZOBRIST(ENABLE_ZOBRIST),
        .ENABLE_TT(ENABLE_TT),
        .ENABLE_PST(ENABLE_PST)
    ) controller (
        .clk(clk),
        .rst_n(rst_n),
        .req_valid(controller_req_valid),
        .req_ready(controller_req_ready),
        .req(controller_req),
        .resp_valid(controller_resp_valid),
        .resp(controller_resp)
    );

endmodule : engine
