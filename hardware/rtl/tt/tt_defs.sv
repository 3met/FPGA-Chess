// By Emet Behrendt

package tt_defs;

    import general_chess_defs::*;

    localparam int TT_COMPACT_ENTRY_BITS = 96;
    localparam int TT_FULL_ENTRY_BITS = 128;
    localparam int TT_ENTRY_BITS = TT_COMPACT_ENTRY_BITS;
    localparam int TT_VERIFY_BITS = 48;
    localparam int TT_DEPTH_BITS = 6;
    localparam int TT_AGE_BITS = 8;
    localparam int TT_AUX_BITS = 16;

    localparam EvalScore MATE_SCORE = EvalScore'(32000);
    localparam EvalScore MATE_THRESHOLD = EvalScore'(31000);

    typedef logic [TT_DEPTH_BITS-1:0] TTDepth;
    typedef logic [TT_AGE_BITS-1:0] TTAge;
    typedef logic [TT_AUX_BITS-1:0] TTAux;
    typedef logic [TT_VERIFY_BITS-1:0] TTVerifyKey;
    typedef logic [15:0] TTMoveBits;

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
        ThreadID thread_id;
        logic hit;
        EvalScore score;
        TTBoundType bound_type;
        TTDepth depth;
        Move best_move;
        TTAge age;
    } TTLookupResponse;

    typedef struct packed {
        ThreadID thread_id;
        ZobristKey zobrist_key;
        TTDepth depth;
        EvalScore score;
        TTBoundType bound_type;
        Move best_move;
        TTAge age;
        PlyIndex ply;
    } TTStoreRequest;

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
        return {2'b00, move};
    endfunction : tt_encode_move

    function automatic Move tt_decode_move(input TTMoveBits move_bits);
        return Move'(move_bits[$bits(Move)-1:0]);
    endfunction : tt_decode_move

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
