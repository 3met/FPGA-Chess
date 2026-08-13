`timescale 1ns/1ps

import general_chess_defs::*;
import nnue_defs::*;

module tb_nnue_evaluator;
    logic clk = 1'b0;
    logic rst_n = 1'b0;
    logic clear;
    logic update_valid, update_ready, update_idle;
    NnueUpdateRequest update_req;
    logic update_done_valid;
    ThreadID update_done_thread;
    PlyIndex update_done_ply;
    logic eval_valid, eval_ready, result_valid;
    ThreadID eval_thread_id;
    Color eval_turn;
    PieceCount eval_piece_count;
    EvalScore result;
    logic single_update_valid, single_update_ready, single_update_idle;
    NnueUpdateRequest single_update_req;
    logic single_eval_valid, single_eval_ready, single_result_valid;
    EvalScore single_result;
    int pass_count = 0;
    int fail_count = 0;

    always #5 clk = ~clk;

    nnue_evaluator #(.STATE_THREAD_COUNT(9)) dut (
        .clk, .rst_n, .clear, .update_valid, .update_ready, .update_idle, .update_req,
        .update_done_valid, .update_done_thread, .update_done_ply,
        .eval_valid, .eval_ready, .eval_thread_id, .eval_turn, .eval_piece_count,
        .result_valid, .result
    );

    // Exercise the single-thread state path used by the DE1-SoC build.
    nnue_evaluator #(.STATE_THREAD_COUNT(1)) single_dut (
        .clk, .rst_n, .clear,
        .update_valid(single_update_valid), .update_ready(single_update_ready),
        .update_idle(single_update_idle), .update_req(single_update_req),
        .update_done_valid(), .update_done_thread(), .update_done_ply(),
        .eval_valid(single_eval_valid), .eval_ready(single_eval_ready),
        .eval_thread_id(ThreadID'(0)), .eval_turn(WHITE),
        .eval_piece_count(PieceCount'(2)),
        .result_valid(single_result_valid), .result(single_result)
    );

    task automatic check(input logic condition, input string label);
        if (condition)
            pass_count++;
        else begin
            fail_count++;
            $error("[FAIL] %s", label);
        end
    endtask

    task automatic enqueue(input NnueUpdateRequest request);
        @(negedge clk);
        while (!update_ready)
            @(negedge clk);
        update_req = request;
        update_valid = 1;
        @(negedge clk);
        update_valid = 0;
    endtask

    task automatic evaluate(input EvalScore expected, input string label);
        @(negedge clk);
        eval_valid = 1;
        @(negedge clk);
        eval_valid = 0;
        wait (result_valid);
        check(result == expected, label);
    endtask

    task automatic test_single_thread_state_path();
        @(negedge clk);
        single_update_req = '0;
        single_update_req.black_feature = 1;
        single_update_req.apply = 1'b1;
        single_update_req.add = 1'b1;
        single_update_req.clear = 1'b1;
        single_update_valid = 1'b1;
        @(negedge clk);
        single_update_valid = 1'b0;
        wait (single_update_idle);
        @(negedge clk);
        single_eval_valid = 1'b1;
        @(negedge clk);
        single_eval_valid = 1'b0;
        wait (single_result_valid);
        check(single_result == EvalScore'(256),
            "single-thread evaluation reuses the update-state mirror");
    endtask

    // Exhaust the small exact arithmetic domain but report it as one behavioral
    // property rather than 64 nominal test cases.
    task automatic test_output_products();
        automatic bit product_exact = 1'b1;

        for (int activation = 0; activation <= 7; activation++) begin
            for (int weight = -4; weight <= 3; weight++) begin
                automatic logic signed [3:0] activation_bits = activation;
                automatic logic signed [NNUE_OUTPUT_WEIGHT_BITS-1:0] weight_bits = weight;
                product_exact &= $signed(dut.output_product(
                    activation_bits, weight_bits)) == activation * weight;
            end
        end
        check(product_exact, "output product is exact over its reachable domain");
    endtask

    initial begin
        clear = 0;
        update_valid = 0;
        update_req = '0;
        eval_valid = 0;
        eval_thread_id = 0;
        eval_turn = WHITE;
        eval_piece_count = PieceCount'(2);
        single_update_valid = 0;
        single_update_req = '0;
        single_eval_valid = 0;
        #1;
        dut.feature_rom[0] = {NNUE_ROW_BYTES{8'h55}};
        dut.feature_rom[1] = '0;
        for (int row = 0; row < NNUE_OUTPUT_WEIGHT_ROW_COUNT; row++)
            dut.output_weight_rows[row] = {NNUE_OUTPUT_MAC_LANES{3'h1}};
        for (int bucket = 0; bucket < NNUE_OUTPUT_BUCKET_COUNT; bucket++)
            dut.output_bias[bucket] = 0;
        for (int lane = 0; lane < NNUE_ACCUMULATOR_COUNT; lane++)
            dut.accumulator_bias[lane] = 0;
        single_dut.feature_rom[0] = {NNUE_ROW_BYTES{8'h55}};
        single_dut.feature_rom[1] = '0;
        for (int row = 0; row < NNUE_OUTPUT_WEIGHT_ROW_COUNT; row++)
            single_dut.output_weight_rows[row] = {NNUE_OUTPUT_MAC_LANES{3'h1}};
        for (int bucket = 0; bucket < NNUE_OUTPUT_BUCKET_COUNT; bucket++)
            single_dut.output_bias[bucket] = 0;
        for (int lane = 0; lane < NNUE_ACCUMULATOR_COUNT; lane++)
            single_dut.accumulator_bias[lane] = 0;

        repeat (2) @(negedge clk);
        rst_n = 1;
        check(NNUE_FEATURE_COUNT == 768,
            "NNUE transformer uses 2 sides x 6 pieces x 64 squares");
        check(NNUE_ACCUMULATOR_COUNT == 256,
            "NNUE keeps 256 accumulators per perspective");
        check(nnue_output_bucket(PieceCount'(1)) == NnueOutputBucket'(0)
                && nnue_output_bucket(PieceCount'(2)) == NnueOutputBucket'(0)
                && nnue_output_bucket(PieceCount'(5)) == NnueOutputBucket'(0)
                && nnue_output_bucket(PieceCount'(6)) == NnueOutputBucket'(1)
                && nnue_output_bucket(PieceCount'(29)) == NnueOutputBucket'(6)
                && nnue_output_bucket(PieceCount'(30)) == NnueOutputBucket'(7)
                && nnue_output_bucket(PieceCount'(32)) == NnueOutputBucket'(7),
            "piece counts map from the legal minimum through the full-board bucket");
        check(nnue_feature_index(
            Position'(8), WHITE_PAWN, WHITE) == NnueFeatureIndex'(8),
            "white pawn maps to its direct friendly feature");
        check(nnue_feature_index(
            Position'(8), WHITE_PAWN, BLACK) == NnueFeatureIndex'(432),
            "white pawn maps to the black perspective enemy feature");
        check(nnue_feature_index(
            Position'(4), WHITE_KING, BLACK) == NnueFeatureIndex'(764),
            "friendly kings are direct input features for the other perspective");
        check(dut.state_address(ThreadID'(8)) == 8,
            "one accumulator state is addressed by thread, not ply");
        check(dut.STATE_COUNT == 9,
            "accumulator memory allocates one logical word per thread");

        test_output_products();
        test_single_thread_state_path();

        update_req.thread_id = ThreadID'(8);
        update_req.ply = PlyIndex'(2);
        update_req.white_feature = 0;
        update_req.black_feature = 1;
        update_req.apply = 1;
        update_req.add = 1;
        update_req.clear = 1;
        enqueue(update_req);
        wait (update_idle);
        eval_thread_id = ThreadID'(8);
        evaluate(EvalScore'(256), "state memory supports thread IDs above seven");
        dut.output_weight_rows[0] = {NNUE_OUTPUT_MAC_LANES{3'h1}};
        dut.output_weight_rows[1] = {NNUE_OUTPUT_MAC_LANES{3'h1}};
        dut.output_weight_rows[2] = {NNUE_OUTPUT_MAC_LANES{3'h7}};
        dut.output_weight_rows[3] = {NNUE_OUTPUT_MAC_LANES{3'h7}};
        evaluate(EvalScore'(256), "side to move selects the first concatenated perspective");
        eval_turn = BLACK;
        evaluate(EvalScore'(-256), "opponent perspective moves to the second half");
        eval_turn = WHITE;
        dut.output_bias[0] = 8'h17;
        evaluate(EvalScore'(247), "signed output bias is added once");
        dut.output_bias[0] = 0;
        for (int row = NNUE_OUTPUT_MAC_CYCLES;
                row < 2 * NNUE_OUTPUT_MAC_CYCLES; row++)
            dut.output_weight_rows[row] = {NNUE_OUTPUT_MAC_LANES{3'h2}};
        eval_piece_count = PieceCount'(6);
        evaluate(EvalScore'(512), "piece count selects an independent output bucket");
        eval_piece_count = PieceCount'(2);
        for (int row = 0; row < NNUE_OUTPUT_MAC_CYCLES; row++)
            dut.output_weight_rows[row] = {NNUE_OUTPUT_MAC_LANES{3'h1}};

        // A tagged child completion identifies the request that just committed.
        update_req = '0;
        update_req.thread_id = ThreadID'(8);
        update_req.ply = PlyIndex'(1);
        update_req.white_feature = 0;
        update_req.black_feature = 1;
        update_req.apply = 1;
        update_req.add = 1;
        update_req.clear = 1;
        update_req.complete = 1;
        fork
            begin
                wait (update_done_valid);
                check(update_done_thread == ThreadID'(8) && update_done_ply == PlyIndex'(1),
                    "tagged completion identifies the finished child state");
            end
            begin
                enqueue(update_req);
                update_req.complete = 0;
                update_req.thread_id = ThreadID'(0);
                update_req.ply = PlyIndex'(2);
                repeat (3)
                    enqueue(update_req);
            end
        join
        wait (update_idle);

        update_req.thread_id = ThreadID'(0);
        update_req.ply = PlyIndex'(0);
        eval_thread_id = ThreadID'(0);
        update_req.white_feature = 0;
        update_req.black_feature = 1;
        update_req.apply = 1;
        update_req.add = 1;
        update_req.clear = 1;
        enqueue(update_req);
        wait (update_idle);
        evaluate(EvalScore'(256), "perspective activations feed the output layer");
        check(eval_ready, "evaluator becomes ready after its MAC and clipping cycles");

        update_req = '0;
        update_req.ply = PlyIndex'(1);
        update_req.white_feature = 0;
        update_req.black_feature = 1;
        update_req.apply = 1;
        update_req.add = 0;
        enqueue(update_req);
        wait (update_idle);
        evaluate(EvalScore'(0), "a feature delta forwards updated state");

        // A normal child updates its thread's live state without a copy request.
        update_req = '0;
        update_req.thread_id = ThreadID'(1);
        update_req.ply = PlyIndex'(0);
        update_req.white_feature = 0;
        update_req.black_feature = 1;
        update_req.apply = 1;
        update_req.add = 1;
        update_req.clear = 1;
        enqueue(update_req);
        update_req = '0;
        update_req.thread_id = ThreadID'(1);
        update_req.ply = PlyIndex'(1);
        update_req.white_feature = 0;
        update_req.black_feature = 1;
        update_req.apply = 1;
        update_req.add = 0;
        enqueue(update_req);
        wait (update_idle);
        eval_thread_id = ThreadID'(1);
        evaluate(EvalScore'(0),
            "first delta reads the live parent without a standalone copy request");

        // The mirrored state store must support an evaluation read while a
        // different thread commits its next accumulator update.
        update_req = '0;
        update_req.thread_id = ThreadID'(3);
        update_req.ply = PlyIndex'(0);
        update_req.white_feature = 0;
        update_req.black_feature = 1;
        update_req.apply = 1;
        update_req.add = 1;
        update_req.clear = 1;
        enqueue(update_req);
        wait (update_idle);
        update_req.thread_id = ThreadID'(4);
        enqueue(update_req);
        wait (update_idle);
        update_req.clear = 0;
        enqueue(update_req);
        eval_thread_id = ThreadID'(3);
        eval_valid = 1;
        @(negedge clk);
        eval_valid = 0;
        wait (result_valid);
        check(result == EvalScore'(256),
            "evaluation overlaps another thread's accumulator commit");
        wait (update_idle);
        eval_thread_id = ThreadID'(4);
        evaluate(EvalScore'(512),
            "overlapped update is visible in its destination thread");

        // Consecutive requests for one thread must observe each preceding
        // distributed-memory commit without an issue bubble.
        update_req = '0;
        update_req.thread_id = ThreadID'(2);
        update_req.ply = PlyIndex'(1);
        update_req.white_feature = 0;
        update_req.black_feature = 1;
        update_req.apply = 1;
        update_req.add = 1;
        update_req.clear = 1;
        @(negedge clk);
        update_valid = 1;
        @(negedge clk);
        update_req.clear = 0;
        @(negedge clk);
        update_req.complete = 1;
        @(negedge clk);
        update_valid = 0;
        update_req.complete = 0;
        wait (update_done_valid);
        wait (update_idle);
        eval_thread_id = ThreadID'(2);
        evaluate(EvalScore'(768),
            "full-width update pipeline commits back-to-back same-thread rows");

        for (int lane = 0; lane < NNUE_ACCUMULATOR_COUNT; lane++)
            dut.accumulator_bias[lane] = 3'd3;
        eval_thread_id = ThreadID'(0);
        update_req = '0;
        update_req.ply = PlyIndex'(2);
        update_req.white_feature = 0;
        update_req.black_feature = 1;
        update_req.apply = 1;
        update_req.add = 1;
        update_req.clear = 1;
        enqueue(update_req);
        update_req.clear = 0;
        repeat (11) enqueue(update_req);
        wait (update_idle);
        check($signed(dut.accumulator_update_memory[0][0 +: NNUE_ACCUMULATOR_BITS])
                == NnueAccumulator'(15),
            "five-bit accumulators retain the trained positive range");
        evaluate(EvalScore'(2560), "concatenated perspective activations reach the output");
        update_req.add = 0;
        repeat (12)
            enqueue(update_req);
        wait (update_idle);
        check($signed(dut.accumulator_update_memory[0][0 +: NNUE_ACCUMULATOR_BITS])
                == NnueAccumulator'(3),
            "modular inverse deltas exactly restore the accumulator bias");
        evaluate(EvalScore'(1536), "both biased perspectives remain in the concatenated output");

        // Flush an accepted evaluation and queued update together, then prove
        // that no result or update survives and a fresh rebuild still works.
        @(negedge clk);
        update_req = '0;
        update_req.thread_id = ThreadID'(8);
        update_req.ply = PlyIndex'(2);
        update_req.white_feature = 0;
        update_req.black_feature = 1;
        update_req.apply = 1;
        update_req.add = 1;
        update_valid = 1;
        eval_thread_id = ThreadID'(0);
        eval_valid = 1;
        @(negedge clk);
        update_valid = 0;
        eval_valid = 0;
        clear = 1;
        @(negedge clk);
        clear = 0;
        check(update_idle && eval_ready, "clear retires queued update and evaluation work");
        begin
            automatic bit stale_result_seen = 1'b0;
            repeat (7) begin
                @(negedge clk);
                stale_result_seen |= result_valid;
            end
            check(!stale_result_seen, "clear suppresses stale evaluation results");
        end
        for (int lane = 0; lane < NNUE_ACCUMULATOR_COUNT; lane++)
            dut.accumulator_bias[lane] = 0;
        update_req.clear = 1;
        enqueue(update_req);
        wait (update_idle);
        eval_thread_id = ThreadID'(8);
        evaluate(EvalScore'(256), "evaluation restarts correctly after clear");

        // Exercise the signed activation product extrema; an unsigned
        // multiply produces a non-clipped value with this model.
        dut.feature_rom[0] = {NNUE_ROW_BYTES{8'h55}};
        for (int lane = 0; lane < NNUE_ACCUMULATOR_COUNT; lane++)
            dut.accumulator_bias[lane] = 3'd3;
        for (int row = 0; row < NNUE_OUTPUT_MAC_CYCLES; row++)
            dut.output_weight_rows[row] = {NNUE_OUTPUT_MAC_LANES{3'h4}};
        update_req.ply = PlyIndex'(1);
        update_req.black_feature = 0;
        update_req.add = 1;
        update_req.clear = 1;
        enqueue(update_req);
        update_req.clear = 0;
        repeat (11)
            enqueue(update_req);
        wait (update_idle);
        evaluate(EvalScore'(-14336), "signed activation products retain their full width");
        dut.output_bias[0] = 8'h10;
        evaluate(EvalScore'(-14352), "minimum MAC sum and output bias retain their full width");
        dut.output_bias[0] = 0;

        begin
            automatic time first_issue, second_issue;
            automatic int stream_results = 0;

            @(negedge clk);
            first_issue = $time;
            eval_valid = 1;
            @(negedge clk);
            eval_valid = 0;
            while (!eval_ready)
                @(negedge clk);
            second_issue = $time;
            eval_valid = 1;
            @(negedge clk);
            eval_valid = 0;
            check(second_issue - first_issue
                    == (NNUE_OUTPUT_MAC_CYCLES + 1) * 10ns,
                "evaluation initiation interval includes the partial-sum register");
            while (stream_results != 2) begin
                @(negedge clk);
                if (result_valid) begin
                    check(result == EvalScore'(-14336),
                        "pipelined evaluation preserves result ordering");
                    stream_results++;
                end
            end
        end

        $display("Pass Count: %0d", pass_count);
        $display("Fail Count: %0d", fail_count);
        if (fail_count != 0)
            $fatal(1, "NNUE evaluator testbench failed");
        $finish;
    end

    initial begin
        #1_000_000;
        $fatal(1, "NNUE evaluator testbench timed out (pass=%0d fail=%0d)",
            pass_count, fail_count);
    end
endmodule
