
// By Emet Behrendt

// Shared helper functions for the chess data types.

package chess_helper_funcs;

    import general_chess_defs::*;

	// Returns true when a piece type is real (not NULL or SPARE).
	function logic isRealPiece(PieceType piece_type);
		return (piece_type != NULL_PIECE && piece_type != SPARE_PIECE);
	endfunction

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

    // Checks if a move is NULL
    function logic isNullMove(Move m);
		return (m.from_pos == 6'd0 && m.to_pos == 6'd0 ? 1'b1 : 1'b0);
	endfunction

    // Mirrors a position between the black and white sides of the board
	function Position mirrorPos(Position in);
		return Position'({~getRank(in), getFile(in)});
	endfunction

    // Function returns true if direction is cardinal
	function logic isDirCardinal(Direction dir);
		return (dir==NORTH || dir==SOUTH || dir==EAST || dir==WEST);
	endfunction : isDirCardinal

	// Function returns true if direction is diagonal
	function logic isDirDiag(Direction dir);
		return (dir==NORTH_EAST || dir==SOUTH_EAST || dir==NORTH_WEST || dir==SOUTH_WEST);
	endfunction : isDirDiag

	// Shift a position in some direction for some distance
	function Position shiftPos(Position pos, Direction dir, logic [2:0] distance);
		logic [6:0] shifted_pos;

		// Positions intentionally wrap modulo 64 here; isShiftOnBoard validates
		// the direction-specific rank and file movement separately. Widen the
		// addition before truncating so synthesis does not report the intended
		// wraparound as a constant overflow.
		shifted_pos = {1'b0, pos} + {1'b0, DIST_SHIFT[dir][distance]};
		return Position'(shifted_pos[5:0]);
	endfunction : shiftPos

	// Returns whether shifting a position by the requested direction and distance
	// remains on the board.
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
			default: ;
		endcase

		case (dir)
			WEST, SOUTH_WEST, NORTH_WEST:  if (new_file >= old_file) return 1'b0;
			EAST, SOUTH_EAST, NORTH_EAST:  if (new_file <= old_file) return 1'b0;
			default: ;
		endcase

		return 1'b1;
	endfunction : isShiftOnBoard

	// Shift a position in some KNIGHT direction
	function Position shiftKnightPos(Position pos, KnightDirection dir);
		logic [6:0] shifted_pos;

		shifted_pos = {1'b0, pos} + {1'b0, KNIGHT_SHIFT[dir]};
		return Position'(shifted_pos[5:0]);
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

    // Maps a piece type to an associated letter
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

    // Returns an FEN string for a given board position
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
			if (b.castle_perms.white_kingside)  str = {str, "K"};
			if (b.castle_perms.white_queenside) str = {str, "Q"};
			if (b.castle_perms.black_kingside)  str = {str, "k"};
			if (b.castle_perms.black_queenside) str = {str, "q"};
		end

		// Write En Passant Info
		if (b.has_ep) begin
            automatic Position ep_pos = Position'({b.turn == WHITE ? 3'd5 : 3'd2, b.ep_file});

            // Check if EP is actually possible before printing location 
            if (   (b.turn == WHITE && ((b.tiles[ep_pos-7] == WHITE_PAWN && getFile(ep_pos) < 'd7) || (b.tiles[ep_pos-9] == WHITE_PAWN && getFile(ep_pos) > 'd0)))
                || (b.turn == BLACK && ((b.tiles[ep_pos+9] == BLACK_PAWN && getFile(ep_pos) < 'd7) || (b.tiles[ep_pos+7] == BLACK_PAWN && getFile(ep_pos) > 'd0)))) begin

                if (b.turn == WHITE) str = {str, " ", byte'("a") + b.ep_file, "6"};
                else                 str = {str, " ", byte'("a") + b.ep_file, "3"};
            end else begin
                str = {str, " -"};
            end
		end else begin
			str = {str, " -"};
		end

		// Write halfmove clock
		str = {str, " ", $sformatf("%0d", b.halfmove_clock)};

		return str;
	endfunction

endpackage : chess_helper_funcs
