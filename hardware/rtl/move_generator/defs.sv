// By Emet Behrendt

// Package for definitions relating to the move generator.
package move_generator_defs;

    import general_chess_defs::*;

    localparam int PROP_STAGE_CNT = 3;
    localparam int REDUCE_STAGE_CNT = 2;
    localparam int MOVE_GEN_STAGE_CNT = PROP_STAGE_CNT + 1 + REDUCE_STAGE_CNT + 1;

    // -- Define Move Generator Operations --
    typedef enum logic [1:0] {
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

    // Sliding edges are directed so opposite-direction moves cannot alias.
    localparam int NORMAL_MOVE_MASK_BITS = 588;
    localparam int PROMOTION_EDGE_COUNT = 22;
    localparam int PROMOTION_MASK_BITS = PROMOTION_EDGE_COUNT * 4;
    localparam int CASTLING_MASK_BITS = 2;
    localparam int MOVE_MASK_BITS = NORMAL_MOVE_MASK_BITS + PROMOTION_MASK_BITS + CASTLING_MASK_BITS;
    localparam int NS_MASK_OFFSET = 0;
    localparam int EW_MASK_OFFSET = 112;
    localparam int POS_DIAG_MASK_OFFSET = 224;
    localparam int NEG_DIAG_MASK_OFFSET = 322;
    localparam int NNE_SSW_KNIGHT_MASK_OFFSET = 420;
    localparam int NEE_SWW_KNIGHT_MASK_OFFSET = 462;
    localparam int SEE_NWW_KNIGHT_MASK_OFFSET = 504;
    localparam int SSE_NNW_KNIGHT_MASK_OFFSET = 546;
    localparam int PROMOTION_MASK_OFFSET = NORMAL_MOVE_MASK_BITS;
    localparam int CASTLING_MASK_OFFSET = PROMOTION_MASK_OFFSET + PROMOTION_MASK_BITS;

    typedef logic [MOVE_MASK_BITS-1:0] MoveMask;
    typedef logic [$clog2(MOVE_MASK_BITS)-1:0] MoveMaskIndex;

    typedef logic [3:0] MovePriority;
    localparam MovePriority NULL_MOVE_PRIORITY = MovePriority'('d0);
    localparam MovePriority UNKNOWN_MOVE_PRIORITY = MovePriority'('dx);
    localparam MovePriority MAX_MOVE_PRIORITY = MovePriority'(4'd15);

    typedef struct packed {
        Tile tile;
        logic [2:0] distance;
    } RayRecord;

    typedef logic [4:0] MoveScore;

    typedef struct packed {
        logic valid;
        Move move;
        MoveScore score;
        logic king_safe;
    } CandidateProposal;

    localparam RayRecord NULL_RAY = RayRecord'({EMPTY_TILE, 3'd0});
    localparam CandidateProposal NULL_PROPOSAL = CandidateProposal'({
        1'b0,
        Move'('x),
        MoveScore'('x),
        1'bx
    });

endpackage : move_generator_defs
