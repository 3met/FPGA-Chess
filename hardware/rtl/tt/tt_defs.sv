// By Emet Behrendt

package tt_defs;

    import general_chess_defs::*;

    localparam int TT_DEFAULT_TAG_BITS = 32;
    localparam int TT_HASH_BITS = 32;
    localparam int TT_DEPTH_BITS = (MAX_PLY_COUNT <= 1) ? 1 : $clog2(MAX_PLY_COUNT);
    localparam int TT_ENTRY_PAYLOAD_BITS = $bits(Move) + $bits(EvalScore)
        + TT_DEPTH_BITS + 2 + 5;
    localparam int TT_COMPACT_ENTRY_BITS = TT_DEFAULT_TAG_BITS + TT_ENTRY_PAYLOAD_BITS;
    localparam int TT_FULL_ENTRY_BITS = $bits(ZobristKey) + TT_ENTRY_PAYLOAD_BITS + 16;
    localparam int TT_ENTRY_BITS = TT_COMPACT_ENTRY_BITS;
    localparam int TT_AGE_BITS = 5;
    localparam int TT_AUX_BITS = 16;

    // Bit 14 separates finite evaluations from mates. The 0x100 score gap
    // represents distances through 256 plies (mate in at least 128 moves).
    localparam EvalScore MATE_THRESHOLD = EvalScore'(16'h4000);
    localparam EvalScore MATE_SCORE = EvalScore'(16'h4100);

    typedef logic [TT_DEPTH_BITS-1:0] TTDepth;
    typedef logic [TT_AGE_BITS-1:0] TTAge;
    typedef logic [TT_AUX_BITS-1:0] TTAux;
    typedef logic [TT_DEFAULT_TAG_BITS-1:0] TTTag;
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

    localparam int TT_WORD_BITS = 16;
    localparam int TT_PHYSICAL_ENTRY_BITS =
        ((TT_COMPACT_ENTRY_BITS + TT_WORD_BITS - 1) / TT_WORD_BITS) * TT_WORD_BITS;
    localparam int TT_WORDS_PER_ENTRY = TT_PHYSICAL_ENTRY_BITS / TT_WORD_BITS;
    localparam int TT_EXTERNAL_WORD_ADDR_BITS = 25;
    localparam int TT_EXTERNAL_WORD_COUNT = 1 << TT_EXTERNAL_WORD_ADDR_BITS;
    localparam int TT_EXTERNAL_ENTRY_COUNT = TT_EXTERNAL_WORD_COUNT / TT_WORDS_PER_ENTRY;

    typedef logic [TT_PHYSICAL_ENTRY_BITS-1:0] TTPhysicalEntry;
    typedef logic [TT_EXTERNAL_WORD_ADDR_BITS-1:0] TTWordAddress;

    typedef struct packed {
        TTAge age;
        TTBoundType bound_type;
        TTDepth depth;
        EvalScore score;
        TTMoveBits best_move_bits;
        TTTag tag;
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

    function automatic TTTag tt_tag(input ZobristKey zobrist_key);
        return TTTag'(zobrist_key);
    endfunction : tt_tag

    // Zobrist keys are already uniformly distributed, so an XOR fold followed
    // by an invertible xorshift avalanche provides a strong index hash without
    // consuming a multiplier. Callers range-reduce this value when needed.
    function automatic logic [TT_HASH_BITS-1:0] tt_index_hash(
        input ZobristKey zobrist_key,
        input int unsigned tag_bits
    );
        logic [TT_HASH_BITS-1:0] folded;
        logic [TT_HASH_BITS-1:0] mixed;

        folded = '0;
        for (int bit_index = 0; bit_index < $bits(ZobristKey); bit_index++) begin
            if (bit_index >= tag_bits)
                folded[(bit_index - tag_bits) % TT_HASH_BITS] ^=
                    zobrist_key[bit_index];
        end
        mixed = folded;
        mixed ^= mixed << 13;
        mixed ^= mixed >> 17;
        mixed ^= mixed << 5;
        return mixed;
    endfunction : tt_index_hash

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
        input TTBoundType new_bound_type,
        input int unsigned stale_depth_tolerance
    );
        automatic logic stale_with_depth_window;
        automatic logic equal_depth_allowed;

        stale_with_depth_window = (old_age != new_age)
            && ((int'(new_depth) + stale_depth_tolerance) >= int'(old_depth));
        // At equal depth, preserve an exact result against a later bound while
        // still allowing another exact result or bound to refresh its peer.
        equal_depth_allowed = (new_depth == old_depth)
            && ((old_bound_type != TT_BOUND_EXACT)
                || (new_bound_type == TT_BOUND_EXACT));
        return !old_valid || !old_key_matches || stale_with_depth_window
            || new_depth > old_depth || equal_depth_allowed;
    endfunction : tt_should_replace

    function automatic TTEntry tt_invalid_entry();
        automatic TTEntry entry;

        entry.tag = TTTag'(0);
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

        entry.tag = tt_tag(zobrist_key);
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
        physical[TT_COMPACT_ENTRY_BITS-1:0] = entry;
        return physical;
    endfunction : tt_pack_entry

    function automatic TTEntry tt_unpack_entry(input TTPhysicalEntry physical);
        automatic TTEntry entry;

        entry = TTEntry'(physical[TT_COMPACT_ENTRY_BITS-1:0]);
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
