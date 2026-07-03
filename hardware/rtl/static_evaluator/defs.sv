package static_evaluator_defs;

    import general_chess_defs::*;

    localparam int STATIC_EVAL_PIPELINE_STAGE_CNT = 8;

    localparam EvalScore PAWN_SHIELD_BONUS = EvalScore'('d4);
    localparam EvalScore TRAPPED_BISHOP_PENALTY = EvalScore'('d4);
    localparam EvalScore OPEN_ROOK_FILE_BONUS = EvalScore'('d6);
    localparam EvalScore DOUBLED_PAWN_PENALTY = EvalScore'('d6);

    typedef logic [2:0] RayDistance;

    typedef struct packed {
        Tile piece;
        RayDistance empty_count;
    } DirectionScan;

endpackage : static_evaluator_defs
