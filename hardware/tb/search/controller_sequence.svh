// Integration scenario execution and summarized coverage checks.
// Included in tb_search_controller scope.

    initial begin
        reset_dut();
        // Reset alone establishes a playable board and repetition root.
        run_perft(8'd2, NodeCountType'(400), "power-up startpos perft");
        test_response_backpressure();
        if (MATE_ONLY) begin
            new_game();
            setup_fifty_move_mate_position();
            run_fifty_move_mate_search("fifty-move mate cold TT");
            run_fifty_move_mate_search("fifty-move mate warm TT");
            $display("Pass Count: %0d", pass_count);
            $display("Fail Count: %0d", fail_count);
            if (fail_count != 0) $fatal(1, "fifty-move mate regression failed");
            $finish;
        end
        if (EARLY_ONLY) begin
            new_game();
            run_search_depth(8'd2, "early quiet search");
            new_game();
            setup_promotion_perft_position();
            run_search_depth(8'd2, "early noisy promotion search");
            new_game();
            clear_start_position("early noisy captures");
            set_tile(WHITE_KING, Position'(4), "early capture white king e1");
            set_tile(WHITE_ROOK, Position'(0), "early capture white rook a1");
            set_tile(WHITE_BISHOP, Position'(18), "early capture white bishop c3");
            set_tile(BLACK_KING, Position'(60), "early capture black king e8");
            set_tile(BLACK_QUEEN, Position'(27), "early capture black queen d4");
            set_tile(BLACK_ROOK, Position'(8), "early capture black rook a2");
            set_tile(BLACK_ROOK, Position'(63), "early capture black rook h8");
            set_tile(BLACK_QUEEN, Position'(59), "early capture black queen d8");
            set_tile(BLACK_PAWN, Position'(49), "early capture black pawn b7");
            set_tile(BLACK_PAWN, Position'(50), "early capture black pawn c7");
            run_search_depth(8'd1, "early noisy capture search");
            check(early_noisy_reads > 0, "search receives highest noisy bucket before generation completes");
            check(early_quiet_reads > 0, "search receives highest quiet bucket before generation completes");
            check(early_child_preparations > 0, "early candidates begin child preparation during generation");
            check(repaired_parents > 0, "completed generation publishes remaining moves to saved parents");
            check(early_child_search_requests > 0, "child TT lookup or evaluation overlaps parent generation");
            check(!dut.move_overflow_sticky, "early search preserves move-memory bounds");
            new_game();
            kill_early_generation();
            run_search_depth(8'd1, "search restarts after overlapped generation kill");
            $display("Early reads: noisy=%0d quiet=%0d child preparation=%0d saved parents=%0d",
                early_noisy_reads, early_quiet_reads, early_child_preparations, repaired_parents);
            $display("Pass Count: %0d", pass_count);
            $display("Fail Count: %0d", fail_count);
            if (fail_count != 0) $fatal(1, "early search integration failed");
            $finish;
        end

        reset_active_search();
        run_fresh_game_repeatability();

        `include "hardware/tb/search/controller_policy_checks.svh"

        new_game();
        run_perft(8'd0, NodeCountType'(1), "startpos perft depth 0");
        run_perft(8'd1, NodeCountType'(20), "startpos perft depth 1");
        run_perft(8'd2, NodeCountType'(400), "startpos perft depth 2");
        run_search_depth(8'd2, "startpos search depth 2");
        check_search_stats("startpos search statistics");
        check(pvs_scout_seen, "startpos depth 2 used a PVS scout window");
        check(rfp_eval_seen, "startpos depth 2 evaluated an eligible RFP node");
        check(aspiration_window_seen, "startpos depth 2 used an aspiration window");
        kill_search_before_root_init("early search kill");
        kill_and_restart_with_pending_tt();

        // Opposite-direction moves h2h4 and h5h3 must have distinct mask identities.
        new_game();
        apply_game_move(make_move(Position'(12), Position'(20), PROMO_QUEEN), "perft regression e2e3");
        apply_game_move(make_move(Position'(48), Position'(40), PROMO_QUEEN), "perft regression a7a6");
        apply_game_move(make_move(Position'(3), Position'(39), PROMO_QUEEN), "perft regression d1h5");
        apply_game_move(make_move(Position'(40), Position'(32), PROMO_QUEEN), "perft regression a6a5");
        run_perft(8'd1, NodeCountType'(44), "queen sortie perft depth 1");

        // Independent reference perft counts exercise cached check status at
        // the root, on descent to an unchecked child, and after reversal.
        new_game();
        setup_quiet_evasion_perft_position();
        run_perft(8'd1, NodeCountType'(6), "quiet evasion perft depth 1");
        run_perft(8'd2, NodeCountType'(89), "quiet evasion perft depth 2");

        // Independent reference counts preserve special noisy evasions and
        // complete child move sets after leaving the checked root.
        for (int fixture = 0; fixture < 3; fixture++) begin
            new_game();
            setup_noisy_evasion_perft_position(fixture);
            case (fixture)
                0: begin
                    run_perft(8'd1, NodeCountType'(4), "knight capture evasion depth 1");
                    run_perft(8'd2, NodeCountType'(84), "knight capture evasion depth 2");
                end
                1: begin
                    run_perft(8'd1, NodeCountType'(8), "EP capture evasion depth 1");
                    run_perft(8'd2, NodeCountType'(45), "EP capture evasion depth 2");
                end
                2: begin
                    run_perft(8'd1, NodeCountType'(8), "blocking promotion evasion depth 1");
                    run_perft(8'd2, NodeCountType'(106), "blocking promotion evasion depth 2");
                end
            endcase
        end

        new_game();
        setup_kings_only();
        run_perft(8'd1, NodeCountType'(5), "kings-only perft depth 1");
        // Choose enough depth for a weak quiet's reduced child to remain in
        // main search, where TT depth propagation can actually be observed.
        begin
            automatic int parent_depth = dut.LMR_MINIMUM_DEPTH;
            automatic int move_number = dut.LMR_MINIMUM_MOVE_NUMBER;
            automatic int reduction;
            if (move_number < 2) move_number = 2;
            while (parent_depth < SEARCH_STACK_DEPTH - 1) begin
                reduction = int'(dut.lmr_bucket_reduction(
                    dut.lmr_reduction(dut.floor_log2_8(8'(parent_depth)),
                        dut.floor_log2_8(8'(move_number))),
                    8'(parent_depth), move_generator_defs::QUIET_LOW_BUCKET));
                if (reduction > 0 && parent_depth - 1 - reduction > 0) break;
                parent_depth++;
            end
            run_search_depth(8'(parent_depth + 1), "kings-only LMR and TT depth search");
        end
        check(null_push_seen, "LMR scout search issued a null move");
        check(null_reverse_seen, "null child was reversed through board history");
        check(lmr_reduced_issue_seen, "LMR controller reduces an eligible third-or-later move");
        check(lmr_recovery_issue_seen, "LMR alpha-raising scout is issued again at full depth");
        check(lmr_reduced_tt_depth_seen, "LMR reduced child TT request uses reduced depth");
        check(lmr_full_tt_depth_seen, "LMR recovery TT request uses restored full depth");

        new_game();
        setup_pinned_rook_position();
        begin
            automatic Move ignored_move;
            automatic EvalScore ignored_score;
            automatic NodeCountType ignored_nodes;
            run_search_depth_record(8'd1, "pinned-rook illegal-candidate search",
                ignored_move, ignored_score, ignored_nodes);
        end
        // The generator unit test proves the pinned move is emitted. This
        // search completing proves board-update rejection does not stall it.

        new_game();
        setup_castling_perft_position();
        run_perft(8'd1, NodeCountType'(15), "castling perft depth 1");
        run_search_depth(8'd1, "castling NNUE delta search");

        new_game();
        setup_en_passant_perft_position();
        run_perft(8'd1, NodeCountType'(8), "en passant perft depth 1");
        run_search_depth(8'd1, "en passant NNUE delta search");

        new_game();
        setup_promotion_perft_position();
        run_perft(8'd1, NodeCountType'(9), "promotion perft depth 1");
        run_search_depth(8'd1, "promotion NNUE delta search");

        new_game();
        setup_stalemate_position();
        run_perft(8'd1, NodeCountType'(0), "stalemate perft depth 1");
        run_stalemate_search("stalemate search");

        new_game();
        setup_checkmate_position();
        run_perft(8'd1, NodeCountType'(0), "checkmate perft depth 1");
        run_checkmate_search("checkmate search");

        new_game();
        setup_checkmate_position();
        run_qsearch_checkmate_test("qsearch checkmate");

        new_game();
        setup_qsearch_quiet_evasion_position();
        run_qsearch_quiet_evasion_test("qsearch quiet check evasion");

        // Force all quiet evasions into the final phase to guard against false mate.
        new_game();
        setup_qsearch_quiet_evasion_position();
        for (int entry = 0; entry < dut.HISTORY_ENTRY_COUNT; entry++)
            dut.move_generator.quiet_history.history_table.history_ram.mem[entry] = 0;
        run_qsearch_quiet_evasion_test("qsearch low-score quiet check evasion");


        new_game();
        apply_game_move(make_move(Position'(12), Position'(28), PROMO_QUEEN), "make e2e4");
        run_perft(8'd1, NodeCountType'(20), "after e2e4 perft depth 1");

        new_game();
        kill_active_perft("kill active perft");
        new_game();
        kill_active_search("kill active search");
        run_perft_error(8'd32, "oversized perft depth");
        run_search_depth_error(8'd32, "oversized search depth");

        new_game();
        setup_rook_takes_queen();
        run_qsearch_capture_test("qsearch rook takes queen");

        new_game();
        setup_black_rook_takes_queen();
        run_black_qsearch_capture_test("black qsearch rook takes queen");

        new_game();
        setup_rook_takes_queen();
        set_halfmove_clock(HalfmoveClock'(100), "set 50-move draw halfmove clock");
        run_halfmove_draw_search("50-move draw search");

        new_game();
        setup_checkmate_position();
        set_halfmove_clock(HalfmoveClock'(100), "checkmate at fifty-move threshold");
        run_checkmate_search("checkmate precedes fifty-move draw");
        run_qsearch_checkmate_test("qsearch mate precedes fifty-move draw");

        new_game();
        setup_qsearch_quiet_evasion_position();
        set_halfmove_clock(HalfmoveClock'(100), "checked draw threshold");
        run_halfmove_draw_search("checked position with evasion is drawn");

        new_game();
        clear_start_position("checked draw with only a capturing evasion");
        set_tile(WHITE_KING, Position'(53), "white king f7");
        set_tile(WHITE_ROOK, Position'(55), "white rook h7");
        set_tile(BLACK_KING, Position'(63), "black king h8");
        set_turn(BLACK, "black to move");
        set_halfmove_clock(HalfmoveClock'(100), "capture evasion draw threshold");
        run_halfmove_draw_search("capturing evasion still permits a draw claim");

        new_game();
        repeat_knight_shuffle_once("first repetition cycle");
        repeat_knight_shuffle_once("second repetition cycle");
        run_repetition_draw_search("threefold root search");

        run_root_tt_score_policy_test("root TT score policy");
        run_tt_validation_priority_test();
        run_tt_validation_fallback_test(1'b0);
        run_tt_validation_fallback_test(1'b1);
        run_direct_reject_followup_test("direct rejection generation tracking");
        check_underpromotion_publication();

        new_game();
        run_tt_reuse_test("startpos TT reuse");
        run_shallow_tt_move_ordering_test("shallow TT move ordering");

        new_game();
        run_scheduler_lifecycle_test("scheduler lifecycle search");

        new_game();
        run_node_limit_search("node-limited search");
        run_fixed_time_search("zero fixed-time search");
        run_clock_budget_search("zero clock-budget search");

        // Expiry must reject pseudo-legal king moves that remain on the rook's file.
        new_game();
        setup_qsearch_quiet_evasion_position();
        run_fixed_time_search("expired checked root");
        check(resp.best_move.from_pos == Position'(63)
                && (resp.best_move.to_pos == Position'(54) || resp.best_move.to_pos == Position'(62)),
            "expired checked root returns a king-safe evasion");
        run_clock_budget_search("expired checked root on clock");
        check(resp.best_move.from_pos == Position'(63)
                && (resp.best_move.to_pos == Position'(54) || resp.best_move.to_pos == Position'(62)),
            "expired clock root returns a king-safe evasion");

        new_game();
        setup_checkmate_position();
        run_expired_terminal_search("expired checkmate", -MATE_SCORE);
        new_game();
        setup_stalemate_position();
        run_expired_terminal_search("expired stalemate", DRAW_EVAL_SCORE);

        // A synthetic nonzero model proves the search score consumes the NNUE
        // result rather than merely exercising the update/output handshake.
        begin
            automatic Move baseline_move, nnue_move;
            automatic EvalScore baseline_score, nnue_score;
            automatic NodeCountType baseline_nodes, nnue_nodes;
            automatic int bucket = int'(nnue_output_bucket(PieceCount'(3)));
            for (int row = bucket * NNUE_OUTPUT_MAC_CYCLES;
                    row < (bucket + 1) * NNUE_OUTPUT_MAC_CYCLES; row++)
                dut.nnue_evaluator.output_weight_rows[row] = 0;
            dut.nnue_evaluator.output_bias[bucket] = 0;
            new_game();
            setup_kings_only();
            set_tile(WHITE_PAWN, Position'(8), "NNUE baseline white pawn a2");
            run_search_depth_record(8'd0, "NNUE baseline search",
                baseline_move, baseline_score, baseline_nodes);
            for (int row = 0; row < NNUE_FEATURE_COUNT; row++)
                dut.nnue_evaluator.feature_rom[row] = 0;
            dut.nnue_evaluator.feature_rom[8] = {NNUE_ROW_BYTES{8'h55}};
            for (int row = bucket * NNUE_OUTPUT_MAC_CYCLES;
                    row < (bucket + 1) * NNUE_OUTPUT_MAC_CYCLES; row++)
                dut.nnue_evaluator.output_weight_rows[row] = {NNUE_OUTPUT_MAC_LANES{3'h1}};
            for (int lane = 0; lane < NNUE_ACCUMULATOR_COUNT; lane++)
                dut.nnue_evaluator.accumulator_bias[lane] = 4'd2;
            new_game();
            setup_kings_only();
            set_tile(WHITE_PAWN, Position'(8), "NNUE correction white pawn a2");
            run_search_depth_record(8'd0, "NNUE correction search",
                nnue_move, nnue_score, nnue_nodes);
            // Only White's direct a2-pawn feature is nonzero, so the ordered
            // concatenation contributes one activation in every White lane.
            check(nnue_score == baseline_score + EvalScore'(256),
                $sformatf("search adds NNUE correction: baseline=%0d corrected=%0d",
                    baseline_score, nnue_score));
        end
        check(nnue_delta_seen, "NNUE child states apply physical move deltas");
        check(nnue_reverse_delta_seen,
            "NNUE restores parent state with an inverse stack delta");
        check(nnue_rebuild_seen, "NNUE rebuild path initializes root accumulators");
        check(nnue_pending_state_invalid,
            "pending NNUE child slots stay invalid until their tagged completion");
        check(nnue_root_initialization_seen && nnue_root_initialization_correct,
            "pre-search NNUE roots are flushed, valid, and identical for every thread");
        check(nnue_king_delta_seen && nnue_king_delta_correct,
            "king moves use direct incremental NNUE features");
        check(nnue_castle_delta_seen,
            "castling includes the rook in direct NNUE deltas");
        check(nnue_castle_request_count_correct,
            "each castling delta uses exactly four feature requests");
        check(nnue_castle_state_seen && nnue_en_passant_state_seen
                && nnue_promotion_state_seen && nnue_special_state_correct,
            "special-move deltas and inverses exactly match full NNUE rebuilds");
        check(nnue_null_state_seen && nnue_null_state_correct,
            "null children retain valid NNUE state without an update plan");
        check(!nnue_recovery_rebuild_seen,
            "ordinary evaluation never repairs an unexpectedly invalid accumulator");
        check(stats_reset_correct, "every new search resets all statistics");
        check(tt_lookup_depth_correct, "every TT lookup uses the node remaining depth");
        check(tt_store_depth_correct, "every TT store uses the node remaining depth");

        $display("Pass Count: %0d", pass_count);
        $display("Fail Count: %0d", fail_count);
        if (fail_count != 0) begin
            $fatal(1, "search controller testbench failed");
        end
        $finish;
    end
