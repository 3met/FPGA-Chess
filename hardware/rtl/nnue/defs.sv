package nnue_defs;

    import chess_defs::*;

    localparam int NNUE_CACHE_ENTRIES = rtl_config::NNUE_CACHE_ENTRIES;
    typedef logic [$clog2(NNUE_CACHE_ENTRIES)-1:0] NnueSlot;

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
    localparam int NNUE_ACCUMULATOR_BIAS_BITS = 6;
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
    // Six-bit square remainders and quotients are small LUTs; no runtime
    // divider belongs on the feature-collection path.
    function automatic logic [1:0] nnue_square_mod3(input logic [5:0] square);
        case (square)
            6'd0, 6'd3, 6'd6, 6'd9, 6'd12, 6'd15, 6'd18, 6'd21, 6'd24, 6'd27, 6'd30, 6'd33, 6'd36, 6'd39, 6'd42, 6'd45, 6'd48, 6'd51, 6'd54, 6'd57, 6'd60, 6'd63: return 2'd0;
            6'd1, 6'd4, 6'd7, 6'd10, 6'd13, 6'd16, 6'd19, 6'd22, 6'd25, 6'd28, 6'd31, 6'd34, 6'd37, 6'd40, 6'd43, 6'd46, 6'd49, 6'd52, 6'd55, 6'd58, 6'd61: return 2'd1;
            default: return 2'd2;
        endcase
    endfunction
    function automatic logic [4:0] nnue_square_div3(input logic [5:0] square);
        case (square)
            6'd0, 6'd1, 6'd2: return 5'd0;
            6'd3, 6'd4, 6'd5: return 5'd1;
            6'd6, 6'd7, 6'd8: return 5'd2;
            6'd9, 6'd10, 6'd11: return 5'd3;
            6'd12, 6'd13, 6'd14: return 5'd4;
            6'd15, 6'd16, 6'd17: return 5'd5;
            6'd18, 6'd19, 6'd20: return 5'd6;
            6'd21, 6'd22, 6'd23: return 5'd7;
            6'd24, 6'd25, 6'd26: return 5'd8;
            6'd27, 6'd28, 6'd29: return 5'd9;
            6'd30, 6'd31, 6'd32: return 5'd10;
            6'd33, 6'd34, 6'd35: return 5'd11;
            6'd36, 6'd37, 6'd38: return 5'd12;
            6'd39, 6'd40, 6'd41: return 5'd13;
            6'd42, 6'd43, 6'd44: return 5'd14;
            6'd45, 6'd46, 6'd47: return 5'd15;
            6'd48, 6'd49, 6'd50: return 5'd16;
            6'd51, 6'd52, 6'd53: return 5'd17;
            6'd54, 6'd55, 6'd56: return 5'd18;
            6'd57, 6'd58, 6'd59: return 5'd19;
            6'd60, 6'd61, 6'd62: return 5'd20;
            default: return 5'd21;
        endcase
    endfunction
    function automatic int nnue_feature_bank(input NnueFeatureIndex feature);
        automatic logic [1:0] remainder = nnue_square_mod3(feature[5:0]);
        if (feature >= 10'd384) begin
            case (remainder)
                0: return 1;
                1: return 2;
                default: return 0;
            endcase
        end
        return int'(remainder);
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
                return int'(base + 8'(nnue_square_div3(square - 6'd8)));
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
        return int'(base + 8'(nnue_square_div3(square)));
    endfunction

    typedef struct packed {
        ThreadID thread_id;
        PlyIndex ply;
        // Physical snapshot addresses are supplied by the search cache controller.
        NnueSlot source_slot;
        NnueSlot destination_slot;
        // Logical cache operations; the arithmetic evaluator only uses copy.
        logic copy;
        NnueFeatureIndex white_feature;
        NnueFeatureIndex black_feature;
        // False denotes an ordered completion marker with no accumulator write.
        // Feature deltas and zero-delta copies update both perspectives together.
        // Consecutive move or square-replacement deltas form one transaction.
        logic combine;
        logic apply;
        logic add;
        // Marks the last physical request belonging to one child-state update.
        logic complete;
    } NnueUpdateRequest;

endpackage : nnue_defs
