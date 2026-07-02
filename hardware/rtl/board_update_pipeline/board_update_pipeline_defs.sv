
// By Emet Behrendt

package board_update_pipeline_defs;

	import general_chess_defs::*;

    localparam BOARD_UPDATE_PIPELINE_STAGE_CNT = 7;

    // Enum for all board update pipeline operations
    typedef enum {
        BOARD_PUSH_MOVE_OP,   // A move made during a search
        BOARD_COMMIT_MOVE_OP, // A move made to simply update the board
        BOARD_SET_TILE_OP,
        BOARD_SET_TURN_OP,
        BOARD_SET_CASTLE_PERMS_OP,
        BOARD_SET_EN_PASSANT_OP,
        BOARD_REVERSE_MOVE_OP,
        BOARD_IDLE_OP
    } BoardOp;

    // Data Type to Identify Special Moves
    typedef enum {
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
        Move move;
        logic [3:0] set_data; // Either a tile, turn, castle perms, or en passant info depending on the SET operation
        ThreadID thread_id;

        // Pipeline Internal Values
        MoveRecord move_record;
        logic is_castle;
        logic is_ep;
        logic is_pawn_move; // Used for halfmove clock
        logic overwritten_color_has_turn; // For SET TILE: Indicates if the overwritten tile belongs to the active player
    } BoardUpdatePipelineCtx;

endpackage
