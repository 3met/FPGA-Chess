`timescale 1ns/1ps
import chess_defs::*;
import nnue_defs::*;

module tb_nnue_evaluator;
    localparam int TEST_THREADS = 3;
    logic clk = 0, rst_n = 0, clear = 0;
    always #5 clk = !clk;
    logic update_valid = 0, update_ready, update_idle;
    NnueUpdateRequest update_req = '0;
    logic update_done_valid;
    ThreadID update_done_thread;
    PlyIndex update_done_ply;
    logic eval_valid = 0, eval_ready, result_valid;
    ThreadID eval_thread_id = 0;
    NnueSlot eval_slot = '0;
    NnueSlot selected[TEST_THREADS] = '{default:'0};
    bit collecting_test = 0;
    Color eval_turn = WHITE;
    PieceCount eval_piece_count = 2;
    PstEvalPair eval_pst = '0;
    NnueCorrection result;
    PstEvalScore result_pst;
    int pass_count = 0, fail_count = 0;
    int reference_state[TEST_THREADS][NNUE_STATE_VALUE_COUNT];
    int expected_result[$], expected_pst[$];
    int results_seen = 0, updates_seen = 0;
    int cycle_count = 0, last_product_cycle = -1, stream_rows = 0;
    bit check_stream = 0;
    nnue_evaluator #(.STATE_THREAD_COUNT(TEST_THREADS)) dut (.*);

    task automatic check(input bit ok, input string label);
        if (ok) pass_count++;
        else begin fail_count++; $error("%s", label); end
    endtask

    // Independent scalar reference covers all signed accumulator and weight codes.
    function automatic int activation(input int value);
        int positive;
        positive = value < 0 ? 0 : value;
        return positive*positive/8 > 15 ? 15 : positive*positive/8;
    endfunction
    function automatic int wrap(input int value);
        int code;
        code = value & ((1 << NNUE_ACCUMULATOR_BITS)-1);
        return code >= (1 << (NNUE_ACCUMULATOR_BITS-1)) ? code-(1 << NNUE_ACCUMULATOR_BITS) : code;
    endfunction
    function automatic int feature_value(input int feature, input int lane);
        if (feature/64 inside {0,6} && (feature%64)/8 inside {0,7}) return 0;
        return (feature*7 + lane*3 + lane/11)%4 - 2;
    endfunction
    function automatic int bias_value(input int lane);
        return lane % (1 << NNUE_ACCUMULATOR_BIAS_BITS);
    endfunction
    function automatic int weight_value(input int bucket, input int lane);
        return (bucket*3 + lane*7 + lane/13)%16 - 8;
    endfunction

    // The scoreboard checks every response, including overlapped requests.
    always @(negedge clk) begin
        if (rst_n && !clear) begin
            cycle_count++;
            if (result_valid) begin
                int expected;
                check(expected_result.size() != 0, "result has an owning request");
                if (expected_result.size() != 0) begin
                    expected = expected_result.pop_front();
                    check(int'(result) == expected, $sformatf("dot product expected %0d got %0d", expected, result));
                    expected = expected_pst.pop_front();
                    check(int'(result_pst) == expected, "PST stays aligned with its result");
                end
                results_seen++;
            end
            if (update_done_valid) begin
                check(update_done_thread == update_req.thread_id && update_done_ply == update_req.ply,
                    "update completion carries the accepted tag");
                updates_seen++;
            end
            if (check_stream && dut.product_tag.valid) begin
                if (stream_rows != 0) check(cycle_count == last_product_cycle+1, "stream has no idle multiplier cycles");
                last_product_cycle = cycle_count;
                stream_rows++;
            end
        end
    end

    // Honor backpressure and update the reference with modular arithmetic.
    task automatic send_update(input NnueUpdateRequest req);
        @(negedge clk);
        if (!collecting_test) while (!update_idle) @(negedge clk);
        while (!update_ready) @(negedge clk);
        req.source_slot = selected[req.thread_id];
        req.destination_slot = selected[req.thread_id] + NnueSlot'(1);
        update_req = req;
        update_valid = 1;
        @(posedge clk);
        if (req.apply)
            for (int side = 0; side < 2; side++)
                for (int lane = 0; lane < NNUE_ACCUMULATOR_COUNT; lane++) begin
                    automatic int index = side*NNUE_ACCUMULATOR_COUNT+lane;
                    automatic int value = reference_state[req.thread_id][index];
                    automatic int weight = feature_value(side == 0 ? int'(req.white_feature) : int'(req.black_feature), lane);
                    reference_state[req.thread_id][index] = wrap(value + (req.copy ? 0 : req.add ? weight : -weight));
                end
        @(negedge clk);
        update_valid = 0;
        collecting_test = req.combine && !req.complete;
        if (!collecting_test) selected[req.thread_id] = req.destination_slot;
    endtask

    // Moving blend arithmetic between stages must preserve the public latency,
    // including consecutive evaluations with different thread/PST/phase inputs.
    int expected_response_cycle[$];
    int eval_clock = 0;
    always @(posedge clk) begin
        eval_clock++;
        if (!rst_n || clear) expected_response_cycle.delete();
        else begin
            if (eval_valid && eval_ready)
                expected_response_cycle.push_back(eval_clock + NNUE_OUTPUT_MAC_CYCLES + 3);
            #1;
            if (result_valid) begin
                check(expected_response_cycle.size() != 0, "timed result has an owning request");
                if (expected_response_cycle.size() != 0)
                    check(eval_clock == expected_response_cycle.pop_front(),
                        "evaluation latency remains unchanged");
            end
        end
    end

    task automatic send_eval(input int thread, input Color turn, input int piece_count, input int first, input int endgame);
        int expected, bucket, phase;
        @(negedge clk);
        while (!eval_ready) @(negedge clk);
        eval_thread_id = ThreadID'(thread);
        eval_slot = selected[thread];
        eval_turn = turn;
        eval_piece_count = PieceCount'(piece_count);
        eval_pst = '{first: PstEvalScore'(first), endgame: PstEvalScore'(endgame)};
        eval_valid = 1;
        bucket = int'(nnue_output_bucket(PieceCount'(piece_count)));
        expected = bucket*7;
        for (int lane = 0; lane < NNUE_OUTPUT_INPUT_COUNT; lane++) begin
            automatic int state_lane = (lane + (turn == BLACK ? NNUE_ACCUMULATOR_COUNT : 0)) % NNUE_OUTPUT_INPUT_COUNT;
            expected += activation(reference_state[thread][state_lane])*weight_value(bucket,lane);
        end
        phase = piece_count <= 2 ? 0 : piece_count >= 32 ? 30 : piece_count-2;
        expected_result.push_back(expected);
        expected_pst.push_back((first*phase + endgame*(30-phase))/30);
        @(negedge clk);
        eval_valid = 0;
    endtask

    task automatic check_state(input int thread);
        logic [NNUE_STATE_VALUE_COUNT*NNUE_ACCUMULATOR_BITS-1:0] actual;
        wait (update_idle);
        @(negedge clk);
        actual = dut.read_state(thread, selected[thread]);
        for (int lane = 0; lane < NNUE_STATE_VALUE_COUNT; lane++)
            check(int'($signed(actual[lane*NNUE_ACCUMULATOR_BITS +: NNUE_ACCUMULATOR_BITS])) == reference_state[thread][lane],
                "committed accumulator matches reversible scalar update");
    endtask

    initial begin
        #1;
        for (int feature = 0; feature < NNUE_FEATURE_COUNT; feature++) begin
            automatic logic [NNUE_FEATURE_ROW_BITS-1:0] value;
            for (int lane = 0; lane < NNUE_ACCUMULATOR_COUNT; lane++)
                value[lane*2 +: 2] = 2'(feature_value(feature,lane));
            dut.load_feature(feature,value);
        end
        // Model contents at unreachable features must never corrupt idle reads.
        for (int square = 0; square < 8; square++)
            dut.load_feature(square, '1);
        for (int row = 0; row < dut.SIDE_ROWS; row++)
            check(dut.feature_bank0[row] == '0 && dut.feature_bank1[row] == '0
                && dut.feature_bank2[row] == '0, "zero vectors survive unused model entries");
        for (int lane = 0; lane < NNUE_ACCUMULATOR_COUNT; lane++) dut.load_bias(lane, NNUE_ACCUMULATOR_BIAS_BITS'(bias_value(lane)));
        for (int bucket = 0; bucket < NNUE_OUTPUT_BUCKET_COUNT; bucket++) begin
            dut.output_bias[bucket] = 8'(bucket*7);
            for (int lane = 0; lane < NNUE_OUTPUT_INPUT_COUNT; lane++)
                dut.output_weight_rows[bucket*NNUE_OUTPUT_MAC_CYCLES+lane/NNUE_OUTPUT_MAC_LANES][(lane%NNUE_OUTPUT_MAC_LANES)*4 +: 4]
                    = 4'(weight_value(bucket,lane));
        end
        for (int acc = -(1 << (NNUE_ACCUMULATOR_BITS-1)); acc < (1 << (NNUE_ACCUMULATOR_BITS-1)); acc++)
            check(int'(dut.screlu(NnueAccumulator'(acc))) == activation(acc), "SCReLU matches every accumulator code");
        foreach (reference_state[thread, lane])
            reference_state[thread][lane] = bias_value(lane % NNUE_ACCUMULATOR_COUNT);
        repeat (2) @(negedge clk);
        rst_n = 1;
        for (int thread = 0; thread < TEST_THREADS; thread++) begin
            automatic NnueUpdateRequest req = '0;
            req.thread_id = ThreadID'(thread);
            req.white_feature = 8;
            req.black_feature = 432;
            req.apply = 1;
            req.add = 1;
            req.complete = 1;
            req.ply = PlyIndex'(thread+1);
            send_update(req);
            check_state(thread);
        end
        for (int piece_count = 2; piece_count <= 32; piece_count++) begin
            send_eval(piece_count%TEST_THREADS, WHITE, piece_count, -327, 191);
            send_eval(piece_count%TEST_THREADS, BLACK, piece_count, 333, -99);
        end
        wait (expected_result.size() == 0);
        @(negedge clk);
        check_stream = 1;
        for (int request = 0; request < 6; request++)
            send_eval(request%TEST_THREADS, request[0] ? BLACK : WHITE, 2+request*4, 137+request, -83-request);
        wait (expected_result.size() == 0);
        @(negedge clk);
        check_stream = 0;
        check(stream_rows == 6*NNUE_OUTPUT_MAC_CYCLES, "all requested rows used the continuous multiplier stream");

        // A capture batches three features; an inverse batch restores all lanes.
        for (int reverse_move = 0; reverse_move < 2; reverse_move++) begin
            for (int step = 0; step < 3; step++) begin
                automatic NnueUpdateRequest req = '0;
                automatic Position square = step == 0 ? Position'(18) : Position'(27);
                automatic Tile piece = step == 1 ? BLACK_PAWN : WHITE_KNIGHT;
                req.thread_id = 1;
                req.ply = 4;
                req.apply = 1;
                req.combine = 1;
                req.complete = step == 2;
                req.add = (step == 2) ^ (reverse_move != 0);
                req.white_feature = nnue_feature_index(square,piece,WHITE);
                req.black_feature = nnue_feature_index(square,piece,BLACK);
                send_update(req);
            end
            check_state(1);
            send_eval(1, WHITE, 17, 20, -20);
        end
        wait (expected_result.size() == 0);

        // A null move copies the complete two-perspective image without deltas.
        begin
            automatic NnueUpdateRequest req = '0;
            req.thread_id = 1;
            req.apply = 1;
            req.copy = 1;
            req.complete = 1;
            send_update(req);
            check_state(1);
        end

        // Repeated modular overflow and underflow must reverse exactly.
        for (int direction = 0; direction < 2; direction++) begin
            for (int repeat_index = 0; repeat_index < (1 << NNUE_ACCUMULATOR_BITS); repeat_index++) begin
                automatic NnueUpdateRequest req = '0;
                req.apply = 1;
                req.add = direction == 0;
                req.white_feature = 8;
                req.black_feature = 432;
                send_update(req);
            end
            check_state(0);
        end

        // Forward reads take priority while a different thread's update waits.
        fork
            begin
                automatic NnueUpdateRequest req = '0;
                req.thread_id = 2;
                req.apply = 1;
                req.add = 1;
                req.white_feature = 9;
                req.black_feature = 433;
                send_update(req);
            end
            begin
                repeat (5) send_eval(0, BLACK, 32, -1, 0);
            end
        join
        check_state(2);
        send_eval(2, WHITE, 2, 0, 137);
        wait (expected_result.size() == 0);

        // Clear flushes every valid stage without resetting RAM contents.
        send_eval(0, WHITE, 2, 0, 0);
        clear = 1;
        expected_result.delete(); expected_pst.delete();
        @(negedge clk);
        clear = 0;
        repeat (NNUE_OUTPUT_MAC_CYCLES+6) @(negedge clk);
        check(update_idle && eval_ready, "clear returns both request paths to idle");
        send_eval(0, WHITE, 2, 0, 0);
        wait (expected_result.size() == 0);
        @(negedge clk);
        $display("Pass Count: %0d", pass_count);
        $display("Fail Count: %0d", fail_count);
        if (fail_count) $fatal(1,"NNUE evaluator failed");
        $finish;
    end
    initial begin
        #2_000_000;
        $fatal(1,"NNUE evaluator timed out");
    end
endmodule
