// By Emet Behrendt

import chess_defs::*;
import board_update_pipeline_defs::*;
import engine_defs::*;

module engine_command_layer #(
    parameter logic [63:0] BUILD_ID = 64'h0000_0000_0000_0000,
    parameter int CLOCK_FREQ = 100_000_000,
    parameter int SEARCH_THREAD_COUNT = chess_defs::THREAD_COUNT,
    parameter int SEARCH_STACK_DEPTH = chess_defs::MAX_PLY_COUNT
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
    output logic search_resp_ready,
    input EngineControllerResponse search_resp,
    output logic [7:0] debug_stat_address,
    input logic [39:0] debug_stat_value
);

    localparam logic [5:0] RESULT_BASE = 6'd48;
    localparam logic [31:0] BUILD_CLOCK_FREQ = CLOCK_FREQ;
    localparam logic [7:0] BUILD_THREAD_COUNT = 8'(SEARCH_THREAD_COUNT);
    localparam logic [7:0] BUILD_SEARCH_STACK_DEPTH = 8'(SEARCH_STACK_DEPTH);

    typedef enum logic [2:0] {
        RESP_NONE, RESP_STATUS, RESP_ACK, RESP_SEARCH, RESP_PERFT,
        RESP_DEBUG, RESP_ERROR, RESP_BUILD_INFO
    } ResponseKind;

    EngineState state;
    ResponseKind response_kind, request_response_kind;
    logic [3:0] response_index;
    logic [3:0] response_status;
    logic [2:0] response_error, error_code;
    logic [7:0] response_active_op, active_operation, curr_opcode;
    logic [5:0] payload_count;
    logic payload_error, search_active, result_valid, result_error;
    logic [6:0] board_update_index;
    logic [7:0] debug_stat_address_reg;
    // All scalar commands share the largest wire payload, rather than a full request register.
    logic [87:0] operands;

    // A single synchronous byte port serves command staging and the persistent result cache.
    // Memory contents are never reset; control state guards unwritten command/result bytes.
    logic [7:0] scratch [0:63];
    logic [5:0] ram_address;
    logic ram_read, ram_write;
    logic [7:0] ram_data, ram_q;
    always_ff @(posedge clk) begin
        if (ram_write) scratch[ram_address] <= ram_data;
        if (ram_read) ram_q <= scratch[ram_address];
    end

    assign debug_stat_address = debug_stat_address_reg;
    function automatic logic command_known(input logic [7:0] opcode);
        // Command opcodes are distinct; default retains handling of other bytes.
        unique case (opcode)
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
        // Command opcodes are distinct; default retains handling of other bytes.
        unique case (opcode)
            ENGINE_CMD_SET_BOARD:         return 6'd36;
            ENGINE_CMD_MAKE_MOVE:         return 6'd2;
            ENGINE_CMD_SEARCH_DEPTH:      return 6'd1;
            ENGINE_CMD_SEARCH_FIXED_TIME: return 6'd6;
            ENGINE_CMD_SEARCH_ON_CLOCK:   return 6'd11;
            ENGINE_CMD_SEARCH_NODES:      return 6'd5;
            ENGINE_CMD_PERFT:             return 6'd1;
            ENGINE_CMD_GET_DEBUG_STAT:    return 6'd1;
            default:                      return 6'd0;
        endcase
    endfunction : payload_len

    function automatic logic [3:0] response_len(input ResponseKind kind);
        // Response kinds have distinct encodings.
        unique case (kind)
            RESP_STATUS: return 4'd4;
            RESP_ACK:    return 4'd2;
            RESP_SEARCH: return 4'd14;
            RESP_PERFT:  return 4'd7;
            RESP_DEBUG:  return 4'd7;
            RESP_ERROR:  return 4'd3;
            RESP_BUILD_INFO: return 4'd15;
            default:     return 4'd0;
        endcase
    endfunction : response_len

    function automatic logic [7:0] response_type_for(input ResponseKind kind);
        // Response kinds have distinct encodings.
        unique case (kind)
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
        // Command opcodes are distinct; default retains handling of other bytes.
        unique case (opcode)
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

    // Encode directly from the controller's held completion; no duplicate result register bank.
    function automatic logic [7:0] result_byte(input logic [3:0] index);
        unique case (index)
            4'd1: return {search_resp.best_move.to_pos,
                (search_resp.best_move.from_pos == Position'(0) && search_resp.best_move.to_pos == Position'(0))
                    ? 2'b00 : search_resp.best_move.promo_piece};
            4'd2: return {2'b00, search_resp.best_move.from_pos};
            4'd3: return search_resp.score[7:0];
            4'd4: return 8'($signed(search_resp.score) >>> 8);
            4'd5: return search_resp.nodes_count[7:0];
            4'd6: return search_resp.nodes_count[15:8];
            4'd7: return search_resp.nodes_count[23:16];
            4'd8: return search_resp.nodes_count[31:24];
            4'd9: return search_resp.nodes_count[39:32];
            4'd10: return search_resp.completed_depth;
            4'd11: return {5'b0, search_resp.end_reason[2:0]};
            4'd12: return {search_resp.ponder_move.to_pos,
                (search_resp.ponder_move.from_pos == Position'(0) && search_resp.ponder_move.to_pos == Position'(0))
                    ? 2'b00 : search_resp.ponder_move.promo_piece};
            4'd13: return {2'b00, search_resp.ponder_move.from_pos};
            default: return '0;
        endcase
    endfunction : result_byte

    // The FSM makes RAM users mutually exclusive, including cached-result output reads.
    always_comb begin
        ram_address = payload_count;
        ram_read = 1'b0;
        ram_write = 1'b0;
        ram_data = data_in;
        unique case (state)
            CMD_RECEIVE_PAYLOAD: ram_write = data_in_valid;
            CMD_LOAD_READ: ram_read = 1'b1;
            CMD_BOARD_READ: begin
                ram_read = 1'b1;
                if (board_update_index < 7'd64) ram_address = board_update_index[6:1];
                else unique case (board_update_index[1:0])
                    2'd0: ram_address = 6'd32;
                    2'd1: ram_address = 6'd34;
                    2'd2: ram_address = 6'd33;
                    2'd3: ram_address = 6'd35;
                endcase
            end
            CMD_CACHE_RESULT: begin
                ram_address = RESULT_BASE + {2'b0, response_index} - 6'd1;
                ram_data = result_byte(response_index);
                ram_write = search_resp_valid;
            end
            CMD_OUTPUT_READ: begin
                ram_read = 1'b1;
                ram_address = RESULT_BASE + {2'b0, response_index} - 6'd1;
                if (response_kind == RESP_PERFT) ram_address = ram_address + 6'd4;
            end
            default: begin end
        endcase
    end

    // Expand shared wire-format operands only at the controller boundary.
    always_comb begin
        search_req = '0;
        search_req.operation = ENGINE_CTRL_IDLE;
        search_req.board_op = BOARD_IDLE_OP;
        search_req_valid = 1'b0;
        if (state == CMD_BOARD_UPDATE) begin
            search_req_valid = 1'b1;
            search_req.operation = ENGINE_CTRL_BOARD_UPDATE;
            if (board_update_index < 7'd64) begin
                search_req.board_op = BOARD_SET_TILE_OP;
                search_req.move.to_pos = Position'(board_update_index[5:0]);
                search_req.board_wr_data = {3'b0, board_update_index[0] ? ram_q[7:4] : ram_q[3:0]};
            end else unique case (board_update_index[1:0])
                2'd0: begin
                    search_req.board_op = BOARD_SET_CASTLING_RIGHTS_OP;
                    search_req.board_wr_data = {3'b0, ram_q[3:0]};
                end
                2'd1: begin
                    search_req.board_op = BOARD_SET_TURN_OP;
                    search_req.board_wr_data = {6'b0, ram_q[0]};
                end
                2'd2: begin
                    search_req.board_op = BOARD_SET_EN_PASSANT_OP;
                    search_req.board_wr_data = {3'b0, ram_q[3:0]};
                end
                2'd3: begin
                    search_req.board_op = BOARD_SET_HALFMOVE_CLOCK_OP;
                    search_req.board_wr_data = ram_q[6:0];
                end
            endcase
        end else if (state == CMD_ISSUE_KILL) begin
            // A completion that wins the stop race is already held for us to consume.
            search_req_valid = !search_resp_valid;
            search_req.operation = ENGINE_CTRL_KILL;
        end else if (state == CMD_ISSUE_REQUEST) begin
            search_req_valid = 1'b1;
            unique case (curr_opcode)
                ENGINE_CMD_NEW_GAME: search_req.operation = ENGINE_CTRL_NEW_GAME;
                ENGINE_CMD_MAKE_MOVE: begin
                    search_req.operation = ENGINE_CTRL_BOARD_UPDATE;
                    search_req.board_op = BOARD_COMMIT_MOVE_OP;
                    search_req.move = Move'({operands[13:8], operands[7:2], operands[1:0]});
                end
                ENGINE_CMD_SEARCH_DEPTH, ENGINE_CMD_PERFT: begin
                    search_req.operation = curr_opcode == ENGINE_CMD_PERFT ? ENGINE_CTRL_PERFT : ENGINE_CTRL_SEARCH_DEPTH;
                    search_req.depth_limit = operands[7:0];
                end
                ENGINE_CMD_SEARCH_FIXED_TIME: begin
                    search_req.operation = ENGINE_CTRL_SEARCH_FIXED_TIME;
                    search_req.time_limit = operands[23:0];
                    search_req.move_overhead = operands[47:24];
                end
                ENGINE_CMD_SEARCH_ON_CLOCK: begin
                    search_req.operation = ENGINE_CTRL_SEARCH_ON_CLOCK;
                    search_req.remaining_time = operands[23:0];
                    search_req.increment = operands[47:24];
                    search_req.moves_to_go = operands[63:48];
                    search_req.move_overhead = operands[87:64];
                end
                ENGINE_CMD_SEARCH_NODES: begin
                    search_req.operation = ENGINE_CTRL_SEARCH_NODES;
                    search_req.node_limit = operands[39:0];
                end
                default: begin end
            endcase
        end
    end

    assign ready = state == CMD_IDLE || state == CMD_RECEIVE_PAYLOAD || state == CMD_WAIT_RESULT;
    assign data_out_valid = state == CMD_OUTPUT && ready_for_result;
    assign error_flag = error_code != '0;
    // Hold live search results for caching. Drain abandoned completions in all other states
    // so a protocol error cannot leave a later command waiting behind an unaccepted response.
    always_comb begin
        search_resp_ready = 1'b1;
        if (state == CMD_WAIT_RESULT && search_active && !search_resp.error)
            search_resp_ready = 1'b0;
        if (state == CMD_CACHE_RESULT) search_resp_ready = response_index == 4'd13;
        if (state == CMD_ISSUE_KILL) search_resp_ready = 1'b0;
    end

    // Cache reads and constant/status responses share the same byte-at-a-time transmitter.
    always_comb begin
        data_out = 'x;
        if (response_index == 4'd0) data_out = response_type_for(response_kind);
        else unique case (response_kind)
            RESP_STATUS: unique case (response_index)
                4'd1: data_out = {4'b0, response_status};
                4'd2: data_out = {5'b0, response_error};
                4'd3: data_out = response_active_op;
                default: data_out = 'x;
            endcase
            RESP_ACK: data_out = {4'b0, response_status};
            RESP_ERROR: data_out = response_index == 4'd1 ? {5'b0, response_error} : {4'b0, response_status};
            RESP_SEARCH, RESP_PERFT: begin
                data_out = result_valid ? ram_q : 8'd0;
                if (response_kind == RESP_SEARCH && response_index == 4'd11 && result_error)
                    data_out = ENGINE_END_ERROR;
            end
            RESP_DEBUG: unique case (response_index)
                4'd1: data_out = debug_stat_address_reg;
                4'd2: data_out = debug_stat_value[7:0];
                4'd3: data_out = debug_stat_value[15:8];
                4'd4: data_out = debug_stat_value[23:16];
                4'd5: data_out = debug_stat_value[31:24];
                4'd6: data_out = debug_stat_value[39:32];
                default: data_out = 'x;
            endcase
            RESP_BUILD_INFO: begin
                // Explicit byte indices are distinct; default retains unused-index behavior.
                unique case (response_index)
                    4'd1:  data_out = BUILD_ID[7:0];
                    4'd2:  data_out = BUILD_ID[15:8];
                    4'd3:  data_out = BUILD_ID[23:16];
                    4'd4:  data_out = BUILD_ID[31:24];
                    4'd5:  data_out = BUILD_ID[39:32];
                    4'd6:  data_out = BUILD_ID[47:40];
                    4'd7:  data_out = BUILD_ID[55:48];
                    4'd8:  data_out = BUILD_ID[63:56];
                    4'd9:  data_out = BUILD_THREAD_COUNT;
                    4'd10: data_out = BUILD_CLOCK_FREQ[7:0];
                    4'd11: data_out = BUILD_CLOCK_FREQ[15:8];
                    4'd12: data_out = BUILD_CLOCK_FREQ[23:16];
                    4'd13: data_out = BUILD_CLOCK_FREQ[31:24];
                    4'd14: data_out = BUILD_SEARCH_STACK_DEPTH;
                    default: data_out = 'x;
                endcase
            end

            default: data_out = 'x;
        endcase
    end

    // Snapshot only response control; data lives in RAM or the held controller completion.
    task automatic start_response(input ResponseKind kind, input logic [2:0] err, input logic searching);
        response_kind <= kind;
        response_index <= 4'd0;
        response_error <= err;
        response_active_op <= searching ? active_operation : 8'd0;
        response_status <= {err != 3'd0, 1'b0, searching, 1'b1};
        state <= CMD_OUTPUT_READ;
    endtask : start_response

    // Protocol errors leave the last completed search cache intact.
    task automatic latch_error(input logic [7:0] err);
        error_code <= err[2:0];
        active_operation <= 8'd0;
        search_active <= 1'b0;
        start_response(RESP_ERROR, err[2:0], 1'b0);
    endtask : latch_error

    // Advance a board replay only after the individual controller operation completes.
    task automatic finish_board_update();
        if (search_resp.error) latch_error(ENGINE_ERR_INTERNAL);
        else if (board_update_index == 7'd67) start_response(RESP_ACK, error_code, 1'b0);
        else begin
            board_update_index <= board_update_index + 7'd1;
            state <= CMD_BOARD_READ;
        end
    endtask : finish_board_update

    always_ff @(posedge clk) begin
        if (!rst_n) begin
            state <= CMD_IDLE;
            response_kind <= RESP_NONE;
            request_response_kind <= RESP_NONE;
            response_index <= '0;
            response_status <= '0;
            response_error <= '0;
            response_active_op <= '0;
            error_code <= '0;
            active_operation <= '0;
            curr_opcode <= '0;
            payload_count <= '0;
            payload_error <= 1'b0;
            search_active <= 1'b0;
            result_valid <= 1'b0;
            result_error <= 1'b0;
            board_update_index <= '0;
            debug_stat_address_reg <= '0;
        end else unique case (state)
            CMD_IDLE: begin
                active_operation <= 8'd0;
                if (data_in_valid) begin
                    curr_opcode <= data_in;
                    if (!command_known(data_in)) latch_error(ENGINE_ERR_UNKNOWN_OPCODE);
                    else if (payload_len(data_in) != 0) begin
                        payload_count <= 6'd0;
                        payload_error <= 1'b0;
                        active_operation <= data_in;
                        state <= CMD_RECEIVE_PAYLOAD;
                    end else unique case (data_in)
                        ENGINE_CMD_GET_STATUS: start_response(RESP_STATUS, error_code, 1'b0);
                        ENGINE_CMD_GET_SEARCH_RESULT: start_response(RESP_SEARCH, error_code, 1'b0);
                        ENGINE_CMD_GET_BUILD_INFO: start_response(RESP_BUILD_INFO, error_code, 1'b0);
                        ENGINE_CMD_NEW_GAME: begin
                            request_response_kind <= RESP_ACK;
                            state <= CMD_ISSUE_REQUEST;
                        end
                        ENGINE_CMD_KILL: begin end
                        default: latch_error(ENGINE_ERR_UNKNOWN_OPCODE);
                    endcase
                end
            end
            CMD_RECEIVE_PAYLOAD: if (data_in_valid) begin
                payload_error <= payload_error || payload_byte_invalid(curr_opcode, payload_count, data_in);
                if (payload_count == payload_len(curr_opcode) - 6'd1) state <= CMD_PROCESS_PAYLOAD;
                else payload_count <= payload_count + 6'd1;
            end
            CMD_PROCESS_PAYLOAD: begin
                if (payload_error) latch_error(ENGINE_ERR_MALFORMED_PAYLOAD);
                else if (curr_opcode == ENGINE_CMD_SET_BOARD) begin
                    board_update_index <= 7'd0;
                    state <= CMD_BOARD_READ;
                end else begin
                    // Read all operand lanes in a fixed sequence; unused lanes are ignored by the opcode.
                    payload_count <= 6'd0;
                    state <= CMD_LOAD_READ;
                end
            end
            CMD_LOAD_READ: state <= CMD_LOAD_LATCH;
            CMD_LOAD_LATCH: begin
                operands <= {ram_q, operands[87:8]};
                if (payload_count == 6'd10) begin
                    if (curr_opcode == ENGINE_CMD_GET_DEBUG_STAT) begin
                        // Byte zero is the final low byte after this last shift.
                        debug_stat_address_reg <= operands[15:8];
                        start_response(RESP_DEBUG, error_code, 1'b0);
                    end else begin
                        request_response_kind <= curr_opcode == ENGINE_CMD_MAKE_MOVE ? RESP_ACK
                            : curr_opcode == ENGINE_CMD_PERFT ? RESP_PERFT : RESP_SEARCH;
                        state <= CMD_ISSUE_REQUEST;
                    end
                end else begin
                    payload_count <= payload_count + 6'd1;
                    state <= CMD_LOAD_READ;
                end
            end
            CMD_BOARD_READ: state <= CMD_BOARD_UPDATE;
            CMD_BOARD_UPDATE: if (search_req_ready) begin
                if (search_resp_valid) finish_board_update();
                else state <= CMD_BOARD_WAIT;
            end
            CMD_BOARD_WAIT: if (search_resp_valid) finish_board_update();
            CMD_ISSUE_REQUEST: if (search_req_ready) begin
                search_active <= request_response_kind == RESP_SEARCH || request_response_kind == RESP_PERFT;
                if (curr_opcode == ENGINE_CMD_NEW_GAME) begin
                    error_code <= '0;
                    result_valid <= 1'b0;
                    result_error <= 1'b0;
                end
                state <= CMD_WAIT_RESULT;
            end
            CMD_WAIT_RESULT: begin
                if (data_in_valid && !(search_active && data_in == ENGINE_CMD_KILL))
                    latch_error(ENGINE_ERR_MALFORMED_PAYLOAD);
                else if (search_resp_valid) begin
                    if (search_resp.error) begin
                        result_error <= 1'b1;
                        latch_error(ENGINE_ERR_INTERNAL);
                    end else if (search_active) begin
                        if (data_in_valid) request_response_kind <= RESP_STATUS;
                        response_index <= 4'd1;
                        state <= CMD_CACHE_RESULT;
                    end else start_response(request_response_kind, error_code, 1'b0);
                end else if (data_in_valid) begin
                    request_response_kind <= RESP_STATUS;
                    state <= CMD_ISSUE_KILL;
                end
            end
            CMD_ISSUE_KILL: if (search_req_ready || search_resp_valid) state <= CMD_WAIT_RESULT;
            CMD_CACHE_RESULT: if (search_resp_valid) begin
                if (response_index == 4'd13) begin
                    result_valid <= 1'b1;
                    result_error <= 1'b0;
                    search_active <= 1'b0;
                    start_response(request_response_kind, error_code, 1'b0);
                end else response_index <= response_index + 4'd1;
            end
            CMD_OUTPUT_READ: state <= CMD_OUTPUT;
            CMD_OUTPUT: if (ready_for_result) begin
                if (response_index == response_len(response_kind) - 4'd1) state <= CMD_IDLE;
                else begin
                    response_index <= response_index + 4'd1;
                    state <= CMD_OUTPUT_READ;
                end
            end
            default: latch_error(ENGINE_ERR_INTERNAL);
        endcase
    end
endmodule : engine_command_layer
