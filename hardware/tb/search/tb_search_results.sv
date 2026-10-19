`timescale 1ns/1ps

import chess_defs::*;
import engine_defs::*;
import search_defs::*;
import tt_defs::*;

module tb_search_results;
    // Supply only the primary-thread snapshot fields read by the production helper.
    typedef PlyIndex SearchDepth;
    SearchDepth search_completed_depth, search_thread_target_depth[1];
    Move search_completed_best_move, search_completed_ponder_move;
    EvalScore search_completed_score;
    NodeCountType search_nodes;
    SearchThreadPhase search_thread_phase[1];
    logic search_thread_aspiration_active[1];
    EvalScore search_thread_iteration_score[1], search_thread_root_alpha[1], search_thread_root_beta[1];
    Move search_thread_iteration_best_move[1], search_thread_iteration_ponder_move[1];
    logic search_root_has_completed_move[1], search_root_best_exact[1];
    Move search_best_move[1], search_ponder_move[1];
    Move search_root_fallback_move;
    EvalScore search_root_best_score[1];
    EngineControllerResponse completed, iteration, partial, empty;
    int pass_count = 0, fail_count = 0;

    // A null move is identified by its squares; promotion bits may be don't-cares.
    function automatic logic is_null_move(input Move move);
        return move.from_pos == Position'(0) && move.to_pos == Position'(0);
    endfunction

    // Compile the actual selector without the controller's unrelated search pipelines.
    `include "hardware/rtl/search/search_results.svh"

    // Use ordinary opening moves as distinct completed, iteration, and partial fixtures.
    function automatic Move make_move(input Position from_pos, input Position to_pos, input PromoType promo);
        return Move'({from_pos, to_pos, promo});
    endfunction

    // Each case reports one result for its entire response, including depth and tags.
    task automatic check(input logic condition, input string label);
        if (condition) pass_count++;
        else begin
            fail_count++;
            $error("[FAIL] %s", label);
        end
    endtask

    task automatic expect_response(
        input logic active, input logic allow_partial, input logic [7:0] reason,
        input EngineControllerResponse expected, input string label
    );
        expected.end_reason = reason;
        check(stopped_search_response(active, allow_partial, reason) === expected, label);
    endtask

    initial begin
        check(partial_root_result_eligible(
                5'd4, EvalScore'(40), 1'b1, 1'b1,
                make_move(Position'(12), Position'(28), PROMO_QUEEN), EvalScore'(60)),
            "partial deeper iteration accepts an exact resolved root candidate");
        check(!partial_root_result_eligible(
                5'd4, EvalScore'(40), 1'b1, 1'b0,
                make_move(Position'(12), Position'(28), PROMO_QUEEN), EvalScore'(60)),
            "partial deeper iteration rejects an aspiration bound");
        check(!partial_root_result_eligible(
                5'd4, EvalScore'(40), 1'b1, 1'b1,
                make_move(Position'(12), Position'(28), PROMO_QUEEN), -MATE_THRESHOLD),
            "partial deeper iteration rejects an aborted losing mate");
        check(!partial_root_result_eligible(
                5'd4, MATE_THRESHOLD + EvalScore'(10), 1'b1, 1'b1,
                make_move(Position'(12), Position'(28), PROMO_QUEEN),
                MATE_THRESHOLD + EvalScore'(5)),
            "partial deeper iteration does not weaken a completed winning mate");
        check(partial_root_result_eligible(
                5'd4, MATE_THRESHOLD + EvalScore'(10), 1'b1, 1'b1,
                make_move(Position'(12), Position'(28), PROMO_QUEEN),
                MATE_THRESHOLD + EvalScore'(20)),
            "partial deeper iteration may improve a completed winning mate");
        check(!partial_root_result_eligible(
                5'd4, -MATE_THRESHOLD, 1'b1, 1'b1,
                make_move(Position'(12), Position'(28), PROMO_QUEEN), EvalScore'(60)),
            "partial deeper iteration retains a completed loss without a proven win");
        check(partial_root_result_eligible(
                5'd0, EvalScore'(0), 1'b1, 1'b0,
                make_move(Position'(12), Position'(28), PROMO_QUEEN), -MATE_THRESHOLD),
            "partial first iteration returns its first fully searched legal move");
        check(!partial_root_result_eligible(
                5'd0, EvalScore'(0), 1'b0, 1'b1,
                make_move(Position'(12), Position'(28), PROMO_QUEEN), EvalScore'(60)),
            "partial first iteration requires a fully searched root child");
        check(!partial_root_result_eligible(
                5'd0, EvalScore'(0), 1'b1, 1'b1, NULL_MOVE, EvalScore'(60)),
            "partial first iteration rejects a null best move");
        completed = EngineControllerResponse'('0);
        completed.best_move = make_move(Position'(12), Position'(28), PROMO_QUEEN);
        completed.ponder_move = make_move(Position'(50), Position'(34), PROMO_QUEEN);
        completed.score = EvalScore'(40);
        completed.completed_depth = 8'd2;
        completed.nodes_count = NodeCountType'(99);
        iteration = completed;
        iteration.best_move = make_move(Position'(11), Position'(27), PROMO_QUEEN);
        iteration.ponder_move = make_move(Position'(57), Position'(42), PROMO_QUEEN);
        iteration.score = EvalScore'(60);
        iteration.completed_depth = completed.completed_depth + 1'b1;
        partial = completed;
        partial.best_move = make_move(Position'(12), Position'(20), PROMO_QUEEN);
        partial.ponder_move = make_move(Position'(51), Position'(35), PROMO_QUEEN);
        partial.score = EvalScore'(50);
        empty = EngineControllerResponse'('0);
        empty.best_move = NULL_MOVE;
        empty.ponder_move = NULL_MOVE;
        empty.nodes_count = completed.nodes_count;

        search_completed_depth = SearchDepth'(completed.completed_depth);
        search_completed_best_move = completed.best_move;
        search_completed_ponder_move = completed.ponder_move;
        search_completed_score = completed.score;
        search_nodes = completed.nodes_count;
        search_thread_phase[0] = SEARCH_PHASE_READY;
        search_thread_aspiration_active[0] = 1'b0;
        search_thread_root_alpha[0] = EvalScore'(50);
        search_thread_root_beta[0] = EvalScore'(70);
        search_thread_target_depth[0] = SearchDepth'(iteration.completed_depth);
        search_thread_iteration_best_move[0] = iteration.best_move;
        search_thread_iteration_ponder_move[0] = iteration.ponder_move;
        search_thread_iteration_score[0] = iteration.score;
        search_root_has_completed_move[0] = 1'b1;
        search_root_best_exact[0] = 1'b1;
        search_root_fallback_move = NULL_MOVE;
        search_best_move[0] = partial.best_move;
        search_ponder_move[0] = partial.ponder_move;
        search_root_best_score[0] = partial.score;

        // The same resolved candidate is publishable for Kill/nodes but not time.
        expect_response(1, 0, ENGINE_END_TIME_LIMIT, completed, "time stop rolls back partial result");
        expect_response(1, 1, ENGINE_END_NODE_LIMIT, partial, "node stop publishes exact partial PV without advancing depth");
        expect_response(1, 1, ENGINE_END_KILLED, partial, "Kill publishes the same resolved partial PV");
        search_thread_phase[0] = SEARCH_PHASE_DONE;
        search_thread_aspiration_active[0] = 1'b1;
        expect_response(1, 0, ENGINE_END_TIME_LIMIT, iteration, "completed pass on stop boundary takes precedence");
        search_thread_iteration_score[0] = search_thread_root_alpha[0];
        expect_response(1, 1, ENGINE_END_KILLED, completed, "failed-low pass retains completed result");
        search_thread_iteration_score[0] = search_thread_root_beta[0];
        expect_response(1, 1, ENGINE_END_NODE_LIMIT, completed, "failed-high pass retains completed result");

        // First-iteration time stops have no result; non-time stops may use a resolved child.
        search_thread_phase[0] = SEARCH_PHASE_READY;
        search_completed_depth = SearchDepth'(0);
        partial.completed_depth = 8'd0;
        expect_response(1, 0, ENGINE_END_TIME_LIMIT, empty, "first-iteration time stop returns empty result");
        expect_response(1, 1, ENGINE_END_NODE_LIMIT, partial, "first-iteration node stop publishes resolved child");
        search_root_has_completed_move[0] = 1'b0;
        expect_response(1, 1, ENGINE_END_KILLED, empty, "unfinished root child cannot become a result");
        search_completed_depth = SearchDepth'(completed.completed_depth);
        search_thread_phase[0] = SEARCH_PHASE_DONE;
        search_thread_iteration_score[0] = iteration.score;
        empty.nodes_count = NodeCountType'(0);
        expect_response(0, 1, ENGINE_END_KILLED, empty, "non-search Kill discards stale search state");

        $display("Pass Count: %0d", pass_count);
        $display("Fail Count: %0d", fail_count);
        if (fail_count != 0) $fatal(1, "search result selection failed");
        $finish;
    end

    // Bound even an untimed fixture in case a future helper unexpectedly blocks.
    initial begin
        #1000;
        $fatal(1, "search result test timed out");
    end
endmodule : tb_search_results
