// Result selection for cancellation and search budgets.
// Included in search_controller scope.

    // A stopped first iteration may return any resolved legal move. Later
    // iterations may publish only exact root candidates; losing-mate bounds and
    // weakened completed mates roll back to the preceding iteration.
    function automatic logic partial_root_result_eligible(
        input SearchDepth completed_depth,
        input EvalScore completed_score,
        input logic has_completed_move,
        input logic best_exact,
        input Move best_move,
        input EvalScore best_score
    );
        if (!has_completed_move || is_null_move(best_move))
            return 1'b0;
        if (completed_depth == SearchDepth'(0))
            return 1'b1;
        if (!best_exact || best_score <= -MATE_THRESHOLD)
            return 1'b0;
        if (completed_score >= MATE_THRESHOLD)
            return best_score >= completed_score;
        if (completed_score <= -MATE_THRESHOLD)
            return best_score >= MATE_THRESHOLD;
        return 1'b1;
    endfunction : partial_root_result_eligible

    // Classify active operations before snapshotting a canceled search result.
    function automatic logic is_search_operation(input EngineControllerOp operation);
        return operation == ENGINE_CTRL_SEARCH_DEPTH
            || operation == ENGINE_CTRL_SEARCH_FIXED_TIME
            || operation == ENGINE_CTRL_SEARCH_ON_CLOCK
            || operation == ENGINE_CTRL_SEARCH_NODES;
    endfunction : is_search_operation

    // Prefer a completed pass, then an eligible resolved partial root candidate.
    // Time stops use a legal fallback if no pass finished; kills may use partial scores.
    function automatic EngineControllerResponse stopped_search_response(
        input logic search_active,
        input logic allow_partial,
        input logic [7:0] end_reason
    );
        automatic EngineControllerResponse result = EngineControllerResponse'('0);
        automatic SearchDepth completed_depth = search_completed_depth;
        automatic logic aspiration_failed = search_thread_aspiration_active[0]
            && (search_thread_iteration_score[0] <= search_thread_root_alpha[0]
                || search_thread_iteration_score[0] >= search_thread_root_beta[0]);

        result.best_move = NULL_MOVE;
        result.ponder_move = NULL_MOVE;
        result.end_reason = end_reason;
        if (search_active) begin
            if (completed_depth != SearchDepth'(0)) begin
                result.best_move = search_completed_best_move;
                result.ponder_move = search_completed_ponder_move;
                result.score = search_completed_score;
            end
            // A pass completed on the stop boundary is valid if aspiration succeeded.
            if (search_thread_phase[0] == SEARCH_PHASE_DONE && !aspiration_failed) begin
                result.best_move = search_thread_iteration_best_move[0];
                result.ponder_move = search_thread_iteration_ponder_move[0];
                result.score = search_thread_iteration_score[0];
                completed_depth = search_thread_target_depth[0];
            end
            if (allow_partial && search_thread_phase[0] != SEARCH_PHASE_DONE
                    && partial_root_result_eligible(
                        completed_depth, search_completed_score,
                        search_root_has_completed_move[0], search_root_best_exact[0],
                        search_best_move[0], search_root_best_score[0])) begin
                result.best_move = search_best_move[0];
                result.ponder_move = search_ponder_move[0];
                result.score = search_root_best_score[0];
            end
            // A legality-only fallback has no searched score or ponder reply.
            if (end_reason == ENGINE_END_TIME_LIMIT
                    && completed_depth == SearchDepth'(0)
                    && is_null_move(result.best_move))
                result.best_move = search_root_fallback_move;
            result.nodes_count = search_nodes;
            result.completed_depth = 8'(completed_depth);
        end
        return result;
    endfunction : stopped_search_response
