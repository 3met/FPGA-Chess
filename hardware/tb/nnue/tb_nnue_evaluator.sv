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
    EvalScore result;
    int pass_count = 0;
    int fail_count = 0;

    always #5 clk = ~clk;

    nnue_evaluator #(.STATE_THREAD_COUNT(9)) dut (
        .clk, .rst_n, .clear, .update_valid, .update_ready, .update_idle, .update_req,
        .update_done_valid, .update_done_thread, .update_done_ply,
        .eval_valid, .eval_ready, .eval_thread_id,
        .result_valid, .result
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

    initial begin
        clear = 0;
        update_valid = 0;
        update_req = '0;
        eval_valid = 0;
        eval_thread_id = 0;
        #1;
        dut.feature_rom[0] = {NNUE_ROW_BYTES{8'h55}};
        for (int row = 0; row < NNUE_OUTPUT_MAC_CYCLES; row++)
            dut.output_weight_rows[row] = {NNUE_OUTPUT_MAC_LANES{4'h1}};
        for (int lane = 0; lane < NNUE_ACCUMULATOR_COUNT; lane++)
            dut.accumulator_bias[lane] = 0;

        repeat (2) @(negedge clk);
        rst_n = 1;
        check(NNUE_FEATURE_COUNT == 768,
            "NNUE transformer uses 2 sides x 6 pieces x 64 squares");
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

        // Both portable implementations must cover the complete reachable
        // activation and signed-int4 domains exactly.
        for (int activation = -31; activation <= 31; activation++) begin
            for (int weight = -8; weight <= 7; weight++) begin
                automatic logic signed [5:0] activation_bits = activation;
                automatic logic signed [3:0] weight_bits = weight;
                check($signed(dut.soft_output_product(
                            activation_bits, weight_bits)) == activation * weight,
                    "soft output product is exact");
                check($signed(dut.hard_output_product(
                            activation_bits, weight_bits)) == activation * weight,
                    "hard output product is exact");
            end
        end

        update_req.thread_id = ThreadID'(8);
        update_req.ply = PlyIndex'(2);
        update_req.white_feature = 0;
        update_req.black_feature = 0;
        update_req.white_enable = 1;
        update_req.black_enable = 0;
        update_req.add = 1;
        update_req.clear = 1;
        enqueue(update_req);
        wait (update_idle);
        eval_thread_id = ThreadID'(8);
        evaluate(EvalScore'(256), "state memory supports thread IDs above seven");

        // A tagged child completion identifies the request that just committed.
        update_req = '0;
        update_req.thread_id = ThreadID'(8);
        update_req.ply = PlyIndex'(1);
        update_req.white_feature = 0;
        update_req.black_feature = 0;
        update_req.white_enable = 1;
        update_req.black_enable = 1;
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
        update_req.black_feature = 0;
        update_req.white_enable = 1;
        update_req.black_enable = 0;
        update_req.add = 1;
        update_req.clear = 1;
        enqueue(update_req);
        wait (update_idle);
        evaluate(EvalScore'(256), "perspective differences feed the output layer");
        check(eval_ready, "evaluator becomes ready after its MAC and clipping cycles");

        update_req = '0;
        update_req.ply = PlyIndex'(1);
        update_req.white_feature = 0;
        update_req.black_feature = 0;
        update_req.white_enable = 1;
        update_req.black_enable = 0;
        update_req.add = 0;
        enqueue(update_req);
        wait (update_idle);
        evaluate(EvalScore'(0), "a feature delta forwards updated state");
        evaluate(EvalScore'(0), "single thread state follows the child delta");

        // A normal child updates its thread's live state without a copy request.
        update_req = '0;
        update_req.thread_id = ThreadID'(1);
        update_req.ply = PlyIndex'(0);
        update_req.white_feature = 0;
        update_req.black_feature = 0;
        update_req.white_enable = 1;
        update_req.black_enable = 0;
        update_req.add = 1;
        update_req.clear = 1;
        enqueue(update_req);
        update_req = '0;
        update_req.thread_id = ThreadID'(1);
        update_req.ply = PlyIndex'(1);
        update_req.white_feature = 0;
        update_req.black_feature = 0;
        update_req.white_enable = 1;
        update_req.black_enable = 0;
        update_req.add = 0;
        enqueue(update_req);
        wait (update_idle);
        eval_thread_id = ThreadID'(1);
        evaluate(EvalScore'(0),
            "first delta reads the live parent without a standalone copy request");
        evaluate(EvalScore'(0), "the ply tag does not duplicate live thread state");

        // The mirrored state store must support an evaluation read while a
        // different thread commits its next accumulator update.
        update_req = '0;
        update_req.thread_id = ThreadID'(3);
        update_req.ply = PlyIndex'(0);
        update_req.white_feature = 0;
        update_req.black_feature = 0;
        update_req.white_enable = 1;
        update_req.black_enable = 0;
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
        update_req.black_feature = 0;
        update_req.white_enable = 1;
        update_req.black_enable = 0;
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
        update_req.black_feature = 0;
        update_req.white_enable = 1;
        update_req.black_enable = 0;
        update_req.add = 1;
        update_req.clear = 1;
        enqueue(update_req);
        update_req.clear = 0;
        for (int feature = 1; feature < 28; feature++)
            enqueue(update_req);
        wait (update_idle);
        check($signed(dut.accumulator_update_memory[0][0 +: NNUE_ACCUMULATOR_BITS])
                == NnueAccumulator'(31),
            "six-bit accumulators retain the trained positive range");
        evaluate(EvalScore'(7168), "perspective activation difference reaches 28");
        update_req.add = 0;
        repeat (28)
            enqueue(update_req);
        wait (update_idle);
        check($signed(dut.accumulator_update_memory[0][0 +: NNUE_ACCUMULATOR_BITS])
                == NnueAccumulator'(3),
            "modular inverse deltas exactly restore the accumulator bias");

        // Flush an accepted evaluation and queued update together, then prove
        // that no result or update survives and a fresh rebuild still works.
        @(negedge clk);
        update_req = '0;
        update_req.thread_id = ThreadID'(8);
        update_req.ply = PlyIndex'(2);
        update_req.white_feature = 0;
        update_req.black_feature = 0;
        update_req.white_enable = 1;
        update_req.black_enable = 0;
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
        repeat (7) begin
            @(negedge clk);
            check(!result_valid, "clear suppresses stale evaluation results");
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
            dut.output_weight_rows[row] = {NNUE_OUTPUT_MAC_LANES{4'h8}};
        update_req.ply = PlyIndex'(1);
        update_req.add = 1;
        update_req.clear = 1;
        enqueue(update_req);
        update_req.clear = 0;
        repeat (27)
            enqueue(update_req);
        wait (update_idle);
        evaluate(EvalScore'(-30999), "signed activation products retain their full width");

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
                    check(result == EvalScore'(-30999),
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
endmodule
