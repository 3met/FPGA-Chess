
package board_controller_defs;

	import general_chess_defs::*;

    // Enum for all board controller operations
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
		Position start_pos;         // Move start position
		Position end_pos;           // Move end position
		PieceType killed_piece;     // Stores NULL_PIECE if nothing is killed (all NULL for en passant kills)
		CastlePerms castle_perms;   // Castle perms before move
		MoveFlag move_flag;         // Flag indicating special moves
		logic has_ep;               // Position contains an en passant kill tile
		BoardFile ep_file;          // En passant file
		HalfMoveClk halfmove_clk; // Halfmove clock before 
	} MoveRecord;	// 32 bits total

    // ---- Struct to store data passed down pipeline ----
    typedef struct packed {
        // Pipeline Inputs
        BoardOp board_op;
        FullBoard board;
        BoardHash board_hash;
        EvalScore pst_eval;
        Move move;
        logic [3:0] set_data; // Either a tile, turn, castle perms, or en passant info depending on the SET operation
        ThreadID thread_id;

        // Pipeline Internal Values
        MoveRecord move_record;
        logic is_castle;
        logic is_ep;
    } BoardControllerCtx;

endpackage
