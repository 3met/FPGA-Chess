// Search scoring, pruning, aspiration windows, and constant-folded LMR helpers.
// Included in search_controller scope; this file is not a standalone compilation unit.

    function automatic logic is_null_move(input Move move);
        return move.from_pos == Position'(0) && move.to_pos == Position'(0);
    endfunction : is_null_move

    function automatic logic is_setup_op(input BoardOp op);
        return op == BOARD_SET_TILE_OP
            || op == BOARD_SET_TURN_OP
            || op == BOARD_SET_CASTLING_RIGHTS_OP
            || op == BOARD_SET_EN_PASSANT_OP
            || op == BOARD_SET_HALFMOVE_CLOCK_OP;
    endfunction : is_setup_op

    function automatic logic committed_move_is_irreversible(
        input FullBoard before_board,
        input FullBoard after_board,
        input Move move
    );
        automatic Tile moving_tile;
        automatic Tile destination_tile;

        moving_tile = before_board.tiles[move.from_pos];
        destination_tile = before_board.tiles[move.to_pos];
        return moving_tile.piece_type == PAWN
            || destination_tile.piece_type != NULL_PIECE
            || before_board.castling_rights != after_board.castling_rights;
    endfunction : committed_move_is_irreversible

    function automatic EvalScore terminal_no_move_score(input logic in_check, input PlyIndex ply);
        if (in_check) begin
            return EvalScore'($signed({1'b0, ply}) - MATE_SCORE);
        end
        return DRAW_EVAL_SCORE;
    endfunction : terminal_no_move_score

    function automatic Tile initial_tile(input int pos);
        // Initial-position square groups are disjoint; default supplies empty squares.
        unique case (pos)
            0: return WHITE_ROOK;
            1: return WHITE_KNIGHT;
            2: return WHITE_BISHOP;
            3: return WHITE_QUEEN;
            4: return WHITE_KING;
            5: return WHITE_BISHOP;
            6: return WHITE_KNIGHT;
            7: return WHITE_ROOK;
            8, 9, 10, 11, 12, 13, 14, 15: return WHITE_PAWN;
            48, 49, 50, 51, 52, 53, 54, 55: return BLACK_PAWN;
            56: return BLACK_ROOK;
            57: return BLACK_KNIGHT;
            58: return BLACK_BISHOP;
            59: return BLACK_QUEEN;
            60: return BLACK_KING;
            61: return BLACK_BISHOP;
            62: return BLACK_KNIGHT;
            63: return BLACK_ROOK;
            default: return EMPTY_TILE;
        endcase
    endfunction : initial_tile

    function automatic logic [3:0] initial_tile_bits(input int pos);
        automatic Tile tile;

        tile = initial_tile(pos);
        if (tile.piece_type == NULL_PIECE) begin
            return 4'h0;
        end
        return tile;
    endfunction : initial_tile_bits

    function automatic EngineControllerRequest new_game_setup_request(input logic [6:0] idx);
        automatic EngineControllerRequest setup_req;

        setup_req = EngineControllerRequest'('0);
        setup_req.operation = ENGINE_CTRL_BOARD_UPDATE;
        setup_req.board_op = BOARD_IDLE_OP;
        // Tile indices and the three explicit metadata indices are disjoint.
        unique case (1'b1)
            (idx < 7'd64): begin
                setup_req.board_op = BOARD_SET_TILE_OP;
                setup_req.move.to_pos = Position'(idx[5:0]);
                setup_req.board_wr_data = {3'b000, initial_tile_bits(int'(idx))};
            end
            (idx == 7'd64): begin
                setup_req.board_op = BOARD_SET_CASTLING_RIGHTS_OP;
                setup_req.board_wr_data = 7'b000_1111;
            end
            (idx == 7'd65): begin
                setup_req.board_op = BOARD_SET_TURN_OP;
                setup_req.board_wr_data = 7'd0;
            end
            (idx == 7'd66): begin
                setup_req.board_op = BOARD_SET_EN_PASSANT_OP;
                setup_req.board_wr_data = 7'd0;
            end
            default: begin
                setup_req.board_op = BOARD_SET_HALFMOVE_CLOCK_OP;
                setup_req.board_wr_data = 7'd0;
            end
        endcase
        return setup_req;
    endfunction : new_game_setup_request

    // Select the adaptive scale separately from the budget arithmetic so root
    // node counters never feed the next iteration's board-register enables.
    function automatic logic [3:0] adaptive_soft_factor(
        input Move best_move,
        input EvalScore score,
        input logic [7:0] stable_depths,
        input NodeCountType root_nodes,
        input NodeCountType best_nodes
    );
        automatic integer factor;
        automatic logic [40:0] twice_best;
        automatic logic [41:0] four_best;
        automatic logic [41:0] three_total;
        automatic logic signed [16:0] score_wide;
        automatic logic signed [16:0] previous_wide;

        factor = SOFT_FACTOR_DEFAULT;
        twice_best = {1'b0, best_nodes} * 2;
        four_best = {2'b00, best_nodes} * 4;
        three_total = {2'b00, root_nodes} * 3;
        if (twice_best < {1'b0, root_nodes})
            factor = factor + 1;
        else if (four_best > three_total)
            factor = factor - 1;
        if (best_move != previous_depth_best_move)
            factor = factor + 1;
        else if (stable_depths >= STABLE_DEPTH_THRESHOLD)
            factor = factor - 1;
        score_wide = {score[15], score};
        previous_wide = {previous_depth_score[15], previous_depth_score};
        if (search_completed_depth != SearchDepth'(0)
                && score_wide < previous_wide - SCORE_DROP_THRESHOLD)
            factor = factor + 2;
        if (factor < SOFT_FACTOR_MINIMUM)
            factor = SOFT_FACTOR_MINIMUM;
        else if (factor > SOFT_FACTOR_MAXIMUM)
            factor = SOFT_FACTOR_MAXIMUM;
        return 4'(factor);
    endfunction : adaptive_soft_factor

    function automatic EvalScore pov_eval(input FullBoard board, input EvalScore white_relative_eval);
        return (board.turn == WHITE) ? white_relative_eval : -white_relative_eval;
    endfunction : pov_eval

    function automatic EvalScore add_nnue_correction(
        input EvalScore material_pst,
        input EvalScore correction
    );
        automatic logic signed [16:0] total =
            $signed({material_pst[15], material_pst})
            + $signed({correction[15], correction});
        if (total > 17'sd16383)
            return MAX_NON_MATE_EVAL_SCORE;
        if (total < -17'sd16383)
            return -MAX_NON_MATE_EVAL_SCORE;
        return EvalScore'(total);
    endfunction : add_nnue_correction

    // Keep the RFP score comparison wide so a configured margin cannot wrap
    // either operand near the edge of the signed evaluation representation.
    function automatic logic rfp_prunes(
        input EvalScore static_eval,
        input EvalScore beta,
        input SearchDepth depth
    );
        automatic logic signed [31:0] static_eval_wide =
            $signed({{16{static_eval[15]}}, static_eval});
        automatic logic signed [31:0] beta_wide =
            $signed({{16{beta[15]}}, beta});
        automatic logic signed [31:0] margin =
            RFP_BASE_MARGIN + RFP_MARGIN_PER_DEPTH * int'(depth);
        return static_eval_wide - margin >= beta_wide;
    endfunction : rfp_prunes

    // RFP applies only to positive-depth zero-window nodes with a finite beta.
    function automatic logic rfp_node_eligible(
        input SearchDepth depth,
        input logic zero_window,
        input logic in_check,
        input EvalScore beta
    );
        return depth != SearchDepth'(0)
            && int'(depth) <= RFP_MAXIMUM_DEPTH
            && zero_window
            && !in_check
            && beta > -MATE_THRESHOLD
            && beta < MATE_THRESHOLD;
    endfunction : rfp_node_eligible

    // Ordinary-node futility uses the depth that the move would actually
    // receive after LMR, rather than the parent's raw remaining depth.
    function automatic logic futility_move_eligible(
        input PlyIndex ply,
        input SearchDepth predicted_depth,
        input logic in_check,
        input logic gives_check,
        input logic quiet,
        input logic promotion,
        input logic direct_move,
        input logic has_searched_move,
        input logic is_research
    );
        return ply != PlyIndex'(0)
            && int'(predicted_depth) <= FUTILITY_MAXIMUM_DEPTH
            && !in_check
            && !gives_check
            && quiet
            && !promotion
            && !direct_move
            && has_searched_move
            && !is_research;
    endfunction : futility_move_eligible

    // Widen both scores before adding the configured depth-scaled margin.
    function automatic logic futility_prunes(
        input EvalScore static_eval,
        input EvalScore alpha,
        input SearchDepth predicted_depth
    );
        automatic logic signed [31:0] static_eval_wide =
            $signed({{16{static_eval[15]}}, static_eval});
        automatic logic signed [31:0] alpha_wide =
            $signed({{16{alpha[15]}}, alpha});
        automatic logic signed [31:0] margin = FUTILITY_BASE_MARGIN
            + FUTILITY_MARGIN_PER_DEPTH * int'(predicted_depth);
        return static_eval_wide + margin <= alpha_wide;
    endfunction : futility_prunes

    // Prune a non-checking qsearch capture whose optimistic material gain
    // cannot raise alpha. Callers separately restrict this to qsearch nodes.
    function automatic logic qdelta_prunes(
        input EvalScore static_eval,
        input EvalScore alpha,
        input PieceType victim,
        input logic in_check,
        input logic gives_check,
        input logic promotion,
        input logic capture,
        input logic immediate_recapture
    );
        automatic logic signed [31:0] static_eval_wide =
            $signed({{16{static_eval[15]}}, static_eval});
        automatic logic signed [31:0] alpha_wide =
            $signed({{16{alpha[15]}}, alpha});
        automatic logic signed [31:0] victim_value = PIECE_VALS_128[victim];
        return !in_check
            && !gives_check
            && !promotion
            && capture
            && !immediate_recapture
            && static_eval_wide + victim_value + QDELTA_MARGIN <= alpha_wide;
    endfunction : qdelta_prunes

    // Decode capture, promotion, en-passant, and recapture properties from the
    // unchanged parent board after the speculative move has proved legal.
    function automatic logic qdelta_move_prunes(
        input FullBoard board,
        input Move previous_move,
        input Move move,
        input EvalScore static_eval,
        input EvalScore alpha,
        input logic in_check,
        input logic gives_check
    );
        automatic Tile mover = board.tiles[move.from_pos];
        automatic Tile destination = board.tiles[move.to_pos];
        automatic logic en_passant_capture = mover.piece_type == PAWN
            && move.from_pos[2:0] != move.to_pos[2:0]
            && destination.piece_type == NULL_PIECE;
        automatic logic promotion = mover.piece_type == PAWN
            && (move.to_pos[5:3] == BoardRank'(0)
                || move.to_pos[5:3] == BoardRank'(7));
        automatic PieceType victim = en_passant_capture
            ? PAWN : destination.piece_type;
        return qdelta_prunes(
            static_eval,
            alpha,
            victim,
            in_check,
            gives_check,
            promotion,
            destination.piece_type != NULL_PIECE || en_passant_capture,
            !is_null_move(previous_move) && move.to_pos == previous_move.to_pos
        );
    endfunction : qdelta_move_prunes

    // Stagger the initial windows across threads to diversify Lazy SMP searches.
    function automatic AspirationDelta aspiration_initial_delta(input int unsigned thread_id);
        return AspirationDelta'(ASPIRATION_STARTING_DELTA + (thread_id % 8));
    endfunction : aspiration_initial_delta

    // Grow each thread's current delta with a small constant Q3 multiply.
    function automatic AspirationDelta aspiration_next_delta(input AspirationDelta delta);
        automatic logic [31:0] scaled = delta * ASPIRATION_DELTA_MULTIPLIER_Q3;
        automatic logic [31:0] rounded = (scaled + 32'd4) >> 3;
        if (rounded >= 32'd32767)
            return AspirationDelta'(32767);
        // Ensure that quantization cannot leave a narrow window stuck at one size.
        if (rounded <= delta)
            return delta + AspirationDelta'(1);
        return AspirationDelta'(rounded);
    endfunction : aspiration_next_delta

    // Clamp aspiration bounds before narrowing them to the score representation.
    function automatic EvalScore aspiration_lower_bound(
        input EvalScore score,
        input AspirationDelta delta
    );
        automatic logic signed [16:0] bound =
            $signed({score[15], score}) - $signed({2'b00, delta});
        return (bound <= -17'sd32767) ? -SEARCH_INF : EvalScore'(bound);
    endfunction : aspiration_lower_bound

    function automatic EvalScore aspiration_upper_bound(
        input EvalScore score,
        input AspirationDelta delta
    );
        automatic logic signed [16:0] bound =
            $signed({score[15], score}) + $signed({2'b00, delta});
        return (bound >= 17'sd32767) ? SEARCH_INF : EvalScore'(bound);
    endfunction : aspiration_upper_bound

    // Every newly entered node starts from the same empty search record.
    function automatic SearchStackEntry empty_search_stack_entry();
        automatic SearchStackEntry entry;
        entry.move = NULL_MOVE;
        entry.best_move = NULL_MOVE;
        entry.best_score = -SEARCH_INF;
        entry.static_eval = EvalScore'(0);
        entry.alpha = -SEARCH_INF;
        entry.orig_alpha = -SEARCH_INF;
        entry.beta = SEARCH_INF;
        entry.tt_move = NULL_MOVE;
        entry.repetition_start = PlyIndex'(0);
        entry.remaining_depth = SearchDepth'(0);
        entry.legal_move_count = 8'd0;
        entry.move_order_state = MOVE_ORDER_DIRECT;
        entry.direct_attempted = 1'b0;
        entry.has_legal = 1'b0;
        entry.tt_checked = 1'b0;
        entry.has_tt_move = 1'b0;
        entry.stand_pat_done = 1'b0;
        entry.static_eval_valid = 1'b0;
        entry.node_in_check = 1'b0;
        entry.scout_search = 1'b0;
        entry.zero_window_node = 1'b0;
        entry.unit_window = 1'b0;
        entry.count_move_on_return = 1'b0;
        entry.null_attempted = 1'b0;
        entry.entered_by_null = 1'b0;
        entry.rfp_checked = 1'b0;
        entry.nnue_from = Position'(0);
        entry.nnue_to = Position'(0);
        entry.nnue_capture_pos = Position'(0);
        entry.nnue_mover = EMPTY_TILE;
        entry.nnue_placed = EMPTY_TILE;
        entry.nnue_capture = EMPTY_TILE;
        entry.nnue_capture_valid = 1'b0;
        entry.nnue_delta_valid = 1'b0;
        entry.failed_quiet0 = 12'd0;
        entry.failed_quiet1 = 12'd0;
        entry.failed_quiet2 = 12'd0;
        entry.failed_quiet_count = 2'd0;
        return entry;
    endfunction : empty_search_stack_entry

    function automatic logic search_stop_requested();
        return search_node_stop_q || search_time_stop_q;
    endfunction : search_stop_requested

    function automatic logic search_in_qsearch(input ThreadID thread);
        return search_stack_top[thread].remaining_depth == SearchDepth'(0);
    endfunction : search_in_qsearch

    // Constant-folded Q8 approximation used to populate the small LMR ROM.
    function automatic logic [7:0] lmr_table_value_for_params(
        input longint unsigned a_q8,
        input longint unsigned b_q8,
        input int depth_bucket,
        input int move_bucket
    );
        automatic longint unsigned numerator;
        automatic longint unsigned reduction_q8;
        automatic longint unsigned rounded;
        numerator = longint'(LMR_LN2_Q8) * longint'(LMR_LN2_Q8)
            * longint'(depth_bucket) * longint'(move_bucket);
        // Round the complete rational expression once, rather than rounding
        // the logarithmic term separately before adding A.
        if (b_q8 == 0) return 8'd0;
        reduction_q8 = a_q8 * b_q8 + numerator;
        rounded = (reduction_q8 + (longint'(128) * b_q8)) / (longint'(256) * b_q8);
        return rounded > 255 ? 8'hff : 8'(rounded);
    endfunction : lmr_table_value_for_params

    function automatic logic [7:0] lmr_table_value(input int depth_bucket, input int move_bucket);
        return lmr_table_value_for_params(LMR_A_Q8, LMR_B_Q8, depth_bucket, move_bucket);
    endfunction : lmr_table_value

    function automatic logic [2:0] floor_log2_8(input logic [7:0] value);
        for (int bit_index = 7; bit_index >= 0; bit_index--)
            if (value[bit_index]) return 3'(bit_index);
        return 3'd0;
    endfunction : floor_log2_8

    function automatic logic [7:0] max_raw_lmr_table_value();
        automatic logic [7:0] maximum;
        maximum = 8'd0;
        for (int depth_bucket = 0; depth_bucket < LMR_DEPTH_BUCKETS; depth_bucket++)
            for (int move_bucket = 0; move_bucket < 8; move_bucket++)
                if (lmr_table_value(depth_bucket, move_bucket) > maximum)
                    maximum = lmr_table_value(depth_bucket, move_bucket);
        return maximum;
    endfunction : max_raw_lmr_table_value

    localparam logic [7:0] LMR_TABLE_MAX_VALUE = max_raw_lmr_table_value();
    localparam int LMR_TABLE_VALUE_BITS = (LMR_TABLE_MAX_VALUE <= 1)
        ? 1 : $clog2(LMR_TABLE_MAX_VALUE + 1);
    // A case lookup gives every simulator and synthesis tool the same
    // constant-folded table without runtime logarithms, multiplication, or
    // division. Depth buckets above five are unreachable with MAX_PLY_COUNT=64.
    function automatic SearchDepth lmr_reduction(
        input logic [2:0] depth_bucket,
        input logic [2:0] move_bucket
    );
        // Reduction-table addresses are distinct; default retains zero reduction.
        unique case ({depth_bucket, move_bucket})
            6'o00: return SearchDepth'(lmr_table_value(0, 0));
            6'o01: return SearchDepth'(lmr_table_value(0, 1));
            6'o02: return SearchDepth'(lmr_table_value(0, 2));
            6'o03: return SearchDepth'(lmr_table_value(0, 3));
            6'o04: return SearchDepth'(lmr_table_value(0, 4));
            6'o05: return SearchDepth'(lmr_table_value(0, 5));
            6'o06: return SearchDepth'(lmr_table_value(0, 6));
            6'o07: return SearchDepth'(lmr_table_value(0, 7));
            6'o10: return SearchDepth'(lmr_table_value(1, 0));
            6'o11: return SearchDepth'(lmr_table_value(1, 1));
            6'o12: return SearchDepth'(lmr_table_value(1, 2));
            6'o13: return SearchDepth'(lmr_table_value(1, 3));
            6'o14: return SearchDepth'(lmr_table_value(1, 4));
            6'o15: return SearchDepth'(lmr_table_value(1, 5));
            6'o16: return SearchDepth'(lmr_table_value(1, 6));
            6'o17: return SearchDepth'(lmr_table_value(1, 7));
            6'o20: return SearchDepth'(lmr_table_value(2, 0));
            6'o21: return SearchDepth'(lmr_table_value(2, 1));
            6'o22: return SearchDepth'(lmr_table_value(2, 2));
            6'o23: return SearchDepth'(lmr_table_value(2, 3));
            6'o24: return SearchDepth'(lmr_table_value(2, 4));
            6'o25: return SearchDepth'(lmr_table_value(2, 5));
            6'o26: return SearchDepth'(lmr_table_value(2, 6));
            6'o27: return SearchDepth'(lmr_table_value(2, 7));
            6'o30: return SearchDepth'(lmr_table_value(3, 0));
            6'o31: return SearchDepth'(lmr_table_value(3, 1));
            6'o32: return SearchDepth'(lmr_table_value(3, 2));
            6'o33: return SearchDepth'(lmr_table_value(3, 3));
            6'o34: return SearchDepth'(lmr_table_value(3, 4));
            6'o35: return SearchDepth'(lmr_table_value(3, 5));
            6'o36: return SearchDepth'(lmr_table_value(3, 6));
            6'o37: return SearchDepth'(lmr_table_value(3, 7));
            6'o40: return SearchDepth'(lmr_table_value(4, 0));
            6'o41: return SearchDepth'(lmr_table_value(4, 1));
            6'o42: return SearchDepth'(lmr_table_value(4, 2));
            6'o43: return SearchDepth'(lmr_table_value(4, 3));
            6'o44: return SearchDepth'(lmr_table_value(4, 4));
            6'o45: return SearchDepth'(lmr_table_value(4, 5));
            6'o46: return SearchDepth'(lmr_table_value(4, 6));
            6'o47: return SearchDepth'(lmr_table_value(4, 7));
            6'o50: return SearchDepth'(lmr_table_value(5, 0));
            6'o51: return SearchDepth'(lmr_table_value(5, 1));
            6'o52: return SearchDepth'(lmr_table_value(5, 2));
            6'o53: return SearchDepth'(lmr_table_value(5, 3));
            6'o54: return SearchDepth'(lmr_table_value(5, 4));
            6'o55: return SearchDepth'(lmr_table_value(5, 5));
            6'o56: return SearchDepth'(lmr_table_value(5, 6));
            6'o57: return SearchDepth'(lmr_table_value(5, 7));
            default: return SearchDepth'(0);
        endcase
    endfunction : lmr_reduction
    generate
        if (LMR_B_Q8 == 0) begin : gen_invalid_lmr_denominator
            initial $fatal(1, "LMR_B_Q8 must be nonzero");
        end
        if (LMR_TABLE_VALUE_BITS > SEARCH_DEPTH_BITS) begin : gen_oversized_lmr_table_value
            initial $fatal(1, "LMR table value does not fit SearchDepth");
        end
    endgenerate

    // Apply bucket confidence before the depth clamp, with a carry bit for +1.
    function automatic SearchDepth lmr_bucket_reduction(
        input SearchDepth base_reduction,
        input SearchDepth depth,
        input MoveBucketIndex bucket
    );
        automatic logic [SEARCH_DEPTH_BITS:0] adjusted = {1'b0, base_reduction};
        // Bucket groups are disjoint; default retains the unadjusted reduction.
        unique case (bucket)
            GOOD_NOISY_HIGH_BUCKET, GOOD_NOISY_LOW_BUCKET, QUIET_HIGHEST_BUCKET:
                if (adjusted != 0) adjusted = adjusted - 1'b1;
            QUIET_LOW_BUCKET: adjusted = adjusted + 1'b1;
            default: begin end
        endcase
        if (depth == SearchDepth'(0)) return SearchDepth'(0);
        if (adjusted >= {1'b0, depth}) return depth - SearchDepth'(1);
        return SearchDepth'(adjusted);
    endfunction : lmr_bucket_reduction

    function automatic SearchDepth lmr_child_depth(
        input ThreadID thread,
        input MoveBucketIndex bucket
    );
        automatic SearchDepth depth;
        automatic logic [7:0] move_index;
        automatic SearchDepth reduction;
        automatic logic [2:0] depth_bucket;
        depth = search_stack_top[thread].remaining_depth;
        move_index = search_stack_top[thread].legal_move_count == 8'hff
            ? 8'hff : search_stack_top[thread].legal_move_count + 8'd1;
        depth_bucket = floor_log2_8(depth);
        reduction = lmr_reduction(depth_bucket, floor_log2_8(move_index));
        reduction = lmr_bucket_reduction(reduction, depth, bucket);
        return depth - SearchDepth'(1) - reduction;
    endfunction : lmr_child_depth

    // Bucket confidence changes reduction size, not main-search eligibility.
    function automatic logic lmr_eligible(
        input PlyIndex ply,
        input SearchDepth remaining_depth,
        input logic [7:0] legal_move_count,
        input logic is_research
    );
        return ply != PlyIndex'(0) && remaining_depth >= SearchDepth'(LMR_MINIMUM_DEPTH)
            && legal_move_count >= 8'(LMR_MINIMUM_MOVE_NUMBER - 1) && !is_research;
    endfunction : lmr_eligible

    function automatic logic search_needs_research(
        input logic was_scout,
        input logic was_reduced,
        input EvalScore score,
        input EvalScore alpha,
        input EvalScore beta
    );
        // Every alpha-raising reduced scout is verified at full depth, including
        // apparent beta cutoffs. Ordinary PVS scouts retain cutoff behavior.
        return was_scout && score > alpha && (score < beta || was_reduced);
    endfunction : search_needs_research
