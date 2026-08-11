// By Emet Behrendt

import general_chess_defs::*;
import board_update_pipeline_defs::*;
import engine_defs::*;

module engine_command_layer #(
    parameter logic [63:0] BUILD_ID = 64'h0000_0000_0000_0000,
    parameter int CLOCK_FREQ = 100_000_000,
    parameter int SEARCH_THREAD_COUNT = general_chess_defs::THREAD_COUNT,
    parameter int SEARCH_STACK_DEPTH = general_chess_defs::MAX_PLY_COUNT
) (
    input wire clk,
    input wire rst_n,
    input logic [7:0] data_in,
    input logic data_in_valid,
    input logic ready_for_result,
    output logic error_flag,
    output logic ready,
    output logic [7:0] data_out,
    output logic data_out_valid,

    output logic search_req_valid,
    input logic search_req_ready,
    output EngineControllerRequest search_req,
    input logic search_resp_valid,
    input EngineControllerResponse search_resp,
    output logic [7:0] debug_stat_address,
    input logic [39:0] debug_stat_value
);

    localparam int SET_BOARD_PAYLOAD_BYTES = 36;
    localparam logic [31:0] BUILD_CLOCK_FREQ = CLOCK_FREQ;
    localparam logic [7:0] BUILD_THREAD_COUNT = SEARCH_THREAD_COUNT;
    localparam logic [7:0] BUILD_SEARCH_STACK_DEPTH = SEARCH_STACK_DEPTH;

    typedef enum logic [2:0] {
        ST_IDLE,
        ST_RECEIVE_PAYLOAD,
        ST_PROCESS_PAYLOAD,
        ST_DIRECT_BOARD,
        ST_ISSUE_REQUEST,
        ST_WAIT_RESULT,
        ST_ISSUE_KILL,
        ST_OUTPUT
    } EngineState;

    typedef enum logic [2:0] {
        RESP_NONE,
        RESP_STATUS,
        RESP_ACK,
        RESP_SEARCH,
        RESP_PERFT,
        RESP_DEBUG,
        RESP_ERROR,
        RESP_BUILD_INFO
    } ResponseKind;

    EngineState state;
    ResponseKind response_kind;
    logic [3:0] response_index;
    logic [3:0] response_status;
    logic [2:0] response_error;
    logic [7:0] response_active_op;
    logic [2:0] error_code;

    logic [7:0] curr_opcode;
    logic [5:0] payload_count;
    logic payload_error;
    logic [7:0] payload [0:SET_BOARD_PAYLOAD_BYTES-1];

    logic [6:0] direct_index;
    EngineControllerRequest request_reg;
    ResponseKind request_response_kind;
    logic request_waits_for_result;
    logic request_clears_error;
    logic direct_request_inflight;
    logic search_active;
    logic [7:0] active_operation;

    Move last_move;
    EvalScore last_score;
    NodeCountType last_node_count;
    logic [7:0] last_completed_depth;
    logic [2:0] last_end_reason;
    logic [7:0] debug_stat_address_reg;

    assign debug_stat_address = debug_stat_address_reg;

    // The protocol reserves the upper status bits as zero, so store only its live bits.
    function automatic logic [3:0] status_byte(
        input logic ready_bit,
        input logic search_bit,
        input logic output_pending_bit,
        input logic error_bit
    );
        return {error_bit, output_pending_bit, search_bit, ready_bit};
    endfunction : status_byte

    function automatic logic command_known(input logic [7:0] opcode);
        case (opcode)
            ENGINE_CMD_GET_STATUS,
            ENGINE_CMD_SET_BOARD,
            ENGINE_CMD_MAKE_MOVE,
            ENGINE_CMD_NEW_GAME,
            ENGINE_CMD_SEARCH_DEPTH,
            ENGINE_CMD_SEARCH_FIXED_TIME,
            ENGINE_CMD_SEARCH_ON_CLOCK,
            ENGINE_CMD_SEARCH_NODES,
            ENGINE_CMD_KILL,
            ENGINE_CMD_GET_SEARCH_RESULT: return 1'b1;
            ENGINE_CMD_GET_DEBUG_STAT: return 1'b1;
            ENGINE_CMD_GET_BUILD_INFO: return 1'b1;
            ENGINE_CMD_PERFT: return 1'b1;
            default: return 1'b0;
        endcase
    endfunction : command_known

    function automatic logic [5:0] payload_len(input logic [7:0] opcode);
        case (opcode)
            ENGINE_CMD_SET_BOARD:         return 6'd36;
            ENGINE_CMD_MAKE_MOVE:         return 6'd2;
            ENGINE_CMD_SEARCH_DEPTH:      return 6'd1;
            ENGINE_CMD_SEARCH_FIXED_TIME: return 6'd3;
            ENGINE_CMD_SEARCH_ON_CLOCK:   return 6'd12;
            ENGINE_CMD_SEARCH_NODES:      return 6'd5;
            ENGINE_CMD_PERFT:             return 6'd1;
            ENGINE_CMD_GET_DEBUG_STAT:    return 6'd1;
            default:                      return 6'd0;
        endcase
    endfunction : payload_len

    function automatic logic [3:0] response_len(input ResponseKind kind);
        case (kind)
            RESP_STATUS: return 4'd4;
            RESP_ACK:    return 4'd2;
            RESP_SEARCH: return 4'd12;
            RESP_PERFT:  return 4'd7;
            RESP_DEBUG:  return 4'd7;
            RESP_ERROR:  return 4'd3;
            RESP_BUILD_INFO: return 4'd15;
            default:     return 4'd0;
        endcase
    endfunction : response_len

    function automatic logic [7:0] response_type_for(input ResponseKind kind);
        case (kind)
            RESP_STATUS: return ENGINE_RESP_STATUS;
            RESP_ACK:    return ENGINE_RESP_ACK;
            RESP_SEARCH: return ENGINE_RESP_SEARCH_RESULT;
            RESP_PERFT:  return ENGINE_RESP_PERFT_RESULT;
            RESP_DEBUG:  return ENGINE_RESP_DEBUG_STAT;
            RESP_ERROR:  return ENGINE_RESP_ERROR;
            RESP_BUILD_INFO: return ENGINE_RESP_BUILD_INFO;
            default:     return 8'h00;
        endcase
    endfunction : response_type_for

    function automatic logic payload_byte_invalid(
        input logic [7:0] opcode,
        input logic [5:0] idx,
        input logic [7:0] value
    );
        case (opcode)
            ENGINE_CMD_SET_BOARD: begin
                if (idx < 6'd32) begin
                    return (value[2:0] == SPARE_PIECE) || (value[6:4] == SPARE_PIECE);
                end
                if (idx == 6'd32 || idx == 6'd33) begin
                    return value[7:4] != 4'b0000;
                end
                if (idx == 6'd34) begin
                    return value[7:1] != 7'b0000000;
                end
                if (idx == 6'd35) begin
                    return value[7] != 1'b0;
                end
                return 1'b0;
            end

            ENGINE_CMD_MAKE_MOVE: begin
                return idx == 6'd1 && value[7:6] != 2'b00;
            end

            default: return 1'b0;
        endcase
    endfunction : payload_byte_invalid

    function automatic TimeType decode_time(input int start_idx);
        return TimeType'({payload[start_idx + 2], payload[start_idx + 1], payload[start_idx]});
    endfunction : decode_time

    function automatic NodeCountType decode_node_count();
        return NodeCountType'({payload[4], payload[3], payload[2], payload[1], payload[0]});
    endfunction : decode_node_count

    function automatic Move decode_move();
        automatic Move move;

        move.from_pos = payload[1][5:0];
        move.to_pos = payload[0][7:2];
        move.promo_piece = PromoType'(payload[0][1:0]);
        return move;
    endfunction : decode_move

    function automatic EngineControllerRequest zero_request();
        automatic EngineControllerRequest req;

        req = EngineControllerRequest'('0);
        req.operation = ENGINE_CTRL_IDLE;
        req.direct_board_op = BOARD_IDLE_OP;
        return req;
    endfunction : zero_request

    function automatic EngineControllerRequest set_board_request(input logic [6:0] idx);
        automatic EngineControllerRequest req;
        automatic logic [7:0] tile_byte;

        req = zero_request();
        req.operation = ENGINE_CTRL_DIRECT_BOARD;
        req.move = Move'('0);

        if (idx < 7'd64) begin
            tile_byte = payload[idx[6:1]];
            req.direct_board_op = BOARD_SET_TILE_OP;
            req.move.to_pos = Position'(idx[5:0]);
            req.board_wr_data = idx[0] ? {3'b000, tile_byte[7:4]} : {3'b000, tile_byte[3:0]};
        end else if (idx == 7'd64) begin
            req.direct_board_op = BOARD_SET_CASTLE_PERMS_OP;
            req.board_wr_data = {3'b000, payload[32][3:0]};
        end else if (idx == 7'd65) begin
            req.direct_board_op = BOARD_SET_EN_PASSANT_OP;
            req.board_wr_data = {3'b000, payload[33][3:0]};
        end else if (idx == 7'd66) begin
            req.direct_board_op = BOARD_SET_TURN_OP;
            req.board_wr_data = {6'b000000, payload[34][0]};
        end else begin
            req.direct_board_op = BOARD_SET_HALFMOVE_CLOCK_OP;
            req.board_wr_data = payload[35][6:0];
        end

        return req;
    endfunction : set_board_request

    always_comb begin
        search_req_valid = (state == ST_DIRECT_BOARD && !direct_request_inflight) || (state == ST_ISSUE_REQUEST) || (state == ST_ISSUE_KILL);
        // The request payload is irrelevant until valid; avoid preserving an idle mux value.
        search_req = 'x;
        if (state == ST_DIRECT_BOARD && !direct_request_inflight) begin
            search_req = set_board_request(direct_index);
        end else if (state == ST_ISSUE_REQUEST || state == ST_ISSUE_KILL) begin
            search_req = request_reg;
        end
    end

    assign ready = (state == ST_IDLE) || (state == ST_RECEIVE_PAYLOAD) || (state == ST_WAIT_RESULT);
    assign data_out_valid = (state == ST_OUTPUT) && ready_for_result;
    assign error_flag = error_code != '0;

    always_comb begin
        // data_out is only meaningful while data_out_valid is asserted.
        data_out = 'x;
        if (response_index == 4'd0) begin
            data_out = response_type_for(response_kind);
        end else begin
            case (response_kind)
                RESP_STATUS: begin
                    case (response_index)
                        5'd1: data_out = {4'b0000, response_status};
                        5'd2: data_out = {5'b00000, response_error};
                        5'd3: data_out = response_active_op;
                        default: data_out = 'x;
                    endcase
                end

                RESP_ACK: begin
                    case (response_index)
                        5'd1: data_out = {4'b0000, response_status};
                        default: data_out = 'x;
                    endcase
                end

                RESP_SEARCH: begin
                    case (response_index)
                        5'd1:  data_out = {last_move.to_pos, last_move.promo_piece};
                        5'd2:  data_out = {2'b00, last_move.from_pos};
                        5'd3:  data_out = last_score[7:0];
                        5'd4:  data_out = last_score[15:8];
                        5'd5:  data_out = last_node_count[7:0];
                        5'd6:  data_out = last_node_count[15:8];
                        5'd7:  data_out = last_node_count[23:16];
                        5'd8:  data_out = last_node_count[31:24];
                        5'd9:  data_out = last_node_count[39:32];
                        5'd10: data_out = last_completed_depth;
                        5'd11: data_out = last_end_reason;
                        default: data_out = 'x;
                    endcase
                end

                RESP_PERFT: begin
                    case (response_index)
                        5'd1: data_out = last_node_count[7:0];
                        5'd2: data_out = last_node_count[15:8];
                        5'd3: data_out = last_node_count[23:16];
                        5'd4: data_out = last_node_count[31:24];
                        5'd5: data_out = last_node_count[39:32];
                        5'd6: data_out = last_completed_depth;
                        default: data_out = 'x;
                    endcase
                end

                RESP_DEBUG: begin
                    case (response_index)
                        5'd1: data_out = debug_stat_address_reg;
                        5'd2: data_out = debug_stat_value[7:0];
                        5'd3: data_out = debug_stat_value[15:8];
                        5'd4: data_out = debug_stat_value[23:16];
                        5'd5: data_out = debug_stat_value[31:24];
                        5'd6: data_out = debug_stat_value[39:32];
                        default: data_out = 'x;
                    endcase
                end

                RESP_ERROR: begin
                    case (response_index)
                        5'd1: data_out = {5'b00000, response_error};
                        5'd2: data_out = {4'b0000, response_status};
                        default: data_out = 'x;
                    endcase
                end

                // Build metadata is constant-folded from engine parameters and needs no storage RAM.
                RESP_BUILD_INFO: begin
                    case (response_index)
                        5'd1:  data_out = BUILD_ID[7:0];
                        5'd2:  data_out = BUILD_ID[15:8];
                        5'd3:  data_out = BUILD_ID[23:16];
                        5'd4:  data_out = BUILD_ID[31:24];
                        5'd5:  data_out = BUILD_ID[39:32];
                        5'd6:  data_out = BUILD_ID[47:40];
                        5'd7:  data_out = BUILD_ID[55:48];
                        5'd8:  data_out = BUILD_ID[63:56];
                        5'd9:  data_out = BUILD_THREAD_COUNT;
                        5'd10: data_out = BUILD_CLOCK_FREQ[7:0];
                        5'd11: data_out = BUILD_CLOCK_FREQ[15:8];
                        5'd12: data_out = BUILD_CLOCK_FREQ[23:16];
                        5'd13: data_out = BUILD_CLOCK_FREQ[31:24];
                        5'd14: data_out = BUILD_SEARCH_STACK_DEPTH;
                        default: data_out = 'x;
                    endcase
                end

                default: data_out = 'x;
            endcase
        end
    end

    task automatic start_response(
        input ResponseKind kind,
        input logic [2:0] err,
        input logic ready_bit,
        input logic search_bit
    );
        response_kind <= kind;
        response_index <= 4'd0;
        response_error <= err;
        response_active_op <= search_bit ? active_operation : 8'h00;
        response_status <= status_byte(ready_bit, search_bit, 1'b0, err != ENGINE_ERR_NONE);
        state <= ST_OUTPUT;
    endtask : start_response

    task automatic latch_error(input logic [2:0] err);
        error_code <= err;
        active_operation <= 8'h00;
        search_active <= 1'b0;
        start_response(RESP_ERROR, err, 1'b1, 1'b0);
    endtask : latch_error

    task automatic issue_single_request(
        input EngineControllerRequest req,
        input ResponseKind response_after_accept,
        input logic waits_for_result,
        input logic clears_error
    );
        request_reg <= req;
        request_response_kind <= response_after_accept;
        request_waits_for_result <= waits_for_result;
        request_clears_error <= clears_error;
        state <= ST_ISSUE_REQUEST;
    endtask : issue_single_request

    task automatic issue_kill_request();
        automatic EngineControllerRequest req;

        req = zero_request();
        req.operation = ENGINE_CTRL_KILL;
        request_reg <= req;
        request_response_kind <= RESP_STATUS;
        request_waits_for_result <= 1'b0;
        request_clears_error <= 1'b0;
        state <= ST_ISSUE_KILL;
    endtask : issue_kill_request

    task automatic process_no_payload_command(input logic [7:0] opcode);
        automatic EngineControllerRequest req;

        req = zero_request();
        case (opcode)
            ENGINE_CMD_GET_STATUS: begin
                start_response(RESP_STATUS, error_code, 1'b1, search_active);
            end

            ENGINE_CMD_NEW_GAME: begin
                active_operation <= ENGINE_CMD_NEW_GAME;
                req.operation = ENGINE_CTRL_NEW_GAME;
                issue_single_request(req, RESP_ACK, 1'b0, 1'b1);
            end

            ENGINE_CMD_KILL: begin
                active_operation <= ENGINE_CMD_KILL;
                req.operation = ENGINE_CTRL_KILL;
                issue_single_request(req, RESP_STATUS, 1'b0, 1'b0);
            end

            ENGINE_CMD_GET_SEARCH_RESULT: begin
                active_operation <= ENGINE_CMD_GET_SEARCH_RESULT;
                start_response(RESP_SEARCH, error_code, 1'b1, 1'b0);
            end

            ENGINE_CMD_GET_BUILD_INFO: begin
                active_operation <= ENGINE_CMD_GET_BUILD_INFO;
                start_response(RESP_BUILD_INFO, error_code, 1'b1, 1'b0);
            end

            default: begin
                latch_error(ENGINE_ERR_UNKNOWN_OPCODE);
            end
        endcase
    endtask : process_no_payload_command

    task automatic process_payload_command();
        automatic EngineControllerRequest req;

        req = zero_request();
        if (payload_error) begin
            latch_error(ENGINE_ERR_MALFORMED_PAYLOAD);
        end else begin
            case (curr_opcode)
                ENGINE_CMD_SET_BOARD: begin
                    active_operation <= ENGINE_CMD_SET_BOARD;
                    direct_index <= 7'd0;
                    direct_request_inflight <= 1'b0;
                    state <= ST_DIRECT_BOARD;
                end

                ENGINE_CMD_MAKE_MOVE: begin
                    active_operation <= ENGINE_CMD_MAKE_MOVE;
                    req.operation = ENGINE_CTRL_DIRECT_BOARD;
                    req.direct_board_op = BOARD_COMMIT_MOVE_OP;
                    req.move = decode_move();
                    issue_single_request(req, RESP_ACK, 1'b0, 1'b0);
                end

                ENGINE_CMD_SEARCH_DEPTH: begin
                    active_operation <= ENGINE_CMD_SEARCH_DEPTH;
                    req.operation = ENGINE_CTRL_SEARCH_DEPTH;
                    req.depth_limit = payload[0];
                    issue_single_request(req, RESP_SEARCH, 1'b1, 1'b0);
                end

                ENGINE_CMD_SEARCH_FIXED_TIME: begin
                    active_operation <= ENGINE_CMD_SEARCH_FIXED_TIME;
                    req.operation = ENGINE_CTRL_SEARCH_FIXED_TIME;
                    req.time_limit = decode_time(0);
                    issue_single_request(req, RESP_SEARCH, 1'b1, 1'b0);
                end

                ENGINE_CMD_SEARCH_ON_CLOCK: begin
                    active_operation <= ENGINE_CMD_SEARCH_ON_CLOCK;
                    req.operation = ENGINE_CTRL_SEARCH_ON_CLOCK;
                    req.wtime = decode_time(0);
                    req.btime = decode_time(3);
                    req.winc = decode_time(6);
                    req.binc = decode_time(9);
                    issue_single_request(req, RESP_SEARCH, 1'b1, 1'b0);
                end

                ENGINE_CMD_SEARCH_NODES: begin
                    active_operation <= ENGINE_CMD_SEARCH_NODES;
                    req.operation = ENGINE_CTRL_SEARCH_NODES;
                    req.node_limit = decode_node_count();
                    issue_single_request(req, RESP_SEARCH, 1'b1, 1'b0);
                end

                ENGINE_CMD_PERFT: begin
                    active_operation <= ENGINE_CMD_PERFT;
                    req.operation = ENGINE_CTRL_PERFT;
                    req.depth_limit = payload[0];
                    issue_single_request(req, RESP_PERFT, 1'b1, 1'b0);
                end

                ENGINE_CMD_GET_DEBUG_STAT: begin
                    debug_stat_address_reg <= payload[0];
                    start_response(RESP_DEBUG, error_code, 1'b1, 1'b0);
                end

                default: begin
                    latch_error(ENGINE_ERR_UNKNOWN_OPCODE);
                end
            endcase
        end
    endtask : process_payload_command

    always_ff @(posedge clk) begin
        if (!rst_n) begin
            state <= ST_IDLE;
            response_kind <= RESP_NONE;
            response_index <= 4'd0;
            response_status <= 4'h0;
            response_error <= ENGINE_ERR_NONE[2:0];
            response_active_op <= 8'h00;
            error_code <= ENGINE_ERR_NONE[2:0];
            curr_opcode <= 8'h00;
            payload_count <= 6'd0;
            payload_error <= 1'b0;
            direct_index <= 7'd0;
            request_reg <= zero_request();
            request_response_kind <= RESP_NONE;
            request_waits_for_result <= 1'b0;
            request_clears_error <= 1'b0;
            direct_request_inflight <= 1'b0;
            search_active <= 1'b0;
            active_operation <= 8'h00;
            last_move <= Move'('0);
            last_score <= EvalScore'(0);
            last_node_count <= NodeCountType'(0);
            last_completed_depth <= 8'd0;
            last_end_reason <= ENGINE_END_NORMAL[2:0];
            debug_stat_address_reg <= 8'd0;
        end else begin
            case (state)
                ST_IDLE: begin
                    response_kind <= RESP_NONE;
                    response_index <= 4'd0;
                    active_operation <= 8'h00;
                    if (data_in_valid) begin
                        if (!command_known(data_in)) begin
                            latch_error(ENGINE_ERR_UNKNOWN_OPCODE);
                        end else if (payload_len(data_in) != 6'd0) begin
                            curr_opcode <= data_in;
                            payload_count <= 6'd0;
                            payload_error <= 1'b0;
                            active_operation <= data_in;
                            state <= ST_RECEIVE_PAYLOAD;
                        end else begin
                            process_no_payload_command(data_in);
                        end
                    end
                end

                ST_RECEIVE_PAYLOAD: begin
                    if (data_in_valid) begin
                        payload[payload_count] <= data_in;
                        payload_error <= payload_error || payload_byte_invalid(curr_opcode, payload_count, data_in);
                        if (payload_count == payload_len(curr_opcode) - 6'd1) begin
                            state <= ST_PROCESS_PAYLOAD;
                        end else begin
                            payload_count <= payload_count + 6'd1;
                        end
                    end
                end

                ST_PROCESS_PAYLOAD: begin
                    process_payload_command();
                end

                ST_DIRECT_BOARD: begin
                    if (!direct_request_inflight && search_req_ready && !search_resp_valid) begin
                        direct_request_inflight <= 1'b1;
                    end else if ((direct_request_inflight && search_resp_valid)
                            || (!direct_request_inflight && search_req_ready && search_resp_valid)) begin
                        direct_request_inflight <= 1'b0;
                        if (search_resp_valid && search_resp.error) begin
                            error_code <= ENGINE_ERR_INTERNAL[2:0];
                            active_operation <= 8'h00;
                            start_response(RESP_ERROR, ENGINE_ERR_INTERNAL, 1'b1, 1'b0);
                        end else if (direct_index == 7'd67) begin
                            active_operation <= 8'h00;
                            start_response(RESP_ACK, error_code, 1'b1, 1'b0);
                        end else begin
                            direct_index <= direct_index + 7'd1;
                        end
                    end
                end

                ST_ISSUE_REQUEST: begin
                    if (search_req_ready) begin
                        if (request_clears_error) begin
                            error_code <= ENGINE_ERR_NONE[2:0];
                            last_move <= Move'('0);
                            last_score <= EvalScore'(0);
                            last_node_count <= NodeCountType'(0);
                            last_completed_depth <= 8'd0;
                            last_end_reason <= ENGINE_END_NORMAL[2:0];
                        end

                        search_active <= request_waits_for_result;
                        state <= ST_WAIT_RESULT;
                    end
                end

                ST_WAIT_RESULT: begin
                    if (data_in_valid) begin
                        if (search_active && data_in == ENGINE_CMD_KILL) begin
                            issue_kill_request();
                        end else begin
                            latch_error(ENGINE_ERR_MALFORMED_PAYLOAD);
                        end
                    end else if (search_resp_valid) begin
                        search_active <= 1'b0;
                        active_operation <= 8'h00;
                        if (search_resp.error) begin
                            error_code <= ENGINE_ERR_INTERNAL[2:0];
                            last_end_reason <= ENGINE_END_ERROR[2:0];
                            start_response(RESP_ERROR, ENGINE_ERR_INTERNAL, 1'b1, 1'b0);
                        end else begin
                            last_move <= search_resp.best_move;
                            last_score <= search_resp.score;
                            last_node_count <= search_resp.nodes_count;
                            last_completed_depth <= search_resp.completed_depth;
                            last_end_reason <= search_resp.end_reason[2:0];
                            active_operation <= 8'h00;
                            start_response(
                                request_response_kind,
                                request_clears_error ? ENGINE_ERR_NONE : error_code,
                                1'b1,
                                1'b0
                            );
                        end
                    end
                end

                ST_ISSUE_KILL: begin
                    if (search_req_ready) begin
                        state <= ST_WAIT_RESULT;
                    end
                end

                ST_OUTPUT: begin
                    if (ready_for_result) begin
                        if (response_index == response_len(response_kind) - 4'd1) begin
                            response_kind <= RESP_NONE;
                            response_index <= 4'd0;
                            state <= ST_IDLE;
                        end else begin
                            response_index <= response_index + 4'd1;
                        end
                    end
                end

                default: begin
                    latch_error(ENGINE_ERR_INTERNAL);
                end
            endcase
        end
    end

endmodule : engine_command_layer
