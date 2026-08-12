
// By Emet Behrendt

package board_update_pipeline_defs;

	import general_chess_defs::*;

    // Stage 0 captures the request and launches table reads, stage 1 aligns
    // their synchronous outputs, and stage 2 registers the transformed board.
    localparam BOARD_UPDATE_PIPELINE_STAGE_CNT = 3;

    // Enum for all board update pipeline operations
    typedef enum logic [3:0] {
        BOARD_PUSH_MOVE_OP,   // A move made during a search
        BOARD_COMMIT_MOVE_OP, // A move made to simply update the board
        BOARD_SET_TILE_OP,
        BOARD_SET_TURN_OP,
        BOARD_SET_CASTLE_PERMS_OP,
        BOARD_SET_EN_PASSANT_OP,
        BOARD_SET_HALFMOVE_CLOCK_OP,
        BOARD_REVERSE_MOVE_OP,
        BOARD_PUSH_NULL_OP,   // A synthetic null move made only by search
        BOARD_IDLE_OP
    } BoardOp;

    // Data Type to Identify Special Moves
    typedef enum logic [1:0] {
		NORM_MOVE,   // Move is a normal move
		PROMO_MOVE,  // Move is promotion
		EP_MOVE,     // Move is an en passant kill
		CASTLE_MOVE  // Move is a castle
	} MoveFlag;

	// ---- Data Type to store Move History ----
	typedef struct packed {
		Position from_pos;         // Move origin position
		Position to_pos;           // Move destination position
		PieceType killed_piece;     // Stores NULL_PIECE if nothing is killed (all NULL for en passant kills)
		CastlePerms castle_perms;   // Castle perms before move
		MoveFlag move_flag;         // Flag indicating special moves
		logic has_ep;               // Position contains an en passant kill tile
		BoardFile ep_file;          // En passant file
		HalfmoveClock halfmove_clock; // Halfmove clock before the move
	} MoveRecord;	// 32 bits total

    // ---- Struct to store data passed down pipeline ----
    typedef struct packed {
        // Pipeline Inputs
        BoardOp board_op;
        FullBoard board;
        ZobristKey zobrist_key;
        EvalScore pst_eval;
        PieceCount piece_count;
        Move move;
        logic [6:0] set_data; // Tile, turn, castle perms, en passant, or halfmove info depending on the SET operation
        ThreadID thread_id;
        PlyIndex search_ply;

        // Pipeline Internal Values
        MoveRecord move_record;
        Position mover_king_square;
        logic mover_in_check;
    } BoardUpdatePipelineCtx;

endpackage
