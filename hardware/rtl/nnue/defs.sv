package nnue_defs;

    import chess_defs::*;

    localparam int NNUE_SIDE_COUNT = 2;
    localparam int NNUE_PIECE_CATEGORY_COUNT = 6;
    localparam int NNUE_FEATURE_COUNT = NNUE_SIDE_COUNT * NNUE_PIECE_CATEGORY_COUNT * 64;
    localparam int NNUE_ACCUMULATOR_COUNT = 256;
    localparam int NNUE_FEATURE_WEIGHT_BITS = 2;
    localparam int NNUE_FEATURE_ROW_BITS =
        NNUE_ACCUMULATOR_COUNT * NNUE_FEATURE_WEIGHT_BITS;
    localparam int NNUE_ROW_BYTES = NNUE_FEATURE_ROW_BITS / 8;
    localparam int NNUE_STATE_VALUE_COUNT = NNUE_SIDE_COUNT * NNUE_ACCUMULATOR_COUNT;
    localparam int NNUE_OUTPUT_INPUT_COUNT =
        NNUE_SIDE_COUNT * NNUE_ACCUMULATOR_COUNT;
    localparam int NNUE_OUTPUT_WEIGHT_BITS = 3;
    localparam int NNUE_OUTPUT_BIAS_BITS = 5;
    localparam int NNUE_OUTPUT_MAC_LANES = 128;
    localparam int NNUE_OUTPUT_MAC_CYCLES =
        (NNUE_OUTPUT_INPUT_COUNT + NNUE_OUTPUT_MAC_LANES - 1) / NNUE_OUTPUT_MAC_LANES;
    localparam int NNUE_OUTPUT_BUCKET_COUNT = 8;
    localparam int NNUE_OUTPUT_WEIGHT_ROW_COUNT =
        NNUE_OUTPUT_BUCKET_COUNT * NNUE_OUTPUT_MAC_CYCLES;
    typedef logic [$clog2(NNUE_OUTPUT_BUCKET_COUNT)-1:0] NnueOutputBucket;

    // Group four counts from the legal two-king minimum upward so the scarce
    // low-piece positions share heads; the final head covers 30 through 32.
    function automatic NnueOutputBucket nnue_output_bucket(input PieceCount piece_count);
        if (piece_count <= PieceCount'(2))
            return NnueOutputBucket'(0);
        return NnueOutputBucket'((piece_count - PieceCount'(2)) >> 2);
    endfunction

    typedef logic [9:0] NnueFeatureIndex;
    // Training penalizes values outside signed five-bit state. Modular updates
    // preserve exact inverse deltas if an extreme still wraps.
    localparam int NNUE_ACCUMULATOR_BITS = 5;
    localparam int NNUE_ACCUMULATOR_BIAS_BITS = 3;
    typedef logic signed [NNUE_ACCUMULATOR_BITS-1:0] NnueAccumulator;
    // Each perspective sees its own pieces first, followed by enemy pieces,
    // over six piece types and 64 vertically oriented squares: 2*6*64 rows.
    function automatic NnueFeatureIndex nnue_feature_index(
        input Position piece_square,
        input Tile piece,
        input Color perspective
    );
        automatic Position oriented_square = (perspective == WHITE)
            ? piece_square : Position'(piece_square ^ 6'b111000);
        automatic logic [3:0] category = piece.piece_color == perspective
            ? 4'(piece.piece_type - PAWN)
            : 4'(NNUE_PIECE_CATEGORY_COUNT + piece.piece_type - PAWN);
        return NnueFeatureIndex'(int'(category) * 64 + int'(oriented_square));
    endfunction

    typedef struct packed {
        ThreadID thread_id;
        PlyIndex ply;
        NnueFeatureIndex white_feature;
        NnueFeatureIndex black_feature;
        // False denotes an ordered completion marker with no accumulator write.
        // Real feature deltas always update both perspectives together.
        logic apply;
        logic add;
        logic clear;
        // Marks the last physical request belonging to one child-state update.
        logic complete;
    } NnueUpdateRequest;

endpackage : nnue_defs
