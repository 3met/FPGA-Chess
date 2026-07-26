`timescale 1ns/1ns

import general_chess_defs::*;
import board_update_pipeline_defs::*;
import engine_defs::*;

module tb_engine;

    logic clk;
    logic rst_n;
    logic [7:0] data_in;
    logic data_in_valid;
    logic ready_for_result;
    logic error_flag;
    logic ready;
    logic [7:0] data_out;
    logic data_out_valid;

    logic search_req_valid;
    logic search_req_ready;
    EngineControllerRequest search_req;
    logic search_resp_valid;
    EngineControllerResponse search_resp;
    logic [7:0] debug_stat_address;
    logic [39:0] debug_stat_value;

    assign debug_stat_value = 40'd0;

    int pass_count = 0;
    int fail_count = 0;

    engine_command_layer dut (
        .clk(clk),
        .rst_n(rst_n),
        .data_in(data_in),
        .data_in_valid(data_in_valid),
        .ready_for_result(ready_for_result),
        .error_flag(error_flag),
        .ready(ready),
        .data_out(data_out),
        .data_out_valid(data_out_valid),
        .search_req_valid(search_req_valid),
        .search_req_ready(search_req_ready),
        .search_req(search_req),
        .search_resp_valid(search_resp_valid),
        .search_resp(search_resp),
        .debug_stat_address(debug_stat_address),
        .debug_stat_value(debug_stat_value)
    );

    task automatic do_clock(input int count = 1);
        for (int idx = 0; idx < count; idx++) begin
            clk = 1'b0; #5;
            clk = 1'b1; #5;
        end
    endtask : do_clock

    task automatic check(input logic condition, input string label);
        if (condition) begin
            pass_count += 1;
        end else begin
            fail_count += 1;
            $error("[FAIL] %s", label);
        end
    endtask : check

    task automatic reset_dut();
        data_in = 8'h00;
        data_in_valid = 1'b0;
        ready_for_result = 1'b1;
        search_req_ready = 1'b1;
        search_resp_valid = 1'b0;
        search_resp = EngineControllerResponse'('0);
        rst_n = 1'b0;
        do_clock(3);
        rst_n = 1'b1;
        do_clock(2);
        check(ready, "engine ready after reset");
        check(!error_flag, "error clear after reset");
    endtask : reset_dut

    task automatic send_byte(input logic [7:0] value);
        while (!ready) begin
            do_clock(1);
        end
        data_in = value;
        data_in_valid = 1'b1;
        do_clock(1);
        data_in_valid = 1'b0;
        data_in = 8'h00;
    endtask : send_byte

    task automatic expect_byte(input logic [7:0] expected, input string label);
        #1;
        while (!data_out_valid) begin
            do_clock(1);
        end
        #1;
        if (data_out !== expected) begin
            $display("[BYTE MISMATCH] %s expected=0x%02h actual=0x%02h time=%0t", label, expected, data_out, $time);
        end
        check(data_out === expected, label);
        do_clock(1);
    endtask : expect_byte

    task automatic accept_request(output EngineControllerRequest captured);
        #1;
        while (!search_req_valid) begin
            do_clock(1);
        end
        #1;
        captured = search_req;
        if (captured.operation == ENGINE_CTRL_DIRECT_BOARD
                && captured.direct_board_op != BOARD_COMMIT_MOVE_OP
                && captured.direct_board_op != BOARD_REVERSE_MOVE_OP) begin
            search_resp = EngineControllerResponse'('0);
            search_resp_valid = 1'b1;
            do_clock(1);
            search_resp_valid = 1'b0;
            search_resp = EngineControllerResponse'('0);
        end else if (captured.operation == ENGINE_CTRL_DIRECT_BOARD
                || captured.operation == ENGINE_CTRL_NEW_GAME
                || captured.operation == ENGINE_CTRL_KILL) begin
            do_clock(1);
            search_resp = EngineControllerResponse'('0);
            if (captured.operation == ENGINE_CTRL_KILL) begin
                search_resp.end_reason = ENGINE_END_KILLED;
            end
            search_resp_valid = 1'b1;
            do_clock(1);
            search_resp_valid = 1'b0;
            search_resp = EngineControllerResponse'('0);
        end else begin
            do_clock(1);
        end
    endtask : accept_request

    task automatic capture_request_without_response(output EngineControllerRequest captured);
        #1;
        while (!search_req_valid) begin
            do_clock(1);
        end
        #1;
        captured = search_req;
        do_clock(1);
    endtask : capture_request_without_response

    task automatic expect_no_output(input int cycles, input string label);
        for (int idx = 0; idx < cycles; idx++) begin
            #1;
            check(!data_out_valid, $sformatf("%s no output cycle %0d", label, idx));
            do_clock(1);
        end
    endtask : expect_no_output

    task automatic send_mock_response(
        input Move best_move,
        input EvalScore score,
        input NodeCountType nodes,
        input logic [7:0] depth,
        input logic [7:0] end_reason
    );
        search_resp = EngineControllerResponse'('0);
        search_resp.best_move = best_move;
        search_resp.score = score;
        search_resp.nodes_count = nodes;
        search_resp.completed_depth = depth;
        search_resp.end_reason = end_reason;
        search_resp_valid = 1'b1;
        do_clock(1);
        search_resp_valid = 1'b0;
        search_resp = EngineControllerResponse'('0);
    endtask : send_mock_response

    function automatic Move make_move(input Position from_pos, input Position to_pos, input PromoType promo);
        automatic Move move;

        move.from_pos = from_pos;
        move.to_pos = to_pos;
        move.promo_piece = promo;
        return move;
    endfunction : make_move

    task automatic expect_status_response(
        input logic [7:0] expected_status,
        input logic [7:0] expected_error,
        input logic [7:0] expected_active
    );
        expect_byte(ENGINE_RESP_STATUS, "status response type");
        expect_byte(expected_status, "status response status byte");
        expect_byte(expected_error, "status response error byte");
        expect_byte(expected_active, "status response active op");
    endtask : expect_status_response

    task automatic expect_ack(input logic [7:0] expected_status);
        expect_byte(ENGINE_RESP_ACK, "ack response type");
        expect_byte(expected_status, "ack status byte");
    endtask : expect_ack

    task automatic expect_error_response(input logic [7:0] expected_error);
        expect_byte(ENGINE_RESP_ERROR, "error response type");
        expect_byte(expected_error, "error response code");
        expect_byte(8'h09, "error response status byte");
        check(error_flag, "error flag latched");
    endtask : expect_error_response

    task automatic clear_error_with_new_game();
        automatic EngineControllerRequest captured;

        send_byte(ENGINE_CMD_NEW_GAME);
        accept_request(captured);
        check(captured.operation == ENGINE_CTRL_NEW_GAME, "new game request op");
        expect_ack(8'h01);
        check(!error_flag, "new game clears error");
    endtask : clear_error_with_new_game

    task automatic test_status_and_errors();
        $display("=== engine status and error tests ===");
        send_byte(ENGINE_CMD_GET_STATUS);
        expect_status_response(8'h01, ENGINE_ERR_NONE, 8'h00);

        send_byte(ENGINE_CMD_GET_DEBUG_STAT);
        send_byte(8'd0);
        expect_byte(ENGINE_RESP_DEBUG_STAT, "debug statistic response type");
        expect_byte(8'd0, "debug statistic address");
        for (int idx = 0; idx < 5; idx++) begin
            expect_byte(8'd0, "disabled debug statistic value");
        end

        ready_for_result = 1'b0;
        send_byte(ENGINE_CMD_GET_STATUS);
        do_clock(5);
        check(!data_out_valid, "output pauses when downstream not ready");
        ready_for_result = 1'b1;
        expect_status_response(8'h01, ENGINE_ERR_NONE, 8'h00);

        send_byte(8'h55);
        expect_error_response(ENGINE_ERR_UNKNOWN_OPCODE);
        clear_error_with_new_game();

        send_byte(8'h03);
        expect_error_response(ENGINE_ERR_UNKNOWN_OPCODE);
        clear_error_with_new_game();

        send_byte(ENGINE_CMD_MAKE_MOVE);
        do_clock(2);
        send_byte(8'h00);
        send_byte(8'h80);
        expect_error_response(ENGINE_ERR_MALFORMED_PAYLOAD);
        clear_error_with_new_game();

        send_byte(ENGINE_CMD_SET_BOARD);
        for (int idx = 0; idx < 32; idx++) begin
            send_byte((idx == 3) ? 8'h07 : 8'h00);
        end
        send_byte(8'h00);
        send_byte(8'h00);
        send_byte(8'h00);
        send_byte(8'h00);
        expect_error_response(ENGINE_ERR_MALFORMED_PAYLOAD);
        clear_error_with_new_game();

        send_byte(ENGINE_CMD_SET_BOARD);
        for (int idx = 0; idx < 32; idx++) begin
            send_byte(8'h00);
        end
        send_byte(8'h10);
        send_byte(8'h00);
        send_byte(8'h00);
        send_byte(8'h00);
        expect_error_response(ENGINE_ERR_MALFORMED_PAYLOAD);
        clear_error_with_new_game();
    endtask : test_status_and_errors

    task automatic test_set_board_and_moves();
        automatic logic [7:0] board_payload [0:35];
        automatic EngineControllerRequest captured;

        $display("=== engine direct-board tests ===");
        for (int idx = 0; idx < 36; idx++) begin
            board_payload[idx] = 8'h00;
        end
        board_payload[0] = 8'he1;
        board_payload[32] = 8'h0f;
        board_payload[33] = 8'h05;
        board_payload[34] = 8'h01;
        board_payload[35] = 8'h02;

        send_byte(ENGINE_CMD_SET_BOARD);
        for (int idx = 0; idx < 36; idx++) begin
            send_byte(board_payload[idx]);
        end

        for (int idx = 0; idx < 68; idx++) begin
            accept_request(captured);
            check(captured.operation == ENGINE_CTRL_DIRECT_BOARD, $sformatf("set board direct op %0d", idx));
            if (idx == 0) begin
                check(captured.direct_board_op == BOARD_SET_TILE_OP, "set board tile 0 op");
                check(captured.move.to_pos == Position'('d0), "set board tile 0 position");
                check(captured.board_wr_data[3:0] == 4'h1, "set board tile 0 data");
            end else if (idx == 1) begin
                check(captured.direct_board_op == BOARD_SET_TILE_OP, "set board tile 1 op");
                check(captured.move.to_pos == Position'('d1), "set board tile 1 position");
                check(captured.board_wr_data[3:0] == 4'he, "set board tile 1 data");
            end else if (idx == 64) begin
                check(captured.direct_board_op == BOARD_SET_CASTLE_PERMS_OP, "set board castle op");
                check(captured.board_wr_data[3:0] == 4'hf, "set board castle data");
            end else if (idx == 65) begin
                check(captured.direct_board_op == BOARD_SET_EN_PASSANT_OP, "set board ep op");
                check(captured.board_wr_data[3:0] == 4'h5, "set board ep data");
            end else if (idx == 66) begin
                check(captured.direct_board_op == BOARD_SET_TURN_OP, "set board turn op");
                check(captured.board_wr_data[0] == 1'b1, "set board turn data");
            end else if (idx == 67) begin
                check(captured.direct_board_op == BOARD_SET_HALFMOVE_CLOCK_OP, "set board halfmove op");
                check(captured.board_wr_data == 7'd2, "set board halfmove data");
            end
        end
        expect_ack(8'h01);

        send_byte(ENGINE_CMD_MAKE_MOVE);
        send_byte(8'h72);
        send_byte(8'h0c);
        capture_request_without_response(captured);
        check(captured.operation == ENGINE_CTRL_DIRECT_BOARD, "make move direct op");
        check(captured.direct_board_op == BOARD_COMMIT_MOVE_OP, "make move commit board op");
        check(captured.move.from_pos == Position'('d12), "make move from position");
        check(captured.move.to_pos == Position'('d28), "make move to position");
        check(captured.move.promo_piece == PROMO_ROOK, "make move promo");
        expect_no_output(5, "make move waits for controller completion");
        send_mock_response(NULL_MOVE, EvalScore'(0), NodeCountType'(0), 8'd0, ENGINE_END_NORMAL);
        expect_ack(8'h01);

    endtask : test_set_board_and_moves

    task automatic test_search_and_perft();
        automatic EngineControllerRequest captured;
        automatic Move best_move;

        $display("=== engine search/perft tests ===");
        best_move = make_move(Position'('d12), Position'('d28), PROMO_QUEEN);

        send_byte(ENGINE_CMD_SEARCH_DEPTH);
        send_byte(8'd5);
        accept_request(captured);
        check(captured.operation == ENGINE_CTRL_SEARCH_DEPTH, "search depth request op");
        check(captured.depth_limit == 8'd5, "search depth limit");
        do_clock(2);
        send_mock_response(best_move, EvalScore'(-16), NodeCountType'(40'h0102_0304_05), 8'd5, ENGINE_END_DEPTH_LIMIT);
        expect_byte(ENGINE_RESP_SEARCH_RESULT, "search response type");
        expect_byte(8'h70, "search best move byte 0");
        expect_byte(8'h0c, "search best move byte 1");
        expect_byte(8'hf0, "search score byte 0");
        expect_byte(8'hff, "search score byte 1");
        expect_byte(8'h05, "search nodes byte 0");
        expect_byte(8'h04, "search nodes byte 1");
        expect_byte(8'h03, "search nodes byte 2");
        expect_byte(8'h02, "search nodes byte 3");
        expect_byte(8'h01, "search nodes byte 4");
        expect_byte(8'h05, "search completed depth");
        expect_byte(ENGINE_END_DEPTH_LIMIT, "search end reason");

        send_byte(ENGINE_CMD_GET_SEARCH_RESULT);
        expect_byte(ENGINE_RESP_SEARCH_RESULT, "cached search response type");
        expect_byte(8'h70, "cached search best move byte 0");
        expect_byte(8'h0c, "cached search best move byte 1");
        expect_byte(8'hf0, "cached search score byte 0");
        expect_byte(8'hff, "cached search score byte 1");
        expect_byte(8'h05, "cached search nodes byte 0");
        expect_byte(8'h04, "cached search nodes byte 1");
        expect_byte(8'h03, "cached search nodes byte 2");
        expect_byte(8'h02, "cached search nodes byte 3");
        expect_byte(8'h01, "cached search nodes byte 4");
        expect_byte(8'h05, "cached search completed depth");
        expect_byte(ENGINE_END_DEPTH_LIMIT, "cached search end reason");

        send_byte(ENGINE_CMD_PERFT);
        send_byte(8'd3);
        accept_request(captured);
        check(captured.operation == ENGINE_CTRL_PERFT, "perft request op");
        check(captured.depth_limit == 8'd3, "perft depth limit");
        do_clock(1);
        send_mock_response(best_move, EvalScore'(0), NodeCountType'(40'h0000_0000_2a), 8'd3, ENGINE_END_DEPTH_LIMIT);
        expect_byte(ENGINE_RESP_PERFT_RESULT, "perft response type");
        expect_byte(8'h2a, "perft nodes byte 0");
        expect_byte(8'h00, "perft nodes byte 1");
        expect_byte(8'h00, "perft nodes byte 2");
        expect_byte(8'h00, "perft nodes byte 3");
        expect_byte(8'h00, "perft nodes byte 4");
        expect_byte(8'h03, "perft completed depth");
    endtask : test_search_and_perft

    task automatic test_search_limit_payloads();
        automatic EngineControllerRequest captured;
        automatic Move best_move;

        $display("=== engine search payload tests ===");
        best_move = make_move(Position'('d8), Position'('d16), PROMO_KNIGHT);

        send_byte(ENGINE_CMD_SEARCH_FIXED_TIME);
        send_byte(8'h56);
        send_byte(8'h34);
        send_byte(8'h12);
        accept_request(captured);
        check(captured.operation == ENGINE_CTRL_SEARCH_FIXED_TIME, "fixed-time request op");
        check(captured.time_limit == TimeType'(24'h123456), "fixed-time payload little-endian");
        send_mock_response(best_move, EvalScore'(12), NodeCountType'(2), 8'd0, ENGINE_END_TIME_LIMIT);
        expect_byte(ENGINE_RESP_SEARCH_RESULT, "fixed-time response type");
        expect_byte(8'h41, "fixed-time best move byte 0");
        expect_byte(8'h08, "fixed-time best move byte 1");
        expect_byte(8'h0c, "fixed-time score byte 0");
        expect_byte(8'h00, "fixed-time score byte 1");
        expect_byte(8'h02, "fixed-time nodes byte 0");
        expect_byte(8'h00, "fixed-time nodes byte 1");
        expect_byte(8'h00, "fixed-time nodes byte 2");
        expect_byte(8'h00, "fixed-time nodes byte 3");
        expect_byte(8'h00, "fixed-time nodes byte 4");
        expect_byte(8'h00, "fixed-time completed depth");
        expect_byte(ENGINE_END_TIME_LIMIT, "fixed-time end reason");

        send_byte(ENGINE_CMD_SEARCH_ON_CLOCK);
        send_byte(8'h01);
        send_byte(8'h00);
        send_byte(8'h00);
        send_byte(8'h02);
        send_byte(8'h00);
        send_byte(8'h00);
        send_byte(8'h03);
        send_byte(8'h00);
        send_byte(8'h00);
        send_byte(8'h04);
        send_byte(8'h00);
        send_byte(8'h00);
        accept_request(captured);
        check(captured.operation == ENGINE_CTRL_SEARCH_ON_CLOCK, "clock search request op");
        check(captured.wtime == TimeType'(1), "clock search wtime");
        check(captured.btime == TimeType'(2), "clock search btime");
        check(captured.winc == TimeType'(3), "clock search winc");
        check(captured.binc == TimeType'(4), "clock search binc");
        send_mock_response(best_move, EvalScore'(0), NodeCountType'(3), 8'd1, ENGINE_END_TIME_LIMIT);
        expect_byte(ENGINE_RESP_SEARCH_RESULT, "clock search response type");
        expect_byte(8'h41, "clock search best move byte 0");
        expect_byte(8'h08, "clock search best move byte 1");
        expect_byte(8'h00, "clock search score byte 0");
        expect_byte(8'h00, "clock search score byte 1");
        expect_byte(8'h03, "clock search nodes byte 0");
        expect_byte(8'h00, "clock search nodes byte 1");
        expect_byte(8'h00, "clock search nodes byte 2");
        expect_byte(8'h00, "clock search nodes byte 3");
        expect_byte(8'h00, "clock search nodes byte 4");
        expect_byte(8'h01, "clock search completed depth");
        expect_byte(ENGINE_END_TIME_LIMIT, "clock search end reason");

        send_byte(ENGINE_CMD_SEARCH_NODES);
        send_byte(8'h05);
        send_byte(8'h04);
        send_byte(8'h03);
        send_byte(8'h02);
        send_byte(8'h01);
        accept_request(captured);
        check(captured.operation == ENGINE_CTRL_SEARCH_NODES, "normal nodes request op");
        check(captured.node_limit == NodeCountType'(40'h0102_0304_05), "normal nodes payload little-endian");
        send_mock_response(best_move, EvalScore'(0), NodeCountType'(5), 8'd2, ENGINE_END_NODE_LIMIT);
        expect_byte(ENGINE_RESP_SEARCH_RESULT, "normal nodes response type");
        expect_byte(8'h41, "normal nodes best move byte 0");
        expect_byte(8'h08, "normal nodes best move byte 1");
        expect_byte(8'h00, "normal nodes score byte 0");
        expect_byte(8'h00, "normal nodes score byte 1");
        expect_byte(8'h05, "normal nodes count byte 0");
        expect_byte(8'h00, "normal nodes count byte 1");
        expect_byte(8'h00, "normal nodes count byte 2");
        expect_byte(8'h00, "normal nodes count byte 3");
        expect_byte(8'h00, "normal nodes count byte 4");
        expect_byte(8'h02, "normal nodes completed depth");
        expect_byte(ENGINE_END_NODE_LIMIT, "normal nodes end reason");
    endtask : test_search_limit_payloads

    task automatic test_kill_and_active_reject();
        automatic EngineControllerRequest captured;

        $display("=== engine kill tests ===");
        send_byte(ENGINE_CMD_SEARCH_NODES);
        send_byte(8'h01);
        send_byte(8'h00);
        send_byte(8'h00);
        send_byte(8'h00);
        send_byte(8'h00);
        accept_request(captured);
        check(captured.operation == ENGINE_CTRL_SEARCH_NODES, "search nodes request op");
        check(captured.node_limit == NodeCountType'(1), "search nodes limit");

        send_byte(ENGINE_CMD_KILL);
        accept_request(captured);
        check(captured.operation == ENGINE_CTRL_KILL, "in-band kill request op");
        expect_status_response(8'h01, ENGINE_ERR_NONE, 8'h00);

        send_byte(ENGINE_CMD_SEARCH_DEPTH);
        send_byte(8'd4);
        accept_request(captured);
        check(captured.operation == ENGINE_CTRL_SEARCH_DEPTH, "reject test search request op");
        send_byte(ENGINE_CMD_GET_STATUS);
        expect_error_response(ENGINE_ERR_MALFORMED_PAYLOAD);
        clear_error_with_new_game();
    endtask : test_kill_and_active_reject

    initial begin
        reset_dut();
        test_status_and_errors();
        test_set_board_and_moves();
        test_search_and_perft();
        test_search_limit_payloads();
        test_kill_and_active_reject();

        $display("Pass Count: %0d", pass_count);
        $display("Fail Count: %0d", fail_count);
        if (fail_count != 0) begin
            $fatal(1, "engine testbench failed");
        end
        $finish;
    end

    initial begin
        #200_000;
        fail_count += 1;
        $error("[FAIL] tb_engine timeout");
        $display("Pass Count: %0d", pass_count);
        $display("Fail Count: %0d", fail_count);
        $fatal(1, "tb_engine timeout");
    end

endmodule : tb_engine
