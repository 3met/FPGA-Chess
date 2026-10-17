// Standard-chess position fixtures and reversible game-history setup.
// Included in tb_search_controller scope.


    task automatic setup_kings_only();
        for (int pos = 0; pos < 16; pos++) begin
            if (pos != 4) begin
                set_tile(EMPTY_TILE, Position'(pos), $sformatf("clear square %0d", pos));
            end
        end
        for (int pos = 48; pos < 64; pos++) begin
            if (pos != 60) begin
                set_tile(EMPTY_TILE, Position'(pos), $sformatf("clear square %0d", pos));
            end
        end
        set_castling_rights(CastlingRights'(4'b0000), "clear castling rights for kings only");
    endtask : setup_kings_only

    // Legal checked root with both king escapes and quiet interpositions.
    task automatic setup_quiet_evasion_perft_position();
        clear_start_position("quiet evasion perft");
        set_tile(WHITE_KING, Position'(4), "quiet evasion king e1");
        set_tile(WHITE_ROOK, Position'(8), "quiet evasion rook a2");
        set_tile(WHITE_BISHOP, Position'(2), "quiet evasion bishop c1");
        set_tile(WHITE_KNIGHT, Position'(1), "quiet evasion knight b1");
        set_tile(WHITE_PAWN, Position'(14), "quiet evasion pawn g2");
        set_tile(BLACK_KING, Position'(57), "quiet evasion black king b8");
        set_tile(BLACK_ROOK, Position'(60), "quiet evasion checker e8");
        set_turn(WHITE, "quiet evasion white to move");
    endtask : setup_quiet_evasion_perft_position

    // Checked roots with off-line knight/EP captures and blocking promotions.
    task automatic setup_noisy_evasion_perft_position(input int fixture);
        clear_start_position("noisy evasion perft");
        set_tile(WHITE_QUEEN, Position'(9), "noisy evasion queen b2");
        case (fixture)
            0: begin
                set_tile(WHITE_KING, Position'(4), "knight evasion king e1");
                set_tile(BLACK_KING, Position'(58), "knight evasion king c8");
                set_tile(WHITE_BISHOP, Position'(14), "knight evasion bishop g2");
                set_tile(BLACK_KNIGHT, Position'(21), "knight checker f3");
                set_tile(BLACK_KNIGHT, Position'(45), "other knight f6");
                set_tile(BLACK_PAWN, Position'(10), "unrelated capture c2");
            end
            1: begin
                set_tile(WHITE_KING, Position'(28), "EP evasion king e4");
                set_tile(BLACK_KING, Position'(56), "EP evasion king a8");
                set_tile(WHITE_PAWN, Position'(36), "EP evasion pawn e5");
                set_tile(BLACK_PAWN, Position'(35), "EP checker d5");
                set_tile(BLACK_PAWN, Position'(8), "unrelated capture a2");
                set_en_passant(1'b1, BoardFile'(3), "EP evasion d6");
            end
            2: begin
                set_tile(WHITE_KING, Position'(56), "promotion evasion king a8");
                set_tile(BLACK_KING, Position'(47), "promotion evasion king h6");
                set_tile(BLACK_ROOK, Position'(63), "promotion checker h8");
                set_tile(WHITE_PAWN, Position'(50), "blocking promotion pawn c7");
                set_tile(BLACK_PAWN, Position'(10), "unrelated capture c2");
            end
        endcase
        set_turn(WHITE, "noisy evasion white to move");
    endtask : setup_noisy_evasion_perft_position

    task automatic setup_castling_perft_position();
        automatic CastlingRights castling_rights;

        castling_rights = CastlingRights'('0);
        castling_rights.white_kingside = 1'b1;
        clear_start_position("castling perft");
        set_tile(WHITE_KING, Position'(4), "castling perft white king e1");
        set_tile(WHITE_ROOK, Position'(7), "castling perft white rook h1");
        set_tile(BLACK_KING, Position'(56), "castling perft black king a8");
        set_castling_rights(castling_rights, "castling perft white kingside right");
        set_turn(WHITE, "castling perft white to move");
    endtask : setup_castling_perft_position

    task automatic setup_en_passant_perft_position();
        clear_start_position("en passant perft");
        set_tile(WHITE_KING, Position'(36), "en passant perft white king e5");
        set_tile(WHITE_PAWN, Position'(37), "en passant perft white pawn f5");
        set_tile(BLACK_PAWN, Position'(38), "en passant perft black pawn g5");
        set_tile(BLACK_KING, Position'(56), "en passant perft black king a8");
        set_en_passant(1'b1, BoardFile'(6), "en passant perft target g-file");
        set_turn(WHITE, "en passant perft white to move");
    endtask : setup_en_passant_perft_position

    task automatic setup_promotion_perft_position();
        clear_start_position("promotion perft");
        set_tile(WHITE_KING, Position'(4), "promotion perft white king e1");
        set_tile(WHITE_PAWN, Position'(48), "promotion perft white pawn a7");
        set_tile(BLACK_KING, Position'(60), "promotion perft black king e8");
        set_turn(WHITE, "promotion perft white to move");
    endtask : setup_promotion_perft_position

    task automatic setup_stalemate_position();
        clear_start_position("stalemate perft");
        set_tile(WHITE_KING, Position'(53), "stalemate white king f7");
        set_tile(WHITE_QUEEN, Position'(46), "stalemate white queen g6");
        set_tile(BLACK_KING, Position'(63), "stalemate black king h8");
        set_turn(BLACK, "stalemate black to move");
    endtask : setup_stalemate_position

    task automatic setup_checkmate_position();
        clear_start_position("checkmate perft");
        set_tile(WHITE_KING, Position'(45), "checkmate white king f6");
        set_tile(WHITE_QUEEN, Position'(54), "checkmate white queen g7");
        set_tile(BLACK_KING, Position'(63), "checkmate black king h8");
        set_turn(BLACK, "checkmate black to move");
    endtask : setup_checkmate_position

    // Near the fifty-move boundary, quiet mates and clock-resetting captures
    // must compete normally: White can delay Black's mate until the third move.
    task automatic setup_fifty_move_mate_position();
        clear_start_position("fifty-move mate regression");
        set_tile(WHITE_KING, Position'(8), "white king a2");
        set_tile(WHITE_KNIGHT, Position'(51), "white knight d7");
        set_tile(BLACK_KING, Position'(55), "black king h7");
        set_tile(BLACK_QUEEN, Position'(61), "black queen f8");
        set_tile(BLACK_ROOK, Position'(30), "black rook g4");
        set_tile(BLACK_ROOK, Position'(23), "black rook h3");
        set_turn(WHITE, "white to move");
        set_halfmove_clock(HalfmoveClock'(96), "near fifty-move threshold");
    endtask : setup_fifty_move_mate_position

    task automatic setup_qsearch_quiet_evasion_position();
        clear_start_position("qsearch quiet evasion");
        set_tile(WHITE_KING, Position'(0), "qsearch quiet evasion white king a1");
        set_tile(WHITE_ROOK, Position'(7), "qsearch quiet evasion white rook h1");
        set_tile(BLACK_KING, Position'(63), "qsearch quiet evasion black king h8");
        set_turn(BLACK, "qsearch quiet evasion black to move");
    endtask : setup_qsearch_quiet_evasion_position

    task automatic setup_rook_takes_queen();
        setup_kings_only();
        set_tile(WHITE_ROOK, Position'(0), "place white rook a1");
        set_tile(BLACK_QUEEN, Position'(56), "place black queen a8");
        set_castling_rights(CastlingRights'(4'b0000), "clear castling rights");
        set_turn(WHITE, "white to move");
    endtask : setup_rook_takes_queen

    task automatic setup_black_rook_takes_queen();
        setup_kings_only();
        set_tile(BLACK_ROOK, Position'(56), "place black rook a8");
        set_tile(WHITE_QUEEN, Position'(0), "place white queen a1");
        set_castling_rights(CastlingRights'(4'b0000), "clear castling rights for black capture");
        set_turn(BLACK, "black to move");
    endtask : setup_black_rook_takes_queen

    task automatic setup_pinned_rook_position();
        clear_start_position("pinned-rook search");
        set_tile(WHITE_KING, Position'(4), "pinned-rook white king e1");
        set_tile(WHITE_ROOK, Position'(12), "pinned-rook white rook e2");
        set_tile(BLACK_ROOK, Position'(60), "pinned-rook black rook e8");
        set_tile(BLACK_KING, Position'(56), "pinned-rook black king a8");
        set_turn(WHITE, "pinned-rook white to move");
    endtask : setup_pinned_rook_position

    task automatic repeat_knight_shuffle_once(input string label);
        apply_game_move(make_move(Position'(6), Position'(21), PROMO_QUEEN), {label, " g1f3"});
        apply_game_move(make_move(Position'(62), Position'(45), PROMO_QUEEN), {label, " g8f6"});
        apply_game_move(make_move(Position'(21), Position'(6), PROMO_QUEEN), {label, " f3g1"});
        apply_game_move(make_move(Position'(45), Position'(62), PROMO_QUEEN), {label, " f6g8"});
    endtask : repeat_knight_shuffle_once
