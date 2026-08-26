
// By Emet Behrendt

// Shared helper functions for the chess data types.

package chess_helpers;

    import chess_defs::*;

    // Return the rank for a square.
	function BoardRank get_rank(input Position pos);
		return BoardRank'(pos[5:3]);
	endfunction

	// Return the file for a square.
	function BoardFile get_file(input Position pos);
		return BoardFile'(pos[2:0]);
	endfunction

	// Return the square at a rank and file.
	function Position get_position(input BoardRank rank, input BoardFile file);
		return Position'({rank, file});
	endfunction

    // Mirror a square between the White and Black sides of the board.
    function Position mirror_position(Position in);
		return Position'({~get_rank(in), get_file(in)});
	endfunction

    // Returns the incrementally maintained king square for one color.
    function Position king_position(input FullBoard board, input Color color);
		return Position'(board.king_positions[color]);
	endfunction

    // Return whether a direction is cardinal.
	function logic is_cardinal_direction(Direction dir);
		return (dir==NORTH || dir==SOUTH || dir==EAST || dir==WEST);
	endfunction : is_cardinal_direction

	// Return whether a direction is diagonal.
	function logic is_diagonal_direction(Direction dir);
		return (dir==NORTH_EAST || dir==SOUTH_EAST || dir==NORTH_WEST || dir==SOUTH_WEST);
	endfunction : is_diagonal_direction

	// Shift a square in a direction by a distance.
	function Position shift_position(Position pos, Direction dir, logic [2:0] distance);
		logic [6:0] shifted_pos;

		// Squares intentionally wrap modulo 64 here; is_shift_on_board validates
		// the direction-specific rank and file movement separately. Widen the
		// addition before truncating so synthesis does not report the intended
		// wraparound as a constant overflow.
		shifted_pos = {1'b0, pos} + {1'b0, DIST_SHIFT[dir][distance]};
		return Position'(shifted_pos[5:0]);
	endfunction : shift_position

	// Return whether shifting a square by the requested direction and distance
	// remains on the board.
	function bit is_shift_on_board(Position pos, Direction dir, logic [2:0] distance);
		automatic Position new_pos = shift_position(pos, dir, distance);
		automatic BoardRank old_rank = get_rank(pos);
		automatic BoardFile old_file = get_file(pos);
		automatic BoardRank new_rank = get_rank(new_pos);
		automatic BoardFile new_file = get_file(new_pos);

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
	endfunction : is_shift_on_board

	// Shift a square by a knight move.
	function Position shift_knight_position(Position pos, KnightDirection dir);
		logic [6:0] shifted_pos;

		shifted_pos = {1'b0, pos} + {1'b0, KNIGHT_SHIFT[dir]};
		return Position'(shifted_pos[5:0]);
	endfunction : shift_knight_position

	// Return whether a knight move remains on the board.
	function bit is_knight_shift_on_board(Position pos, KnightDirection dir);
		case (dir)
			NNE: return (is_shift_on_board(pos, NORTH, 2) && is_shift_on_board(pos, EAST, 1));
			NEE: return (is_shift_on_board(pos, NORTH, 1) && is_shift_on_board(pos, EAST, 2));
			SEE: return (is_shift_on_board(pos, SOUTH, 1) && is_shift_on_board(pos, EAST, 2));
			SSE: return (is_shift_on_board(pos, SOUTH, 2) && is_shift_on_board(pos, EAST, 1));
			SSW: return (is_shift_on_board(pos, SOUTH, 2) && is_shift_on_board(pos, WEST, 1));
			SWW: return (is_shift_on_board(pos, SOUTH, 1) && is_shift_on_board(pos, WEST, 2));
			NWW: return (is_shift_on_board(pos, NORTH, 1) && is_shift_on_board(pos, WEST, 2));
			NNW: return (is_shift_on_board(pos, NORTH, 2) && is_shift_on_board(pos, WEST, 1));
			default: return 1'bx;
		endcase
	endfunction : is_knight_shift_on_board

    // Return whether a sliding piece attacks along the supplied ray direction.
    function automatic logic is_line_attacker(input PieceType piece, input Direction dir);
        return piece == QUEEN
            || (piece == ROOK && is_cardinal_direction(dir))
            || (piece == BISHOP && is_diagonal_direction(dir));
    endfunction : is_line_attacker

    // Return whether one color attacks a square on an unmodified board.
    function automatic logic square_attacked(
        input FullBoard board,
        input Position square,
        input Color attacker_color
    );
        automatic Position test_pos;
        automatic Tile test_tile;

        if (attacker_color == WHITE) begin
            if (is_shift_on_board(square, SOUTH_WEST, 3'd1)
                    && board.tiles[shift_position(square, SOUTH_WEST, 3'd1)] == WHITE_PAWN) return 1'b1;
            if (is_shift_on_board(square, SOUTH_EAST, 3'd1)
                    && board.tiles[shift_position(square, SOUTH_EAST, 3'd1)] == WHITE_PAWN) return 1'b1;
        end else begin
            if (is_shift_on_board(square, NORTH_WEST, 3'd1)
                    && board.tiles[shift_position(square, NORTH_WEST, 3'd1)] == BLACK_PAWN) return 1'b1;
            if (is_shift_on_board(square, NORTH_EAST, 3'd1)
                    && board.tiles[shift_position(square, NORTH_EAST, 3'd1)] == BLACK_PAWN) return 1'b1;
        end

        for (int knight_dir = 0; knight_dir < 8; knight_dir++) begin
            if (is_knight_shift_on_board(square, KnightDirection'(knight_dir))) begin
                test_pos = shift_knight_position(square, KnightDirection'(knight_dir));
                if (board.tiles[test_pos] == Tile'({attacker_color, KNIGHT})) return 1'b1;
            end
        end

        for (int dir_idx = 0; dir_idx < 8; dir_idx++) begin
            automatic Direction dir = Direction'(dir_idx);
            for (int distance = 1; distance < 8; distance++) begin
                if (is_shift_on_board(square, dir, distance[2:0])) begin
                    test_pos = shift_position(square, dir, distance[2:0]);
                    test_tile = board.tiles[test_pos];
                    if (test_tile.piece_type != NULL_PIECE) begin
                        if (test_tile.piece_color == attacker_color) begin
                            if (distance == 1 && test_tile.piece_type == KING) return 1'b1;
                            if (is_line_attacker(test_tile.piece_type, dir)) return 1'b1;
                        end
                        break;
                    end
                end
            end
        end

        return 1'b0;
    endfunction : square_attacked

	// Return whether the side to move has a pawn adjacent to an en-passant
	// target. King safety is intentionally left to normal move validation.
	function automatic logic has_ep_capturer(
		input FullBoard board,
		input Color turn,
		input BoardFile ep_file
	);
		automatic BoardRank pawn_rank = turn == WHITE ? BoardRank'(4) : BoardRank'(3);
		automatic Tile pawn = Tile'({turn, PAWN});

		return (ep_file != BoardFile'(0)
				&& board.tiles[get_position(pawn_rank, ep_file - BoardFile'(1))] == pawn)
			|| (ep_file != BoardFile'(7)
				&& board.tiles[get_position(pawn_rank, ep_file + BoardFile'(1))] == pawn);
	endfunction : has_ep_capturer

    // Return the FEN character for a tile.
    function string piece_to_char(Tile t);
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

    // Return the FEN fields represented by the board state.
    function automatic string to_fen(FullBoard b);
		string str = "";
		int empty_cnt = 0;

		// Append piece placement.
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
					str = {str, piece_to_char(b.tiles[sq])};
				end
			end

			if (empty_cnt > 0) begin
				str = {str, $sformatf("%0d", empty_cnt)};
				empty_cnt = 0;
			end

			if (row < 7) str = {str, "/"};
		end

		// Append side to move.
		if (b.turn == WHITE) str = {str, " w"};
		else                 str = {str, " b"};

		// Append castling rights.
		if (b.castling_rights == CastlingRights'(4'b0000)) begin
			str = {str, " -"};
		end else begin
			str = {str, " "};
			if (b.castling_rights.white_kingside)  str = {str, "K"};
			if (b.castling_rights.white_queenside) str = {str, "Q"};
			if (b.castling_rights.black_kingside)  str = {str, "k"};
			if (b.castling_rights.black_queenside) str = {str, "q"};
		end

		// Append en passant state.
		if (b.has_ep && has_ep_capturer(b, b.turn, b.ep_file)) begin
			if (b.turn == WHITE) str = {str, " ", byte'("a") + b.ep_file, "6"};
			else                 str = {str, " ", byte'("a") + b.ep_file, "3"};
		end else begin
			str = {str, " -"};
		end

		// Append the halfmove clock.
		str = {str, " ", $sformatf("%0d", b.halfmove_clock)};

		return str;
	endfunction

endpackage : chess_helpers
