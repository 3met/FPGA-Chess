// By Emet Behrendt

package engine_defs;

    import chess_defs::*;
    import board_update_pipeline_defs::*;

    localparam logic [7:0] ENGINE_CMD_GET_STATUS        = 8'h00;
    localparam logic [7:0] ENGINE_CMD_SET_BOARD         = 8'h01;
    localparam logic [7:0] ENGINE_CMD_MAKE_MOVE         = 8'h02;
    localparam logic [7:0] ENGINE_CMD_NEW_GAME          = 8'h04;
    localparam logic [7:0] ENGINE_CMD_SEARCH_DEPTH      = 8'h10;
    localparam logic [7:0] ENGINE_CMD_SEARCH_FIXED_TIME = 8'h11;
    localparam logic [7:0] ENGINE_CMD_SEARCH_ON_CLOCK   = 8'h12;
    localparam logic [7:0] ENGINE_CMD_SEARCH_NODES      = 8'h13;
    localparam logic [7:0] ENGINE_CMD_PERFT             = 8'h14;
    localparam logic [7:0] ENGINE_CMD_KILL              = 8'h1f;
    localparam logic [7:0] ENGINE_CMD_GET_SEARCH_RESULT = 8'h20;
    localparam logic [7:0] ENGINE_CMD_GET_DEBUG_STAT    = 8'h21;
    localparam logic [7:0] ENGINE_CMD_GET_BUILD_INFO    = 8'h22;

    localparam logic [7:0] ENGINE_RESP_STATUS        = 8'h80;
    localparam logic [7:0] ENGINE_RESP_ACK           = 8'h81;
    localparam logic [7:0] ENGINE_RESP_SEARCH_RESULT = 8'h82;
    localparam logic [7:0] ENGINE_RESP_PERFT_RESULT  = 8'h83;
    localparam logic [7:0] ENGINE_RESP_DEBUG_STAT    = 8'h84;
    localparam logic [7:0] ENGINE_RESP_BUILD_INFO    = 8'h85;
    localparam logic [7:0] ENGINE_RESP_ERROR         = 8'hff;

    localparam logic [7:0] ENGINE_STAT_ENABLED          = 8'd0;
    localparam logic [7:0] ENGINE_STAT_THREAD_COUNT     = 8'd1;
    localparam logic [7:0] ENGINE_STAT_PHASE_COUNT      = 8'd2;
    localparam logic [7:0] ENGINE_STAT_TT_LOOKUPS       = 8'd3;
    localparam logic [7:0] ENGINE_STAT_TT_HITS          = 8'd4;
    localparam logic [7:0] ENGINE_STAT_TT_CACHE_LOOKUPS = 8'd5;
    localparam logic [7:0] ENGINE_STAT_TT_CACHE_HITS    = 8'd6;
    localparam logic [7:0] ENGINE_STAT_PHASE_BASE       = 8'd16;
    localparam logic [7:0] ENGINE_STAT_MOVE_NOISY       = 8'd176;
    localparam logic [7:0] ENGINE_STAT_MOVE_QUIET       = 8'd177;
    localparam logic [7:0] ENGINE_STAT_MOVE_DESTINATIONS = 8'd178;
    localparam logic [7:0] ENGINE_STAT_MOVE_CANDIDATES  = 8'd179;
    localparam logic [7:0] ENGINE_STAT_HISTORY_LOOKUPS  = 8'd180;
    localparam logic [7:0] ENGINE_STAT_MOVE_GEN_CYCLES  = 8'd181;
    localparam logic [7:0] ENGINE_STAT_MOVE_OVERFLOW    = 8'd182;
    localparam logic [7:0] ENGINE_STAT_BUCKET_COUNT_BASE = 8'd200;
    localparam logic [7:0] ENGINE_STAT_BUCKET_HIGH_BASE = 8'd208;
    localparam logic [7:0] ENGINE_STAT_ACTIVE_PST_FIRST = 8'd240;
    localparam logic [7:0] ENGINE_STAT_ACTIVE_PST_ENDGAME = 8'd241;
    localparam int ENGINE_STAT_PHASE_COUNT_VALUE = 10;

    localparam logic [7:0] ENGINE_ERR_NONE              = 8'd0;
    localparam logic [7:0] ENGINE_ERR_UNKNOWN_OPCODE    = 8'd1;
    localparam logic [7:0] ENGINE_ERR_MALFORMED_PAYLOAD = 8'd2;
    localparam logic [7:0] ENGINE_ERR_RX_OVERFLOW       = 8'd3;
    localparam logic [7:0] ENGINE_ERR_UART_FRAMING      = 8'd4;
    localparam logic [7:0] ENGINE_ERR_INTERNAL          = 8'd5;

    localparam logic [7:0] ENGINE_END_NORMAL      = 8'd0;
    localparam logic [7:0] ENGINE_END_DEPTH_LIMIT = 8'd1;
    localparam logic [7:0] ENGINE_END_TIME_LIMIT  = 8'd2;
    localparam logic [7:0] ENGINE_END_NODE_LIMIT  = 8'd3;
    localparam logic [7:0] ENGINE_END_KILLED      = 8'd4;
    localparam logic [7:0] ENGINE_END_ERROR       = 8'd5;

    // Shared FSM type keeps profiler decoding tied to the implementation.
    typedef enum logic [2:0] {
        CMD_IDLE,
        CMD_RECEIVE_PAYLOAD,
        CMD_PROCESS_PAYLOAD,
        CMD_BOARD_UPDATE,
        CMD_ISSUE_REQUEST,
        CMD_WAIT_RESULT,
        CMD_ISSUE_KILL,
        CMD_OUTPUT
    } EngineState;

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

    typedef enum logic [3:0] {
        ENGINE_CTRL_IDLE,
        ENGINE_CTRL_BOARD_UPDATE,
        ENGINE_CTRL_NEW_GAME,
        ENGINE_CTRL_SEARCH_DEPTH,
        ENGINE_CTRL_SEARCH_FIXED_TIME,
        ENGINE_CTRL_SEARCH_ON_CLOCK,
        ENGINE_CTRL_SEARCH_NODES,
        ENGINE_CTRL_PERFT,
        ENGINE_CTRL_KILL
    } EngineControllerOp;

    typedef struct packed {
        EngineControllerOp operation;
        BoardOp board_op;
        Move move;
        logic [6:0] board_wr_data;
        TimeType time_limit;
        TimeType move_overhead;
        TimeType remaining_time;
        TimeType increment;
        logic [15:0] moves_to_go;
        logic [7:0] depth_limit;
        NodeCountType node_limit;
    } EngineControllerRequest;

    typedef struct packed {
        logic error;
        Move best_move;
        Move ponder_move;
        EvalScore score;
        NodeCountType nodes_count;
        logic [7:0] completed_depth;
        logic [7:0] end_reason;
    } EngineControllerResponse;

endpackage : engine_defs
