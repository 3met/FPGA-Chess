// By Emet Behrendt

package tt_defs;

    import general_chess_defs::*;

    localparam int TT_COMPACT_ENTRY_BITS = 94;
    localparam int TT_FULL_ENTRY_BITS = 126;
    localparam int TT_ENTRY_BITS = TT_COMPACT_ENTRY_BITS;
    localparam int TT_VERIFY_BITS = 48;
    localparam int TT_DEPTH_BITS = 6;
    localparam int TT_AGE_BITS = 8;
    localparam int TT_AUX_BITS = 16;

    // Bit 14 separates finite evaluations from mates. The 0x100 score gap
    // represents distances through 256 plies (mate in at least 128 moves).
    localparam EvalScore MATE_THRESHOLD = EvalScore'(16'h4000);
    localparam EvalScore MATE_SCORE = EvalScore'(16'h4100);

    typedef logic [TT_DEPTH_BITS-1:0] TTDepth;
    typedef logic [TT_AGE_BITS-1:0] TTAge;
    typedef logic [TT_AUX_BITS-1:0] TTAux;
    typedef logic [TT_VERIFY_BITS-1:0] TTVerifyKey;
    // Store only the defined move bits; TT records have no unused move padding.
    typedef logic [$bits(Move)-1:0] TTMoveBits;

    typedef enum logic [1:0] {
        TT_BOUND_INVALID,
        TT_BOUND_EXACT,
        TT_BOUND_LOWER,
        TT_BOUND_UPPER
    } TTBoundType;

    typedef struct packed {
        ThreadID thread_id;
        ZobristKey zobrist_key;
        TTDepth depth;
        EvalScore alpha;
        EvalScore beta;
        PlyIndex ply;
    } TTLookupRequest;

    typedef struct packed {
        // Route metadata retained until the controller captures this result.
        ThreadID thread_id;
        logic hit;
        EvalScore score;
        TTBoundType bound_type;
        TTDepth depth;
        Move best_move;
    } TTLookupResponse;

    typedef struct packed {
        ZobristKey zobrist_key;
        TTDepth depth;
        EvalScore score;
        TTBoundType bound_type;
        Move best_move;
        TTAge age;
        PlyIndex ply;
    } TTStoreRequest;

    localparam int TT_PHYSICAL_ENTRY_BITS = 96;
    localparam int TT_WORD_BITS = 16;
    localparam int TT_WORDS_PER_ENTRY = 6;
    localparam int TT_EXTERNAL_WORD_ADDR_BITS = 25;
    localparam int TT_EXTERNAL_ENTRY_COUNT = 5_592_405;

    typedef logic [TT_PHYSICAL_ENTRY_BITS-1:0] TTPhysicalEntry;
    typedef logic [TT_EXTERNAL_WORD_ADDR_BITS-1:0] TTWordAddress;

    typedef struct packed {
        TTAge age;
        TTBoundType bound_type;
        TTDepth depth;
        EvalScore score;
        TTMoveBits best_move_bits;
        TTVerifyKey verify_key;
    } TTEntry;

    typedef struct packed {
        TTAux aux;
        TTAge age;
        TTBoundType bound_type;
        TTDepth depth;
        EvalScore score;
        TTMoveBits best_move_bits;
        ZobristKey zobrist_key;
    } TTFullEntry;

    function automatic TTVerifyKey tt_verify_key(input ZobristKey zobrist_key);
        return zobrist_key[$bits(ZobristKey)-1 -: TT_VERIFY_BITS];
    endfunction : tt_verify_key

    function automatic TTMoveBits tt_encode_move(input Move move);
        return TTMoveBits'(move);
    endfunction : tt_encode_move

    function automatic Move tt_decode_move(input TTMoveBits move_bits);
        return Move'(move_bits[$bits(Move)-1:0]);
    endfunction : tt_decode_move

    // Store mate scores relative to the node so entries remain valid when the
    // same position is reached at a different root-relative ply.
    function automatic EvalScore tt_normalize_mate_score(input EvalScore score, input PlyIndex ply);
        automatic logic signed [16:0] score_wide = $signed({score[15], score});
        automatic logic signed [16:0] ply_wide = $signed({1'b0, ply});
        if (score >= MATE_THRESHOLD) return EvalScore'(score_wide + ply_wide);
        if (score <= -MATE_THRESHOLD) return EvalScore'(score_wide - ply_wide);
        return score;
    endfunction : tt_normalize_mate_score

    function automatic EvalScore tt_restore_mate_score(input EvalScore score, input PlyIndex ply);
        automatic logic signed [16:0] score_wide = $signed({score[15], score});
        automatic logic signed [16:0] ply_wide = $signed({1'b0, ply});
        if (score >= MATE_THRESHOLD) return EvalScore'(score_wide - ply_wide);
        if (score <= -MATE_THRESHOLD) return EvalScore'(score_wide + ply_wide);
        return score;
    endfunction : tt_restore_mate_score

    // All TT backends use the same single-entry depth/age replacement policy.
    function automatic logic tt_should_replace(
        input logic old_valid,
        input logic old_key_matches,
        input TTAge old_age,
        input TTDepth old_depth,
        input TTBoundType old_bound_type,
        input TTAge new_age,
        input TTDepth new_depth,
        input TTBoundType new_bound_type
    );
        automatic logic stale_with_depth_window;
        automatic logic exact_over_non_exact;

        stale_with_depth_window = (old_age != new_age)
            && (({1'b0, new_depth} + 7'd4) >= {1'b0, old_depth});
        exact_over_non_exact = (new_bound_type == TT_BOUND_EXACT)
            && (old_bound_type != TT_BOUND_EXACT)
            && (new_depth == old_depth);
        return !old_valid || !old_key_matches || stale_with_depth_window
            || new_depth >= old_depth || exact_over_non_exact;
    endfunction : tt_should_replace

    function automatic TTEntry tt_invalid_entry();
        automatic TTEntry entry;

        entry.verify_key = TTVerifyKey'(0);
        entry.best_move_bits = TTMoveBits'(0);
        entry.score = DRAW_EVAL_SCORE;
        entry.depth = TTDepth'(0);
        entry.bound_type = TT_BOUND_INVALID;
        entry.age = TTAge'(0);
        return entry;
    endfunction : tt_invalid_entry

    function automatic TTEntry tt_make_entry(
        input ZobristKey zobrist_key,
        input Move best_move,
        input EvalScore score,
        input TTDepth depth,
        input TTBoundType bound_type,
        input TTAge age
    );
        automatic TTEntry entry;

        entry.verify_key = tt_verify_key(zobrist_key);
        entry.best_move_bits = tt_encode_move(best_move);
        entry.score = score;
        entry.depth = depth;
        entry.bound_type = bound_type;
        entry.age = age;
        return entry;
    endfunction : tt_make_entry

    function automatic TTPhysicalEntry tt_pack_entry(input TTEntry entry);
        automatic TTPhysicalEntry physical;

        physical = '0;
        physical[47:0] = entry.verify_key;
        physical[61:48] = entry.best_move_bits;
        physical[79:64] = entry.score;
        physical[85:80] = entry.depth;
        physical[87:86] = entry.bound_type;
        physical[95:88] = entry.age;
        return physical;
    endfunction : tt_pack_entry

    function automatic TTEntry tt_unpack_entry(input TTPhysicalEntry physical);
        automatic TTEntry entry;

        entry.verify_key = physical[47:0];
        entry.best_move_bits = physical[61:48];
        entry.score = EvalScore'(physical[79:64]);
        entry.depth = TTDepth'(physical[85:80]);
        entry.bound_type = TTBoundType'(physical[87:86]);
        entry.age = TTAge'(physical[95:88]);
        return entry;
    endfunction : tt_unpack_entry

    function automatic TTFullEntry tt_invalid_full_entry();
        automatic TTFullEntry entry;

        entry.zobrist_key = ZobristKey'(0);
        entry.best_move_bits = TTMoveBits'(0);
        entry.score = DRAW_EVAL_SCORE;
        entry.depth = TTDepth'(0);
        entry.bound_type = TT_BOUND_INVALID;
        entry.age = TTAge'(0);
        entry.aux = TTAux'(0);
        return entry;
    endfunction : tt_invalid_full_entry

    function automatic TTFullEntry tt_make_full_entry(
        input ZobristKey zobrist_key,
        input Move best_move,
        input EvalScore score,
        input TTDepth depth,
        input TTBoundType bound_type,
        input TTAge age,
        input TTAux aux
    );
        automatic TTFullEntry entry;

        entry.zobrist_key = zobrist_key;
        entry.best_move_bits = tt_encode_move(best_move);
        entry.score = score;
        entry.depth = depth;
        entry.bound_type = bound_type;
        entry.age = age;
        entry.aux = aux;
        return entry;
    endfunction : tt_make_full_entry

endpackage : tt_defs
