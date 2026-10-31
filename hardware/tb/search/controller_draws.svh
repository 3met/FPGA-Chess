// Root searches must select real moves while descendant draws retain their history.
// Included in tb_search_controller scope.

    // A completed root result must contain a searched move rather than a terminal shortcut.
    task automatic run_draw_root_search(input string label, input logic [7:0] depth = 8'd2);
        automatic Move best_move;
        automatic EvalScore score;
        automatic NodeCountType nodes;
        run_search_depth_record(depth, label, best_move, score, nodes);
        $display("Root draw regression %s: score=%0d depth=%0d move=%0d-%0d nodes=%0d",
            label, score, resp.completed_depth, best_move.from_pos, best_move.to_pos, nodes);
        check(!is_null_move(best_move), {label, " selects a root move"});
        check(nodes != NodeCountType'(0), {label, " searches legal children"});
    endtask : run_draw_root_search

    // Move the kings through a reversible cycle without changing the capture opportunity.
    task automatic repeat_capture_root(input string label);
        apply_game_move(make_move(Position'(4), Position'(5), PROMO_QUEEN), {label, " e1f1"});
        apply_game_move(make_move(Position'(60), Position'(61), PROMO_QUEEN), {label, " e8f8"});
        apply_game_move(make_move(Position'(5), Position'(4), PROMO_QUEEN), {label, " f1e1"});
        apply_game_move(make_move(Position'(61), Position'(60), PROMO_QUEEN), {label, " f8e8"});
    endtask : repeat_capture_root

    // Position replacement keeps TT contents while changing the reversible clock context.
    task automatic run_draw_clock_tt_reuse();
        automatic Move best_move;
        automatic EvalScore warm_score, cold_score;
        automatic NodeCountType nodes;
        automatic int stores_before;

        new_game();
        setup_kings_only();
        set_tile(WHITE_ROOK, Position'(0), "expired-clock cache seed rook a1");
        set_halfmove_clock(HalfmoveClock'(100), "expired-clock cache seed");
        stores_before = tt_store_count;
        run_draw_root_search("expired-clock root does not cache a draw");
        check(resp.score == DRAW_EVAL_SCORE, "all seed continuations reach the draw threshold");
        check(tt_store_count == stores_before, "expired-clock search does not publish reusable draw scores");

        // Black d8e8 reaches the seed key with clock one at non-root ply.
        set_tile(EMPTY_TILE, Position'(60), "move cache regression king off e8");
        set_tile(BLACK_KING, Position'(59), "cache regression black king d8");
        set_turn(BLACK, "cache regression black to move");
        set_halfmove_clock(HalfmoveClock'(0), "cache regression resets the analysis clock");
        run_search_depth_record(8'd3, "low-clock search after expired-clock root", best_move, warm_score, nodes);
        check(!is_null_move(best_move) && nodes != NodeCountType'(0), "warm low-clock root searches a legal move");
        check(warm_score < DRAW_EVAL_SCORE, "low-clock descendant cannot inherit an expired-clock draw");
        check(tt_store_count > stores_before, "ordinary low-clock searches still publish TT results");

        new_game();
        setup_kings_only();
        set_tile(WHITE_ROOK, Position'(0), "cold-cache regression rook a1");
        set_tile(EMPTY_TILE, Position'(60), "move cold-cache regression king off e8");
        set_tile(BLACK_KING, Position'(59), "cold-cache regression black king d8");
        set_turn(BLACK, "cold-cache regression black to move");
        run_search_depth_record(8'd3, "low-clock search with a fresh cache", best_move, cold_score, nodes);
        check(warm_score == cold_score,
            $sformatf("clock-context reuse matches a fresh TT: warm=%0d cold=%0d", warm_score, cold_score));
    endtask : run_draw_clock_tt_reuse

    // Keep repetition, clock resets, terminal positions, and early stops in the same integration fixture.
    task automatic run_root_draw_regressions();
        run_draw_clock_tt_reuse();
        new_game();
        repeat_knight_shuffle_once("first repetition cycle");
        repeat_knight_shuffle_once("second repetition cycle");
        repetition_root_request_seen = 1'b0;
        repetition_child_draw_seen = 1'b0;
        run_draw_root_search("threefold root searches legal moves");
        check(repetition_root_request_seen, "threefold root still probes its history");
        check(repetition_child_draw_seen, "descendant repetition retains pre-root history");
        run_fixed_time_search("repeated root with exhausted fixed-time budget");
        run_clock_budget_search("repeated root with exhausted clock budget");

        new_game();
        setup_rook_takes_queen();
        repeat_capture_root("capture root first cycle");
        repeat_capture_root("capture root second cycle");
        for (int attempt = 0; attempt < 2; attempt++) begin
            run_draw_root_search("repeated root with winning alternative");
            check(resp.best_move.from_pos == Position'(0) && resp.best_move.to_pos == Position'(56)
                    && resp.score > DRAW_EVAL_SCORE,
                "repeated root searches the winning capture with cold and warm TT");
        end

        // With no pawn moves or captures, every child still reaches the draw threshold.
        new_game();
        setup_kings_only();
        run_draw_root_search("depth-zero root selects a quiet move", 8'd0);
        set_halfmove_clock(HalfmoveClock'(100), "fifty-move root");
        run_draw_root_search("fifty-move root with quiet choices");
        check(resp.score == DRAW_EVAL_SCORE && resp.best_move.from_pos == Position'(4)
                && (resp.best_move.to_pos == Position'(3) || resp.best_move.to_pos == Position'(5)
                    || resp.best_move.to_pos == Position'(11) || resp.best_move.to_pos == Position'(12)
                    || resp.best_move.to_pos == Position'(13)),
            "quiet drawn root returns a legal king move and draw score");
        set_halfmove_clock(HalfmoveClock'('1), "maximum halfmove clock");
        run_draw_root_search("maximum halfmove root");
        check(resp.score == DRAW_EVAL_SCORE, "quiet child cannot wrap the clock and escape the draw");
        run_draw_root_search("depth-zero drawn root selects a quiet move", 8'd0);
        check(dut.active_board.halfmove_clock == HalfmoveClock'('1), "search preserves the active draw clock");
        run_fixed_time_search("fifty-move root with exhausted fixed-time budget");
        run_clock_budget_search("fifty-move root with exhausted clock budget");

        new_game();
        setup_qsearch_quiet_evasion_position();
        set_halfmove_clock(HalfmoveClock'(100), "checked root at draw threshold");
        run_draw_root_search("checked root searches quiet evasions");
        check(resp.score == DRAW_EVAL_SCORE && resp.best_move.from_pos == Position'(63)
                && (resp.best_move.to_pos == Position'(54) || resp.best_move.to_pos == Position'(62)),
            "checked drawn root returns a legal evasion");

        new_game();
        clear_start_position("root with only a capturing evasion");
        set_tile(WHITE_KING, Position'(53), "white king f7");
        set_tile(WHITE_ROOK, Position'(55), "white rook h7");
        set_tile(BLACK_KING, Position'(63), "black king h8");
        set_turn(BLACK, "black to move");
        set_halfmove_clock(HalfmoveClock'(100), "capture evasion draw threshold");
        run_draw_root_search("capturing root evasion resets the clock");
        check(resp.best_move.from_pos == Position'(63) && resp.best_move.to_pos == Position'(55),
            "root returns its only legal capturing evasion");

        new_game();
        setup_rook_takes_queen();
        set_halfmove_clock(HalfmoveClock'(100), "capture root at draw threshold");
        run_draw_root_search("root capture resets draw clock");
        check(resp.best_move.from_pos == Position'(0) && resp.best_move.to_pos == Position'(56)
                && resp.score > DRAW_EVAL_SCORE, "capture can win beyond the root draw threshold");

        new_game();
        clear_start_position("pawn root at draw threshold");
        set_tile(WHITE_KING, Position'(53), "white king f7");
        set_tile(WHITE_PAWN, Position'(54), "white pawn g7");
        set_tile(BLACK_KING, Position'(55), "black king h7");
        set_halfmove_clock(HalfmoveClock'(100), "pawn root draw clock");
        run_draw_root_search("root pawn move resets draw clock");
        check(resp.best_move.from_pos == Position'(54) && resp.best_move.to_pos == Position'(62)
                && resp.score > DRAW_EVAL_SCORE, "promotion is searched beyond the draw threshold");

        new_game();
        clear_start_position("quiet mate from drawn root");
        set_tile(WHITE_KING, Position'(45), "white king f6");
        set_tile(WHITE_QUEEN, Position'(46), "white queen g6");
        set_tile(BLACK_KING, Position'(63), "black king h8");
        set_halfmove_clock(HalfmoveClock'('1), "quiet mate with saturated clock");
        run_draw_root_search("root quiet mate precedes child draw");
        check(resp.best_move.from_pos == Position'(46) && resp.best_move.to_pos == Position'(54)
                && resp.score == MATE_SCORE, "quiet Qg7 mate wins despite the child draw clock");

        new_game();
        setup_checkmate_position();
        set_halfmove_clock(HalfmoveClock'(100), "checkmate at draw threshold");
        run_checkmate_search("checkmate precedes fifty-move draw");
        run_qsearch_checkmate_test("qsearch mate precedes fifty-move draw");
        new_game();
        setup_stalemate_position();
        set_halfmove_clock(HalfmoveClock'(100), "stalemate at draw threshold");
        run_stalemate_search("stalemate at fifty-move threshold");
    endtask : run_root_draw_regressions
