package nnue_defs;

    import chess_defs::*;

    localparam int NNUE_SIDE_COUNT = 2;
    localparam int NNUE_PIECE_CATEGORY_COUNT = 6;
    localparam int NNUE_FEATURE_COUNT = NNUE_SIDE_COUNT * NNUE_PIECE_CATEGORY_COUNT * 64;
    parameter int NNUE_ACCUMULATOR_COUNT = 512;
    localparam int NNUE_FEATURE_WEIGHT_BITS = 2;
    localparam int NNUE_FEATURE_ROW_BITS =
        NNUE_ACCUMULATOR_COUNT * NNUE_FEATURE_WEIGHT_BITS;
    localparam int NNUE_ROW_BYTES = NNUE_FEATURE_ROW_BITS / 8;
    localparam int NNUE_STATE_VALUE_COUNT = NNUE_SIDE_COUNT * NNUE_ACCUMULATOR_COUNT;
    localparam int NNUE_ACTIVATION_BITS = 4;
    localparam int NNUE_OUTPUT_INPUT_COUNT =
        NNUE_SIDE_COUNT * NNUE_ACCUMULATOR_COUNT;
    localparam int NNUE_OUTPUT_WEIGHT_BITS = 4;
    localparam int NNUE_OUTPUT_BIAS_BITS = 6;
    // SCReLU is 0..15; retain every dot-product result before combining with PST.
    localparam int NNUE_CORRECTION_NEGATIVE_BOUND =
        NNUE_OUTPUT_INPUT_COUNT * 15 * (1 << (NNUE_OUTPUT_WEIGHT_BITS - 1));
    localparam int NNUE_CORRECTION_POSITIVE_BOUND =
        NNUE_OUTPUT_INPUT_COUNT * 15 * ((1 << (NNUE_OUTPUT_WEIGHT_BITS - 1)) - 1)
        + (1 << NNUE_OUTPUT_BIAS_BITS) - 1;
    localparam int NNUE_CORRECTION_BOUND =
        NNUE_CORRECTION_NEGATIVE_BOUND > NNUE_CORRECTION_POSITIVE_BOUND
        ? NNUE_CORRECTION_NEGATIVE_BOUND : NNUE_CORRECTION_POSITIVE_BOUND;
    typedef logic signed [$clog2(NNUE_CORRECTION_BOUND + 1):0] NnueCorrection;
    parameter int NNUE_OUTPUT_MAC_LANES = 256;
    localparam int NNUE_OUTPUT_MAC_CYCLES =
        (NNUE_OUTPUT_INPUT_COUNT + NNUE_OUTPUT_MAC_LANES - 1) / NNUE_OUTPUT_MAC_LANES;
    parameter int NNUE_OUTPUT_BUCKET_COUNT = 8;
    localparam int NNUE_OUTPUT_WEIGHT_ROW_COUNT =
        NNUE_OUTPUT_BUCKET_COUNT * NNUE_OUTPUT_MAC_CYCLES;
    typedef logic [(NNUE_OUTPUT_BUCKET_COUNT <= 1 ? 1 : $clog2(NNUE_OUTPUT_BUCKET_COUNT))-1:0] NnueOutputBucket;

    // The packed map is a parameter so alternate piece-count bucket boundaries
    // do not require a different datapath. Entries are ordered by piece count.
    localparam int NNUE_BUCKET_MAP_BITS = 33 * $bits(NnueOutputBucket);
    function automatic logic [NNUE_BUCKET_MAP_BITS-1:0] default_bucket_map();
        for (int count = 0; count <= 32; count++)
            default_bucket_map[count*$bits(NnueOutputBucket) +: $bits(NnueOutputBucket)]
                = NnueOutputBucket'(count <= 2 ? 0 : count >= 32
                    ? NNUE_OUTPUT_BUCKET_COUNT-1 : (count-2)*NNUE_OUTPUT_BUCKET_COUNT/32);
    endfunction
    parameter logic [NNUE_BUCKET_MAP_BITS-1:0] NNUE_OUTPUT_BUCKET_MAP = default_bucket_map();

    function automatic NnueOutputBucket nnue_output_bucket(input PieceCount piece_count);
        automatic int count = int'(piece_count) > 32 ? 32 : int'(piece_count);
        return NnueOutputBucket'(NNUE_OUTPUT_BUCKET_MAP[count*$bits(NnueOutputBucket) +: $bits(NnueOutputBucket)]);
    endfunction

    typedef logic [9:0] NnueFeatureIndex;
    // Training penalizes values outside signed six-bit state. Modular updates
    // preserve exact inverse deltas if an extreme still wraps.
    localparam int NNUE_ACCUMULATOR_BITS = 6;
    localparam int NNUE_ACCUMULATOR_BIAS_BITS = 4;
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

    // Opposing colors separate mover and victim on a capture square. Standard
    // castling and en passant also need at most two ports in each bank.
    function automatic int nnue_feature_bank(input NnueFeatureIndex feature);
        automatic logic [6:0] index = {1'b0, feature[5:0]} + 7'(feature >= 10'd384);
        return int'(index % 7'd3);
    endfunction

    localparam int NNUE_FEATURE_BANK_ROW_COUNT = 253;
    localparam int NNUE_ZERO_FEATURE_ROW = 0;
    // Reserve sixteen pawn entries and twenty-two per other piece per color.
    // Unreachable pawn end ranks alias a dedicated, permanently zero row.
    function automatic int nnue_feature_bank_row(input NnueFeatureIndex feature);
        automatic logic [5:0] square = feature[5:0];
        automatic logic [7:0] base;
        // Explicit category offsets avoid general integer divide/modulo logic
        // on the request-address path. Both quotient operands remain narrow.
        case (feature[9:6])
            4'd0, 4'd6: begin
                if (square < 6'd8 || square >= 6'd56) return NNUE_ZERO_FEATURE_ROW;
                base = feature[9:6] == 4'd0 ? 8'd1 : 8'd127;
                return int'(base + 8'((square - 6'd8) / 6'd3));
            end
            4'd1: base = 8'd17;
            4'd2: base = 8'd39;
            4'd3: base = 8'd61;
            4'd4: base = 8'd83;
            4'd5: base = 8'd105;
            4'd7: base = 8'd143;
            4'd8: base = 8'd165;
            4'd9: base = 8'd187;
            4'd10: base = 8'd209;
            4'd11: base = 8'd231;
            default: base = 8'd0;
        endcase
        return int'(base + 8'(square / 6'd3));
    endfunction

    typedef struct packed {
        ThreadID thread_id;
        PlyIndex ply;
        NnueFeatureIndex white_feature;
        NnueFeatureIndex black_feature;
        // False denotes an ordered completion marker with no accumulator write.
        // Real feature deltas always update both perspectives together.
        // Consecutive move deltas form one six-port transaction. Rebuild rows
        // are independent transactions and may stream an arbitrary piece count.
        logic combine;
        logic apply;
        logic add;
        logic clear;
        // Marks the last physical request belonging to one child-state update.
        logic complete;
    } NnueUpdateRequest;

endpackage : nnue_defs
