// Existing untimed search-policy checks under the controller fixture policy.
// Included inside the main integration sequence.

        // Promotion recognition must distinguish pawns from every other piece
        // on both penultimate ranks, including capture destinations on each file.
        for (int color_index = 0; color_index < 2; color_index++) begin
            for (int file_index = 0; file_index < 8; file_index++) begin
                for (int piece_index = 0; piece_index < 7; piece_index++) begin
                    automatic FullBoard board = '0;
                    automatic Move move = NULL_MOVE;
                    move.from_pos = Position'((color_index == 0 ? 48 : 8) + file_index);
                    board.tiles[move.from_pos] = Tile'({1'(color_index), 3'(piece_index)});
                    for (int destination_file = 0; destination_file < 8; destination_file++) begin
                        if (destination_file >= file_index - 1 && destination_file <= file_index + 1) begin
                            move.to_pos = Position'((color_index == 0 ? 56 : 0) + destination_file);
                            check(dut.is_promotion_move(board, move) == (PieceType'(piece_index) == PAWN),
                                "promotion classification on either back rank");
                        end
                    end
                    move.to_pos = Position'((color_index == 0 ? 40 : 16) + file_index);
                    check(!dut.is_promotion_move(board, move), "non-promotion destination stays ordinary");
                end
            end
        end

        // Wide operands must cancel before clipping into the finite score band.
        for (int base_index = 0; base_index < 5; base_index++) begin
            automatic int base = (base_index-2) * (PST_EVAL_BOUND / 2);
            for (int correction_index = 0; correction_index < 5; correction_index++) begin
                automatic int correction = (correction_index-2) * (NNUE_CORRECTION_BOUND / 2);
                automatic int expected = base + correction;
                if (expected > int'(MAX_NON_MATE_EVAL_SCORE)) expected = int'(MAX_NON_MATE_EVAL_SCORE);
                if (expected < -int'(MAX_NON_MATE_EVAL_SCORE)) expected = -int'(MAX_NON_MATE_EVAL_SCORE);
                check(int'(dut.add_nnue_correction(PstEvalScore'(base), NnueCorrection'(correction))) == expected,
                    "combined static evaluation clips after wide cancellation");
            end
        end

        // Probe both mate-range boundaries and the adjacent finite scores.
        check(dut.null_beta_eligible(MATE_THRESHOLD - EvalScore'(1))
                && dut.null_beta_eligible(-MATE_THRESHOLD + EvalScore'(1))
                && dut.null_beta_eligible(DRAW_EVAL_SCORE),
            "null pruning accepts finite beta bounds");
        check(!dut.null_beta_eligible(MATE_THRESHOLD)
                && !dut.null_beta_eligible(-MATE_THRESHOLD)
                && !dut.null_beta_eligible(MATE_SCORE)
                && !dut.null_beta_eligible(-MATE_SCORE)
                && !dut.null_beta_eligible(MAX_EVAL_SCORE)
                && !dut.null_beta_eligible(-MAX_EVAL_SCORE),
            "null pruning excludes winning and losing mate bounds and infinity");

        check(dut.lmr_table_value_for_params(128, 256, 1, 1) == 8'd1,
            "LMR non-default half-ply offset rounds the complete curve once");
        check(dut.lmr_table_value_for_params(0, 256, 2, 2) == 8'd2,
            "LMR non-default denominator preserves Q8 curve scaling");
        check((1 << dut.LMR_TABLE_VALUE_BITS) > dut.LMR_TABLE_MAX_VALUE,
            "LMR table value width represents the configured maximum");
        check(dut.floor_log2_8(8'd1) == 3'd0 && dut.floor_log2_8(8'd2) == 3'd1,
            "LMR move/depth bucket lower boundaries");
        check(dut.floor_log2_8(8'd3) == 3'd1 && dut.floor_log2_8(8'd4) == 3'd2,
            "LMR move/depth bucket upper boundaries");
        check(dut.floor_log2_8(8'd127) == 3'd6 && dut.floor_log2_8(8'd128) == 3'd7,
            "LMR 8-bit saturation bucket boundary");
        // Exercise bucket confidence independently of the configured base curve.
        for (int bucket = 0; bucket < move_generator_defs::MOVE_BUCKET_COUNT; bucket++) begin
            automatic int expected = (bucket == move_generator_defs::QUIET_HIGHEST_BUCKET
                || bucket == move_generator_defs::GOOD_NOISY_LOW_BUCKET || bucket == move_generator_defs::GOOD_NOISY_HIGH_BUCKET)
                ? 1 : 2;
            check(dut.lmr_bucket_reduction(8'(2), 8'(6),
                    move_generator_defs::MoveBucketIndex'(bucket)) == 8'(expected),
                $sformatf("LMR confidence adjustment for bucket %0d", bucket));
            check(dut.lmr_bucket_reduction(8'(0), 8'(6),
                    move_generator_defs::MoveBucketIndex'(bucket))
                    == 8'(0),
                $sformatf("LMR zero reduction cannot underflow for bucket %0d", bucket));
        end
        check(dut.lmr_bucket_reduction(8'(3), 8'(3),
                move_generator_defs::QUIET_HIGHEST_BUCKET) == 8'(2),
            "LMR applies confidence before clamping to remaining depth");
        check(dut.lmr_bucket_reduction(8'((1 << dut.SEARCH_DEPTH_BITS) - 1), 8'(6),
                move_generator_defs::QUIET_LOW_BUCKET) == 8'(5),
            "LMR maximum base reduction clamps without wrapping");
        dut.search_completed_depth = 5'd2;
        dut.previous_depth_best_move = make_move(Position'(8), Position'(16), PROMO_QUEEN);
        dut.previous_depth_score = EvalScore'(100);
        check(dut.adaptive_soft_factor(
                make_move(Position'(9), Position'(17), PROMO_QUEEN), EvalScore'(100),
                8'd1, NodeCountType'(100), NodeCountType'(40)) == 4'd6,
            "unstable low-share best move selects the 1.5x factor");
        check(dut.adaptive_soft_factor(
                make_move(Position'(8), Position'(16), PROMO_QUEEN), EvalScore'(100),
                8'd3, NodeCountType'(100), NodeCountType'(80)) == 4'd2,
            "stable dominant best move selects the 0.5x factor");
        check(dut.adaptive_soft_factor(
                make_move(Position'(9), Position'(17), PROMO_QUEEN), EvalScore'(35),
                8'd1, NodeCountType'(100), NodeCountType'(40)) == 4'd8,
            "a score drop expands and clamps the factor to 2.0x");
        check(!dut.lmr_eligible(PlyIndex'(0), 8'd8, 8'd2, 1'b0), "LMR excludes root moves");
        check(!dut.lmr_eligible(PlyIndex'(1), 8'd2, 8'd2, 1'b0), "LMR excludes shallow moves");
        check(!dut.lmr_eligible(PlyIndex'(1), 8'd3, 8'd1, 1'b0), "LMR excludes the first two legal moves");
        check(dut.lmr_eligible(PlyIndex'(1), 8'd3, 8'd2, 1'b0), "LMR includes the third legal move");
        check(!dut.lmr_eligible(PlyIndex'(1), 8'd3, 8'd2, 1'b1), "LMR excludes full-depth recovery");
        check(dut.search_needs_research(1'b1, 1'b1, EvalScore'(20), EvalScore'(10), EvalScore'(20)),
            "LMR verifies a reduced beta cutoff at full depth");
        check(!dut.search_needs_research(1'b1, 1'b0, EvalScore'(20), EvalScore'(10), EvalScore'(20)),
            "ordinary PVS beta cutoff does not require full-depth recovery");
        check(dut.rfp_node_eligible(5'd5, 1'b1, 1'b0, EvalScore'(0)),
            "RFP includes finite zero-window nodes at its maximum depth");
        check(!dut.rfp_node_eligible(5'd0, 1'b1, 1'b0, EvalScore'(0))
                && !dut.rfp_node_eligible(5'd6, 1'b1, 1'b0, EvalScore'(0)),
            "RFP excludes quiescence and nodes beyond its maximum depth");
        check(!dut.rfp_node_eligible(5'd5, 1'b0, 1'b0, EvalScore'(0))
                && !dut.rfp_node_eligible(5'd5, 1'b1, 1'b1, EvalScore'(0)),
            "RFP excludes full-window and checked nodes");
        check(!dut.rfp_node_eligible(5'd5, 1'b1, 1'b0, MATE_THRESHOLD)
                && !dut.rfp_node_eligible(5'd5, 1'b1, 1'b0, -MATE_THRESHOLD),
            "RFP excludes decisive beta bounds");
        check(dut.rfp_prunes(EvalScore'(704), EvalScore'(0), 5'd5)
                && !dut.rfp_prunes(EvalScore'(703), EvalScore'(0), 5'd5),
            "RFP depth-five margin uses the configured 64 plus 128 per depth");
        check(dut.rfp_prunes(EvalScore'(92), EvalScore'(-100), 5'd1)
                && !dut.rfp_prunes(EvalScore'(91), EvalScore'(-100), 5'd1),
            "RFP returns static evaluation exactly at the configured margin boundary");
        check(dut.futility_prunes(EvalScore'(-768), EvalScore'(0), 5'd3)
                && !dut.futility_prunes(EvalScore'(-767), EvalScore'(0), 5'd3),
            "ordinary futility includes the exact 150cp plus 150cp-per-depth boundary");
        check(dut.futility_move_eligible(
                PlyIndex'(1), 5'd3, 1'b0, 1'b0, 1'b1, 1'b0, 1'b0, 1'b1, 1'b0),
            "ordinary futility includes a later quiet at its maximum predicted depth");
        check(!dut.futility_move_eligible(
                PlyIndex'(1), 5'd4, 1'b0, 1'b0, 1'b1, 1'b0, 1'b0, 1'b1, 1'b0)
                && !dut.futility_move_eligible(
                    PlyIndex'(0), 5'd3, 1'b0, 1'b0, 1'b1, 1'b0, 1'b0, 1'b1, 1'b0),
            "ordinary futility uses predicted depth and excludes root moves");
        check(!dut.futility_move_eligible(
                PlyIndex'(1), 5'd3, 1'b1, 1'b0, 1'b1, 1'b0, 1'b0, 1'b1, 1'b0)
                && !dut.futility_move_eligible(
                    PlyIndex'(1), 5'd3, 1'b0, 1'b1, 1'b1, 1'b0, 1'b0, 1'b1, 1'b0)
                && !dut.futility_move_eligible(
                    PlyIndex'(1), 5'd3, 1'b0, 1'b0, 1'b0, 1'b0, 1'b0, 1'b1, 1'b0),
            "ordinary futility excludes checked nodes, checking moves, and noisy moves");
        check(!dut.futility_move_eligible(
                PlyIndex'(1), 5'd3, 1'b0, 1'b0, 1'b1, 1'b1, 1'b0, 1'b1, 1'b0)
                && !dut.futility_move_eligible(
                    PlyIndex'(1), 5'd3, 1'b0, 1'b0, 1'b1, 1'b0, 1'b1, 1'b1, 1'b0)
                && !dut.futility_move_eligible(
                    PlyIndex'(1), 5'd3, 1'b0, 1'b0, 1'b1, 1'b0, 1'b0, 1'b0, 1'b0)
                && !dut.futility_move_eligible(
                    PlyIndex'(1), 5'd3, 1'b0, 1'b0, 1'b1, 1'b0, 1'b0, 1'b1, 1'b1),
            "ordinary futility excludes promotions, direct moves, first lines, and re-searches");
        check(dut.qdelta_prunes(
                EvalScore'(-128), EvalScore'(384), PAWN,
                1'b0, 1'b0, 1'b0, 1'b1, 1'b0),
            "qsearch delta pruning includes the exact alpha boundary");
        check(!dut.qdelta_prunes(
                EvalScore'(-127), EvalScore'(384), PAWN,
                1'b0, 1'b0, 1'b0, 1'b1, 1'b0),
            "qsearch delta pruning keeps a capture above the alpha boundary");
        check(!dut.qdelta_prunes(
                EvalScore'(-128), EvalScore'(384), PAWN,
                1'b1, 1'b0, 1'b0, 1'b1, 1'b0)
                && !dut.qdelta_prunes(
                    EvalScore'(-128), EvalScore'(384), PAWN,
                    1'b0, 1'b1, 1'b0, 1'b1, 1'b0),
            "qsearch delta pruning exempts checked nodes and checking moves");
        check(!dut.qdelta_prunes(
                EvalScore'(-128), EvalScore'(384), PAWN,
                1'b0, 1'b0, 1'b1, 1'b1, 1'b0)
                && !dut.qdelta_prunes(
                    EvalScore'(-128), EvalScore'(384), PAWN,
                    1'b0, 1'b0, 1'b0, 1'b0, 1'b0)
                && !dut.qdelta_prunes(
                    EvalScore'(-128), EvalScore'(384), PAWN,
                    1'b0, 1'b0, 1'b0, 1'b1, 1'b1),
            "qsearch delta pruning exempts promotions, non-captures, and recaptures");
        // Untimed function checks temporarily seed register fields without simulator-specific force/release.
        begin
            automatic PlyIndex saved_depth = PlyIndex'(dut.search_stack_top[0].remaining_depth);
            automatic logic [7:0] saved_count = dut.search_stack_top[0].legal_move_count;
            dut.search_stack_top[0].remaining_depth = 5'd6;
            check(dut.null_child_depth(ThreadID'(0)) == 5'd3,
                "null reduction is two plies below depth seven");
            dut.search_stack_top[0].remaining_depth = 5'd7;
            check(dut.null_child_depth(ThreadID'(0)) == 5'd3,
                "null reduction is three plies from depth seven");
            dut.search_stack_top[0].remaining_depth = 5'd3;
            dut.search_stack_top[0].legal_move_count = 8'hff;
            check(dut.lmr_child_depth(ThreadID'(0), move_generator_defs::QUIET_MEDIUM_BUCKET) <= 8'd2, "LMR clamps reduction to d-1 at saturated move count");
            dut.search_stack_top[0].remaining_depth = saved_depth;
            dut.search_stack_top[0].legal_move_count = saved_count;
        end
        for (int depth_bucket = 0; depth_bucket < dut.LMR_DEPTH_BUCKETS; depth_bucket++) begin
            for (int move_bucket = 1; move_bucket < 8; move_bucket++) begin
                check(dut.lmr_reduction(3'(depth_bucket), 3'(move_bucket))
                        >= dut.lmr_reduction(3'(depth_bucket), 3'(move_bucket - 1)),
                    $sformatf("LMR table move monotonic depth bucket %0d move bucket %0d", depth_bucket, move_bucket));
            end
        end
        for (int depth_bucket = 1; depth_bucket < dut.LMR_DEPTH_BUCKETS; depth_bucket++) begin
            for (int move_bucket = 0; move_bucket < 8; move_bucket++) begin
                check(dut.lmr_reduction(3'(depth_bucket), 3'(move_bucket))
                        >= dut.lmr_reduction(3'(depth_bucket - 1), 3'(move_bucket)),
                    $sformatf("LMR table depth monotonic depth bucket %0d move bucket %0d", depth_bucket, move_bucket));
            end
        end
