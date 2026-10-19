// By Emet Behrendt

package tt_defs;

    import chess_defs::*;

    localparam int TT_DEFAULT_TAG_BITS = 32;
    localparam int TT_HASH_BITS = 32;
    localparam int TT_WAYS = 3;
    localparam int TT_DEPTH_BITS = $bits(PlyIndex);
    localparam int TT_AGE_BITS = 5;

    // Mate in one is immediately below infinity; the band ends at 255 plies.
    localparam EvalScore MATE_THRESHOLD = MAX_NON_MATE_EVAL_SCORE + EvalScore'(1);
    localparam EvalScore MATE_SCORE = MAX_EVAL_SCORE - EvalScore'(1);

    // Shared FSM type keeps profiler decoding tied to the implementation.
    typedef enum logic [1:0] { TT_FRONTEND_IDLE, TT_FRONTEND_DRAIN, TT_FRONTEND_CLEAR_WAIT, TT_FRONTEND_CACHE_CLEAR } TTFrontendState;

    typedef logic [TT_DEPTH_BITS-1:0] TTDepth;
    typedef logic [TT_AGE_BITS-1:0] TTAge;
    // Equal source/destination encodes no move; decoded promotions are queens.
    typedef logic [2*$bits(Position)-1:0] TTMoveBits;

    typedef enum logic [1:0] {
        TT_BOUND_INVALID,
        TT_BOUND_EXACT,
        TT_BOUND_LOWER,
        TT_BOUND_UPPER
    } TTBoundType;

    localparam int TT_ENTRY_PAYLOAD_BITS = $bits(TTMoveBits) + $bits(EvalScore)
        + $bits(TTDepth) + $bits(TTBoundType) + $bits(TTAge);
    localparam int TT_COMPACT_ENTRY_BITS = TT_DEFAULT_TAG_BITS + TT_ENTRY_PAYLOAD_BITS;
    localparam int TT_WORD_BITS = 16;
    localparam int TT_PHYSICAL_ENTRY_BITS =
        ((TT_COMPACT_ENTRY_BITS + TT_WORD_BITS - 1) / TT_WORD_BITS) * TT_WORD_BITS;
    localparam int TT_WORDS_PER_WAY = TT_PHYSICAL_ENTRY_BITS / TT_WORD_BITS;
    localparam int TT_WORDS_PER_ENTRY = TT_WAYS * TT_WORDS_PER_WAY;
    localparam int TT_EXTERNAL_WORD_ADDR_BITS = 25;
    localparam int TT_EXTERNAL_WORD_COUNT = 1 << TT_EXTERNAL_WORD_ADDR_BITS;
    localparam int TT_EXTERNAL_ENTRY_COUNT = 2 * (TT_EXTERNAL_WORD_COUNT / TT_WORDS_PER_ENTRY / 2);
    // The length channel covers every legal tag width without board constants.
    localparam int TT_BURST_BITS = $clog2(TT_WAYS *
        ((63 + TT_ENTRY_PAYLOAD_BITS + TT_WORD_BITS - 1) / TT_WORD_BITS) + 1);
    typedef logic [TT_BURST_BITS-1:0] TTBurstLength;
    typedef logic [TT_PHYSICAL_ENTRY_BITS-1:0] TTPhysicalEntry;
    typedef logic [TT_EXTERNAL_WORD_ADDR_BITS-1:0] TTWordAddress;

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
        return {move.from_pos, move.to_pos};
    endfunction : tt_encode_move

    function automatic Move tt_decode_move(input TTMoveBits move_bits);
        return Move'({move_bits, PROMO_QUEEN});
    endfunction : tt_decode_move

    // Mate-distance conversion saturates within the mate band, retaining its class.
    function automatic EvalScore clamp_mate_score(input logic signed [16:0] score, input logic winning);
        if (winning) begin
            if (score > 17'(MATE_SCORE)) return MATE_SCORE;
            if (score < 17'(MATE_THRESHOLD)) return MATE_THRESHOLD;
        end else begin
            if (score < 17'(-MATE_SCORE)) return -MATE_SCORE;
            if (score > 17'(-MATE_THRESHOLD)) return -MATE_THRESHOLD;
        end
        return EvalScore'(score);
    endfunction

    // Store mate scores relative to the node so entries remain valid when the
    // same position is reached at a different root-relative ply.
    function automatic EvalScore tt_normalize_mate_score(input EvalScore score, input PlyIndex ply);
        automatic logic signed [16:0] score_wide = $signed({score[$bits(EvalScore)-1], score});
        automatic logic signed [16:0] ply_wide = $signed({1'b0, ply});
        if (score == MAX_EVAL_SCORE || score == MIN_EVAL_SCORE) return score;
        if (score >= MATE_THRESHOLD) return clamp_mate_score(score_wide + ply_wide, 1'b1);
        if (score <= -MATE_THRESHOLD) return clamp_mate_score(score_wide - ply_wide, 1'b0);
        return score;
    endfunction : tt_normalize_mate_score

    function automatic EvalScore tt_restore_mate_score(input EvalScore score, input PlyIndex ply);
        automatic logic signed [16:0] score_wide = $signed({score[$bits(EvalScore)-1], score});
        automatic logic signed [16:0] ply_wide = $signed({1'b0, ply});
        if (score == MAX_EVAL_SCORE || score == MIN_EVAL_SCORE) return score;
        if (score >= MATE_THRESHOLD) return clamp_mate_score(score_wide - ply_wide, 1'b1);
        if (score <= -MATE_THRESHOLD) return clamp_mate_score(score_wide + ply_wide, 1'b0);
        return score;
    endfunction : tt_restore_mate_score

    // A matching position retains the existing depth/age preference policy.
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

endpackage : tt_defs
