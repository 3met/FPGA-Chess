// Search implementation types shared by the controller, helpers, and monitors.
package search_defs;
    import chess_defs::*;

    // Preserve explicit state widths and ordering for instrumentation.
    typedef enum logic [4:0] {
        CTRL_IDLE,
        CTRL_BOARD_ISSUE,
        CTRL_BOARD_WAIT,
        CTRL_DIRECT_DONE,
        CTRL_NEW_CLEAR_START,
        CTRL_NEW_CLEAR_WAIT,
        CTRL_PERFT_GEN_ISSUE,
        CTRL_PERFT_GEN_WAIT,
        CTRL_PERFT_PUSH_ISSUE,
        CTRL_PERFT_PUSH_WAIT,
        CTRL_PERFT_REVERSE_ISSUE,
        CTRL_PERFT_REVERSE_WAIT,
        CTRL_SEARCH_TIME_SETUP,
        CTRL_SEARCH_TIME_WAIT,
        CTRL_REPETITION_INIT,
        CTRL_REPETITION_ROOT_WAIT,
        CTRL_SEARCH_ITER_START,
        CTRL_SEARCH_ROOT_INIT,
        CTRL_SEARCH_RUN,
        CTRL_RESPOND,
        CTRL_FLUSH_RESPOND,
        CTRL_SEARCH_DRAIN,
        CTRL_NNUE_SETUP_START
    } SearchControllerState;

    typedef enum logic [3:0] {
        SEARCH_PHASE_IDLE,
        SEARCH_PHASE_READY,
        SEARCH_PHASE_TT_WAIT,
        SEARCH_PHASE_EVAL_WAIT,
        SEARCH_PHASE_MOVE_WAIT,
        SEARCH_PHASE_BOARD_WAIT,
        SEARCH_PHASE_REVERSE_WAIT,
        SEARCH_PHASE_REPETITION_WAIT,
        SEARCH_PHASE_STORE_PUBLISH,
        SEARCH_PHASE_TERMINAL_WAIT,
        SEARCH_PHASE_DONE,
        SEARCH_PHASE_TIME_SCALE,
        SEARCH_PHASE_TIME_SCALE_WAIT,
        SEARCH_PHASE_TIME_CHECK
    } SearchThreadPhase;

    // Metadata travels together while pending and in-flight ownership stays separate.
    typedef struct packed {
        PlyIndex child_ply;
        Position from_pos;
        Position to_pos;
        Position capture_pos;
        Tile mover;
        Tile placed;
        Tile capture;
        logic capture_valid;
        logic real_move;
        logic reverse;
        logic copy;
    } SearchNnuePlan;

    // Standard chess never captures a king; the spare piece code marks en
    // passant so the capture square and pawn feature need no separate storage.
    localparam PieceType NNUE_CAPTURE_EP = SPARE_PIECE;
    typedef struct packed {
        PieceType mover;
        PieceType capture_kind;
    } SearchNnueUndo;

    // Expand the per-ply undo metadata using the entering move and restored
    // parent's turn. This feeds the existing plan register without extra reads.
    function automatic SearchNnuePlan nnue_undo_plan(
        input Move move,
        input SearchNnueUndo undo,
        input Color mover_color,
        input PlyIndex parent_ply
    );
        SearchNnuePlan plan;
        plan = '0;
        plan.child_ply = parent_ply;
        plan.from_pos = move.from_pos;
        plan.to_pos = move.to_pos;
        plan.mover = Tile'({mover_color, undo.mover});
        plan.placed = plan.mover;
        if (undo.mover == PAWN
                && (move.to_pos[5:3] == BoardRank'(0)
                    || move.to_pos[5:3] == BoardRank'(7))) begin
            unique case (move.promo_piece)
                PROMO_QUEEN: plan.placed.piece_type = QUEEN;
                PROMO_KNIGHT: plan.placed.piece_type = KNIGHT;
                PROMO_ROOK: plan.placed.piece_type = ROOK;
                PROMO_BISHOP: plan.placed.piece_type = BISHOP;
            endcase
        end
        plan.capture_pos = undo.capture_kind == NNUE_CAPTURE_EP
            ? Position'({move.from_pos[5:3], move.to_pos[2:0]}) : move.to_pos;
        plan.capture_valid = undo.capture_kind != NULL_PIECE;
        plan.capture = Tile'({Color'(~mover_color),
            undo.capture_kind == NNUE_CAPTURE_EP ? PAWN : undo.capture_kind});
        plan.reverse = 1'b1;
        return plan;
    endfunction : nnue_undo_plan

    // Routing metadata retained until the corresponding evaluation returns.
    typedef struct packed {
        ThreadID thread_id;
        PlyIndex ply;
    } SearchPipelineTag;
endpackage : search_defs
