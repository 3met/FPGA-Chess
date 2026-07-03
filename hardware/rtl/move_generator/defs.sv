// By Emet Behrendt

// Package for definitions relating to the move generator.
package move_generator_defs;

    import general_chess_defs::*;

    localparam MOVE_GEN_STAGE_CNT = 11;

    // -- Define Move Generator Operations --
    typedef enum {
        MOVE_GEN_IDLE_OP,
        MOVE_GEN_NORMAL_OP,
        MOVE_GEN_TARGETED_OP,
        MOVE_GEN_QSEARCH_OP
    } MoveGenOp;

    typedef struct packed {
        Color piece_color;
        logic has_knight;
        logic has_king_or_major;
    } KnightBusData;

    localparam int NORMAL_MOVE_MASK_BITS = 378;
    localparam int PROMOTION_EDGE_COUNT = 44;
    localparam int PROMOTION_MASK_BITS = PROMOTION_EDGE_COUNT * 4;
    localparam int CASTLING_MASK_BITS = 4;
    localparam int MOVE_MASK_BITS = NORMAL_MOVE_MASK_BITS + PROMOTION_MASK_BITS + CASTLING_MASK_BITS;
    localparam int NS_MASK_OFFSET = 0;
    localparam int EW_MASK_OFFSET = 56;
    localparam int POS_DIAG_MASK_OFFSET = 112;
    localparam int NEG_DIAG_MASK_OFFSET = 161;
    localparam int NNE_SSW_KNIGHT_MASK_OFFSET = 210;
    localparam int NEE_SWW_KNIGHT_MASK_OFFSET = 252;
    localparam int SEE_NWW_KNIGHT_MASK_OFFSET = 294;
    localparam int SSE_NNW_KNIGHT_MASK_OFFSET = 336;
    localparam int PROMOTION_MASK_OFFSET = NORMAL_MOVE_MASK_BITS;
    localparam int CASTLING_MASK_OFFSET = PROMOTION_MASK_OFFSET + PROMOTION_MASK_BITS;

    typedef logic [MOVE_MASK_BITS-1:0] MoveMask;
    typedef logic [$clog2(MOVE_MASK_BITS)-1:0] MoveMaskIndex;

    typedef logic [3:0] MovePriority;
    localparam MovePriority NULL_MOVE_PRIORITY = MovePriority'('d0);
    localparam MovePriority UNKNOWN_MOVE_PRIORITY = MovePriority'('dx);
    localparam MovePriority MAX_MOVE_PRIORITY = MovePriority'(4'd15);

endpackage : move_generator_defs
