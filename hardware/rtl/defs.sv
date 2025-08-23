
// By Emet Behrendt

// This file contains the engine_defs package which holds
// definitions of various basic datatypes, constants, and functions.

`ifndef ENGINE_INCLUDE_SV
`define ENGINE_INCLUDE_SV

// A Package for general chess/engine definitions
package general_chess_defs;

	// -- Data Type for Colors --
	typedef enum logic {
		WHITE, BLACK
	} Color;

	localparam Color UNKNOWN_COLOR = Color'(1'bx);


	// -- Data Type for Piece Types --
	typedef enum logic[2:0] {
		NULL_PIECE,
		PAWN,
		KNIGHT,
		BISHOP,
		ROOK,
		QUEEN,
		KING,
		SPARE_PIECE
	} PieceType;

	localparam PieceType UNKNOWN_PIECE = PieceType'(3'dx);

	// Value of each type of piece in units of pawns
	// Indexed by PieceType
	localparam logic[3:0] PIECE_VALS_1[8] = '{
		4'd0, 4'd1, 4'd3, 4'd3, 4'd5, 4'd9, 4'd12, 4'dx
	};

	// Value of each type of piece in units of 64th of a pawn
	// Indexed by PieceType
	// https://web.archive.org/web/20160314214435/http://www.danheisman.com/Articles/evaluation_of_material_imbalance.htm
	localparam logic[9:0] PIECE_VALS_64[8] = '{
		10'd0, 10'd64, 10'd208, 10'd208, 10'd320, 10'd576, 10'd1000, 10'dx
	};


	// -- Data Type for Pawn Promotion Types --
	typedef enum logic[1:0] {
		PROMO_QUEEN, PROMO_KNIGHT, PROMO_ROOK, PROMO_BISHOP
	} PromoType;

	localparam PromoType PROMO_UNKNOWN = PromoType'(2'dx);


	// -- Data Type for Castling Information --
	typedef struct packed {
		logic whiteKingside;
		logic whiteQueenside;
		logic blackKingside;
		logic blackQueenside;
	} CastlePerms;


	// -- Data Type for a Half-Move Clock --
	typedef logic [6:0] HalfMoveClk;


	// -- Data Types for Board Positioning --
	// Board Position (0-63)
	typedef logic [5:0] Position;

	// Board rank and file data types
	typedef logic [2:0] BoardRank;
	typedef logic [2:0] BoardFile;

	// Returns the rank from a given position
	function BoardRank getRank(input Position pos);
		return BoardRank'(pos[5:3]);
	endfunction

	// Returns the file from a given position
	function BoardFile getFile(input Position pos);
		return BoardFile'(pos[2:0]);
	endfunction

	// Returns the position from a given rank and file
	function Position getPosition(input BoardRank rank, input BoardFile file);
		return Position'({rank, file});
	endfunction


	// -- Data Type for a Move --
	typedef struct packed {
		Position start_pos;
		Position end_pos;
		PromoType promo_piece;
	} Move;

	// Define a "NULL" move
	localparam Move NULL_MOVE = Move'({6'd0, 6'd0, 2'dx});
	function logic isNullMove(Move m);
		return (m.start_pos == 6'd0 && m.end_pos == 6'd0 ? 1'b1 : 1'b0);
	endfunction


	// Defines a board tile
	typedef struct packed {
		Color piece_color;
		PieceType piece_type;
	} Tile;

	localparam Tile EMPTY_TILE   = Tile'({UNKNOWN_COLOR, NULL_PIECE});
	localparam Tile WHITE_PAWN   = Tile'({WHITE, PAWN});
	localparam Tile WHITE_KNIGHT = Tile'({WHITE, KNIGHT});
	localparam Tile WHITE_BISHOP = Tile'({WHITE, BISHOP});
	localparam Tile WHITE_ROOK   = Tile'({WHITE, ROOK});
	localparam Tile WHITE_QUEEN  = Tile'({WHITE, QUEEN});
	localparam Tile WHITE_KING   = Tile'({WHITE, KING});
	localparam Tile BLACK_PAWN   = Tile'({BLACK, PAWN});
	localparam Tile BLACK_KNIGHT = Tile'({BLACK, KNIGHT});
	localparam Tile BLACK_BISHOP = Tile'({BLACK, BISHOP});
	localparam Tile BLACK_ROOK   = Tile'({BLACK, ROOK});
	localparam Tile BLACK_QUEEN  = Tile'({BLACK, QUEEN});
	localparam Tile BLACK_KING   = Tile'({BLACK, KING});


	// Map position to rank
	localparam BoardRank BOARD_RANK[64] = '{
		7, 7, 7, 7, 7, 7, 7, 7,
		6, 6, 6, 6, 6, 6, 6, 6,
		5, 5, 5, 5, 5, 5, 5, 5,
		4, 4, 4, 4, 4, 4, 4, 4,
		3, 3, 3, 3, 3, 3, 3, 3,
		2, 2, 2, 2, 2, 2, 2, 2,
		1, 1, 1, 1, 1, 1, 1, 1,
		0, 0, 0, 0, 0, 0, 0, 0
	};

	// Map position to file
	localparam BoardFile BOARD_FILE[0:63] = '{
		0, 1, 2, 3, 4, 5, 6, 7,
		0, 1, 2, 3, 4, 5, 6, 7,
		0, 1, 2, 3, 4, 5, 6, 7,
		0, 1, 2, 3, 4, 5, 6, 7,
		0, 1, 2, 3, 4, 5, 6, 7,
		0, 1, 2, 3, 4, 5, 6, 7,
		0, 1, 2, 3, 4, 5, 6, 7,
		0, 1, 2, 3, 4, 5, 6, 7
	};

	// Map position to positive-sloped diagonal
	localparam logic[3:0] POSITIVE_DIAG[0:63] = '{
		0,	1,	2,	3,	4,	5,	6,	7,
		1,	2,	3,	4,	5,	6,	7,	8,
		2,	3,	4,	5,	6,	7,	8,	9,
		3,	4,	5,	6,	7,	8,	9,	10,
		4,	5,	6,	7,	8,	9,	10,	11,
		5,	6,	7,	8,	9,	10,	11,	12,
		6,	7,	8,	9,	10,	11,	12,	13,
		7,	8,	9,	10,	11,	12,	13,	14
	};
	
	// Map position to negative-sloped diagonal
	localparam logic[3:0] NEGATIVE_DIAG[0:63] = '{
		7,	8,	9,	10,	11,	12,	13,	14,
		6,	7,	8,	9,	10,	11,	12,	13,
		5,	6,	7,	8,	9,	10,	11,	12,
		4,	5,	6,	7,	8,	9,	10,	11,
		3,	4,	5,	6,	7,	8,	9,	10,
		2,	3,	4,	5,	6,	7,	8,	9,
		1,	2,	3,	4,	5,	6,	7,	8,
		0,	1,	2,	3,	4,	5,	6,	7
	};

	// Order in which the positions are displayed
	localparam logic[5:0] SHOW_ORDER[0:63] = '{
		56,	57,	58,	59,	60,	61,	62,	63,
		48,	49,	50,	51,	52,	53,	54,	55,
		40,	41,	42,	43,	44,	45,	46,	47,
		32,	33,	34,	35,	36,	37,	38,	39,
		24,	25,	26,	27,	28,	29,	30,	31,
		16,	17,	18,	19,	20,	21,	22,	23,
		8,	9,	10,	11,	12,	13,	14,	15,
		0,	1,	2,	3,	4,	5,	6,	7
	};


	// Maximum search depth
	// Ideally a power of two
	localparam MAX_PLY_COUNT = 8;

	// Data type to store search depth
	typedef logic [$clog2(MAX_PLY_COUNT)-1:0] DepthType;

	// Data type for a board hash
	typedef logic [31:0] BoardHash;


	// -- Evaluation Related Definitions --
	typedef logic signed [11:0] EvalScore;

	localparam EvalScore MAX_EVAL_SCORE = EvalScore'(2 ** ($bits(EvalScore)-1) - 1);
	localparam EvalScore MIN_EVAL_SCORE = -MAX_EVAL_SCORE;
	localparam EvalScore DRAW_EVAL_SCORE = EvalScore'(0);
	localparam EvalScore UNKNOWN_EVAL_SCORE = EvalScore'('dx);


	function string pieceToChar(Tile t);
		case (t)
			WHITE_PAWN:   return "P";
			WHITE_KNIGHT: return "N";
			WHITE_BISHOP: return "B";
			WHITE_ROOK:   return "R";
			WHITE_QUEEN:  return "Q";
			WHITE_KING:   return "K";
			BLACK_PAWN:   return "p";
			BLACK_KNIGHT: return "n";
			BLACK_BISHOP: return "b";
			BLACK_ROOK:   return "r";
			BLACK_QUEEN:  return "q";
			BLACK_KING:   return "k";
			default: return "X";
		endcase
	endfunction


	// -- Metric Tracking Definitions --
	// Tracking Time
	localparam TIME_BITS = 24;  // Ideally a multiple of 8
	typedef logic[TIME_BITS-1:0] TimeType;

	// Counting Nodes
	localparam NODE_COUNT_BITS = 40;  // Ideally a multiple of 8
	typedef logic[NODE_COUNT_BITS-1:0] NodeCountType;


	// -- Direction Related Definitions --

	// Defines board direction
	typedef enum logic[2:0] {
		NORTH, NORTH_EAST, EAST, SOUTH_EAST, SOUTH, SOUTH_WEST, WEST, NORTH_WEST
	} Direction;

	localparam Direction UNKNOWN_DIR = Direction'(3'bxxx);

	// Maps a direction to its opposite direction
	localparam Direction OPPOSITE_DIR[8] = '{
		SOUTH, SOUTH_WEST, WEST, NORTH_WEST, NORTH, NORTH_EAST, EAST, SOUTH_EAST
	};

	// List of Cardinal and diagonal directions for looping through
	localparam Direction CARDINAL_DIR[4] = '{NORTH, SOUTH, EAST, WEST};
	localparam Direction DIAG_DIR[4] = '{NORTH_EAST, SOUTH_EAST, SOUTH_WEST, NORTH_WEST};

	// Function returns true if direction is cardinal
	function logic isDirCardinal(Direction dir);
		return (dir==NORTH || dir==SOUTH || dir==EAST || dir==WEST);
	endfunction : isDirCardinal

	// Function returns true if direction is diagonal
	function logic isDirDiag(Direction dir);
		return (dir==NORTH_EAST || dir==SOUTH_EAST || dir==NORTH_WEST || dir==SOUTH_WEST);
	endfunction : isDirDiag

	// Position shift of one tile given a direction
	localparam logic[5:0] POS_SHIFT[8] = '{
		6'd8, 6'd9, 6'd1, -6'd7,
		-6'd8, -6'd9, -6'd1, 6'd7
	};

	// Position shift for in some direction for some distance [direction][distance]
	localparam logic[5:0] DIST_SHIFT[8][8] = '{
		'{6'd0,	6'd8,	6'd16,	6'd24,	6'd32,	6'd40,	6'd48,	6'd56},
		'{6'd0,	6'd9,	6'd18,	6'd27,	6'd36,	6'd45,	6'd54,	6'd63},
		'{6'd0,	6'd1,	6'd2,	6'd3,	6'd4,	6'd5,	6'd6,	6'd7},
		'{6'd0,	-6'd7,	-6'd14,	-6'd21,	-6'd28,	-6'd35,	-6'd42,	-6'd49},
		'{6'd0,	-6'd8,	-6'd16,	-6'd24,	-6'd32,	-6'd40,	-6'd48,	-6'd56},
		'{6'd0,	-6'd9,	-6'd18,	-6'd27,	-6'd36,	-6'd45,	-6'd54,	-6'd63},
		'{6'd0,	-6'd1,	-6'd2,	-6'd3,	-6'd4,	-6'd5,	-6'd6,	-6'd7},
		'{6'd0,	6'd7,	6'd14,	6'd21,	6'd28,	6'd35,	6'd42,	6'd49}
	};

	// Shift a position in some direction for some distance
	function Position shiftPos(Position pos, Direction dir, logic [2:0] distance);
		return Position'(pos + DIST_SHIFT[dir][distance]);
	endfunction : shiftPos

	// Takes a position, direaction, and distance as input
	// Outputs if shifting starting from pos in the given dir for the given distance
	// will still be on the board
	function bit isShiftOnBoard(Position pos, Direction dir, logic [2:0] distance);
		automatic Position new_pos = shiftPos(pos, dir, distance);
		automatic BoardRank old_rank = getRank(pos);
		automatic BoardFile old_file = getFile(pos);
		automatic BoardRank new_rank = getRank(new_pos);
		automatic BoardFile new_file = getFile(new_pos);

		if (distance == 0) return 1'b1;

		case (dir)
			NORTH, NORTH_EAST, NORTH_WEST: if (new_rank <= old_rank) return 1'b0;
			SOUTH, SOUTH_EAST, SOUTH_WEST: if (new_rank >= old_rank) return 1'b0;
		endcase

		case (dir)
			WEST, SOUTH_WEST, NORTH_WEST:  if (new_file >= old_file) return 1'b0;
			EAST, SOUTH_EAST, NORTH_EAST:  if (new_file <= old_file) return 1'b0;
		endcase

		return 1'b1;
	endfunction : isShiftOnBoard

	// Defines board direction
	typedef enum logic[2:0] {
		NNE, NEE, SEE, SSE, SSW, SWW, NWW, NNW
	} KnightDirection;

	localparam logic[5:0] KNIGHT_SHIFT[8] = '{
		6'd17, 6'd10, -6'd6, -6'd15, -6'd17, -6'd10, 6'd6, 6'd15
	};

	// Shift a position in some KNIGHT direction
	function Position shiftKnightPos(Position pos, KnightDirection dir);
		return Position'(pos + KNIGHT_SHIFT[dir]);
	endfunction : shiftKnightPos

	// Check if making a knight move for a given position+direction is possible
	function bit isKnightShiftOnBoard(Position pos, KnightDirection dir);
		case (dir)
			NNE: return (isShiftOnBoard(pos, NORTH, 2) && isShiftOnBoard(pos, EAST, 1));
			NEE: return (isShiftOnBoard(pos, NORTH, 1) && isShiftOnBoard(pos, EAST, 2));
			SEE: return (isShiftOnBoard(pos, SOUTH, 1) && isShiftOnBoard(pos, EAST, 2));
			SSE: return (isShiftOnBoard(pos, SOUTH, 2) && isShiftOnBoard(pos, EAST, 1));
			SSW: return (isShiftOnBoard(pos, SOUTH, 2) && isShiftOnBoard(pos, WEST, 1));
			SWW: return (isShiftOnBoard(pos, SOUTH, 1) && isShiftOnBoard(pos, WEST, 2));
			NWW: return (isShiftOnBoard(pos, NORTH, 1) && isShiftOnBoard(pos, WEST, 2));
			NNW: return (isShiftOnBoard(pos, NORTH, 2) && isShiftOnBoard(pos, WEST, 1));
			default: return 1'bx;
		endcase

	endfunction : isKnightShiftOnBoard


	// Mirrors a position between the black and white sides of the board
	function Position mirrorPos(Position in);
		return Position'({~getRank(in), getFile(in)});
	endfunction


	// -- Evaluation Related Definitions --

	localparam THREAD_COUNT = 1;

	localparam THREAD_ID_BITS = (THREAD_COUNT > 1) ? $clog2(THREAD_COUNT) : 1;

	typedef logic [THREAD_ID_BITS-1:0] ThreadID;


	// -- A Structure with Complete Board Positional Information --
	typedef struct packed {
		Tile [63:0] tiles;
		Color turn;
		CastlePerms castle_perms;
		logic has_ep;
		BoardFile ep_file;
		HalfMoveClk halfmove_clk;
	} FullBoard;


	// synopsys translate_off
	function automatic string toFen(FullBoard b);
		string str = "";
		int empty_cnt = 0;

		// Write Tiles
		for (int row=0; row<8; row++) begin
			for (int col=0; col<8; col++) begin
				int sq = SHOW_ORDER[8*row + col];
				if (b.tiles[sq].piece_type == NULL_PIECE) begin
					empty_cnt += 1;
				end else begin
					if (empty_cnt > 0) begin
						str = {str, $sformatf("%0d", empty_cnt)};
						empty_cnt = 0;
					end
					str = {str, pieceToChar(b.tiles[sq])};
				end
			end

			if (empty_cnt > 0) begin
				str = {str, $sformatf("%0d", empty_cnt)};
				empty_cnt = 0;
			end

			if (row < 7) str = {str, "/"};
		end

		// Write turn
		if (b.turn == WHITE) str = {str, " w"};
		else                 str = {str, " b"};

		// Write Castle Perms
		if (b.castle_perms == CastlePerms'(4'b0000)) begin
			str = {str, " -"};
		end else begin
			str = {str, " "};
			if (b.castle_perms.whiteKingside)  str = {str, "K"};
			if (b.castle_perms.whiteQueenside) str = {str, "Q"};
			if (b.castle_perms.blackKingside)  str = {str, "k"};
			if (b.castle_perms.blackQueenside) str = {str, "q"};
		end

		// Write En Passant Info
		if (b.has_ep) begin
			if (b.turn == WHITE) str = {str, " ", byte'("a") + b.ep_file, "6"};
			else                 str = {str, " ", byte'("a") + b.ep_file, "3"};
		end else begin
			str = {str, " -"};
		end

		// Write halfmove clock
		str = {str, " ", $sformatf("%0d", b.halfmove_clk)};

		return str;
	endfunction
	// synopsys translate_on


endpackage : general_chess_defs

`endif

