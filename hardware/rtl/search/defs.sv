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
        CTRL_FLUSH_RESPOND
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

    localparam logic NNUE_PLAN_DELTA = 1'b0;
    localparam logic NNUE_PLAN_REBUILD = 1'b1;

    // Metadata travels together while pending and in-flight ownership stays separate.
    typedef struct packed {
        logic kind;
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
    } SearchNnuePlan;

    // Routing metadata retained until the corresponding evaluation returns.
    typedef struct packed {
        ThreadID thread_id;
        PlyIndex ply;
    } SearchPipelineTag;
endpackage : search_defs
