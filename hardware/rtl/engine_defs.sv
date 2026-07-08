// By Emet Behrendt

package engine_defs;

    import general_chess_defs::*;
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

    localparam logic [7:0] ENGINE_RESP_STATUS        = 8'h80;
    localparam logic [7:0] ENGINE_RESP_ACK           = 8'h81;
    localparam logic [7:0] ENGINE_RESP_SEARCH_RESULT = 8'h82;
    localparam logic [7:0] ENGINE_RESP_PERFT_RESULT  = 8'h83;
    localparam logic [7:0] ENGINE_RESP_ERROR         = 8'hff;

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

    typedef enum logic [3:0] {
        ENGINE_CTRL_IDLE,
        ENGINE_CTRL_DIRECT_BOARD,
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
        BoardOp direct_board_op;
        Move move;
        logic [6:0] board_wr_data;
        TimeType time_limit;
        TimeType wtime;
        TimeType btime;
        TimeType winc;
        TimeType binc;
        logic [7:0] depth_limit;
        NodeCountType node_limit;
    } EngineControllerRequest;

    typedef struct packed {
        logic error;
        Move best_move;
        EvalScore score;
        NodeCountType nodes_count;
        logic [7:0] completed_depth;
        logic [7:0] end_reason;
        logic [3:0] board_rd_data;
    } EngineControllerResponse;

endpackage : engine_defs
