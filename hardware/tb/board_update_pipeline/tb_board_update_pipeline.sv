`timescale 1ns/1ns

import chess_defs::*;
import chess_helpers::*;
import board_update_pipeline_defs::*;
import zobrist_defs::*;
import zobrist_values_pkg::*;

module tb_board_update_pipeline;

    logic clk;
    BoardOp board_op;
    FullBoard board_in;
    ZobristKey zobrist_key_in;
    EvalScore pst_eval_in;
    PieceCount piece_count_in;
    Move move_in;
    logic [6:0] set_data;
    ThreadID thread_id;
    PlyIndex search_ply;

    FullBoard board_out;
    ZobristKey zobrist_key_out;
    EvalScore pst_eval_out;
    PieceCount piece_count_out;
    logic mover_in_check_out;
    logic side_in_check_out;

    PstScore pst_values[0:(6 * 64)-1];
    ZobristKey zobrist_tile_values[0:ZOBRIST_TILE_ENTRY_CNT-1];
    ZobristKey zobrist_ep_values[0:ZOBRIST_EP_ENTRY_CNT-1];

    FullBoard ref_board;
    MoveRecord ref_history[0:MAX_PLY_COUNT-1];
    PlyIndex ref_ply;
    EvalScore ref_pst;
    ZobristKey ref_zobrist;

    int pass_count = 0;
    int fail_count = 0;

    board_update_pipeline dut (
        .clk(clk),
        .board_op(board_op),
        .board_in(board_in),
        .zobrist_key_in(zobrist_key_in),
        .pst_eval_in(pst_eval_in),
        .piece_count_in(piece_count_in),
        .move_in(move_in),
        .set_data(set_data),
        .thread_id(thread_id),
        .search_ply(search_ply),
        .board_out(board_out),
        .zobrist_key_out(zobrist_key_out),
        .pst_eval_out(pst_eval_out),
        .piece_count_out(piece_count_out),
        .mover_in_check_out(mover_in_check_out),
        .side_in_check_out(side_in_check_out)
    );

    task automatic do_clock(input int cnt = 1);
        for (int i = 0; i < cnt; i++) begin
            clk = 1'b0; #5;
            clk = 1'b1; #5;
        end
    endtask

    function automatic Tile norm_tile(input Tile tile);
        if (tile.piece_type == NULL_PIECE) begin
            return EMPTY_TILE;
        end

        return tile;
    endfunction

    function automatic PieceType ref_promo_to_piece(input PromoType promo);
        case (promo)
            PROMO_QUEEN:  return QUEEN;
            PROMO_KNIGHT: return KNIGHT;
            PROMO_ROOK:   return ROOK;
            PROMO_BISHOP: return BISHOP;
            default:      return QUEEN;
        endcase
    endfunction

    function automatic Position ref_castle_rook_from(input Position king_to);
        case (king_to)
            Position'('d2):  return Position'('d0);
            Position'('d6):  return Position'('d7);
            Position'('d58): return Position'('d56);
            Position'('d62): return Position'('d63);
            default:         return Position'('dx);
        endcase
    endfunction

    function automatic Position ref_castle_rook_to(input Position king_to);
        case (king_to)
            Position'('d2):  return Position'('d3);
            Position'('d6):  return Position'('d5);
            Position'('d58): return Position'('d59);
            Position'('d62): return Position'('d61);
            default:         return Position'('dx);
        endcase
    endfunction

    function automatic EvalScore ref_tile_score(input Tile tile, input Position pos);
        automatic Position pst_pos;
        automatic int pst_idx;
        automatic EvalScore score;
        automatic Tile normalized = norm_tile(tile);

        if (normalized.piece_type == NULL_PIECE) begin
            return EvalScore'(0);
        end

        pst_pos = (normalized.piece_color == BLACK) ? mirror_position(pos) : pos;
        pst_idx = (int'(normalized.piece_type) - 1) * 64 + int'(pst_pos);
        score = PIECE_VALS_128[normalized.piece_type] + EvalScore'(pst_values[pst_idx]);
        return (normalized.piece_color == WHITE) ? score : -score;
    endfunction

    function automatic EvalScore ref_eval(input FullBoard board);
        automatic int signed total = 0;

        for (int pos = 0; pos < 64; pos++) begin
            total += ref_tile_score(board.tiles[pos], Position'(pos));
        end

        return EvalScore'(total);
    endfunction

    function automatic PieceCount ref_piece_count(input FullBoard board);
        automatic PieceCount count = PieceCount'(0);
        for (int pos = 0; pos < 64; pos++) begin
            if (board.tiles[pos].piece_type != NULL_PIECE)
                count += PieceCount'(1);
        end
        return count;
    endfunction

    function automatic ZobristKey ref_zobrist_tile(input Tile tile, input Position pos);
        automatic Tile normalized = norm_tile(tile);

        if (normalized.piece_type == NULL_PIECE) begin
            return ZobristKey'(0);
        end

        return zobrist_tile_values[zobrist_tile_addr(normalized, pos)];
    endfunction

    function automatic logic ref_ep_has_capturer(
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
    endfunction

    function automatic ZobristKey ref_zobrist_full(input FullBoard board);
        automatic ZobristKey key = ZobristKey'(0);

        if (board.turn == BLACK) begin
            key ^= ZOBRIST_TURN_BLACK_VALUE;
        end

        if (board.castling_rights.white_kingside)  key ^= ZOBRIST_WHITE_KINGSIDE_VALUE;
        if (board.castling_rights.white_queenside) key ^= ZOBRIST_WHITE_QUEENSIDE_VALUE;
        if (board.castling_rights.black_kingside)  key ^= ZOBRIST_BLACK_KINGSIDE_VALUE;
        if (board.castling_rights.black_queenside) key ^= ZOBRIST_BLACK_QUEENSIDE_VALUE;

        if (board.has_ep && ref_ep_has_capturer(board, board.turn, board.ep_file)) begin
            key ^= zobrist_ep_values[board.ep_file];
        end

        for (int pos = 0; pos < 64; pos++) begin
            key ^= ref_zobrist_tile(board.tiles[pos], Position'(pos));
        end

        return key;
    endfunction

    task automatic init_empty_board(output FullBoard board);
        for (int pos = 0; pos < 64; pos++) begin
            board.tiles[pos] = EMPTY_TILE;
        end

        board.king_positions = KingPositions'(0);
        board.turn = WHITE;
        board.castling_rights = CastlingRights'(4'b0000);
        board.has_ep = 1'b0;
        board.ep_file = BoardFile'(0);
        board.halfmove_clock = HalfmoveClock'(0);
    endtask

    task automatic refresh_ref_scores();
        ref_pst = ref_eval(ref_board);
        ref_zobrist = ref_zobrist_full(ref_board);
    endtask

    task automatic reset_ref_model();
        init_empty_board(ref_board);
        for (int ply = 0; ply < MAX_PLY_COUNT; ply++) begin
            ref_history[ply] = MoveRecord'('0);
        end
        ref_ply = PlyIndex'(0);
        refresh_ref_scores();
    endtask

    task automatic drive_idle();
        board_op = BOARD_IDLE_OP;
        board_in = 'x;
        zobrist_key_in = 'x;
        pst_eval_in = 'x;
        piece_count_in = 'x;
        move_in = NULL_MOVE;
        set_data = 'x;
        thread_id = ThreadID'(0);
        search_ply = ref_ply;
    endtask

    task automatic record_pass();
        pass_count += 1;
    endtask

    task automatic record_fail(input string message);
        fail_count += 1;
        $error("[%6t] %s", $time, message);
    endtask

    task automatic expect_equal(input bit condition, input string message);
        if (condition) begin
            record_pass();
        end else begin
            record_fail(message);
        end
    endtask

    task automatic expect_state(input FullBoard expected_board, input string test_name);
        automatic EvalScore expected_pst = ref_eval(expected_board);
        automatic ZobristKey expected_zobrist = ref_zobrist_full(expected_board);

        expect_equal(board_out === expected_board,
            $sformatf("%s board mismatch expected=%s found=%s", test_name, to_fen(expected_board), to_fen(board_out)));
        expect_equal(pst_eval_out === expected_pst,
            $sformatf("%s PST mismatch expected=%0d found=%0d", test_name, expected_pst, pst_eval_out));
        expect_equal(piece_count_out === ref_piece_count(expected_board),
            $sformatf("%s piece-count mismatch expected=%0d found=%0d",
                test_name, ref_piece_count(expected_board), piece_count_out));
        expect_equal(zobrist_key_out === expected_zobrist,
            $sformatf("%s Zobrist mismatch expected=%h found=%h", test_name, expected_zobrist, zobrist_key_out));
    endtask

    task automatic expect_ref_state(input string test_name);
        expect_state(ref_board, test_name);
    endtask

    task automatic expect_fen(input string expected_fen, input string test_name);
        automatic string found_fen = to_fen(ref_board);

        expect_equal(found_fen == expected_fen,
            $sformatf("%s FEN mismatch expected=%s found=%s", test_name, expected_fen, found_fen));
    endtask

    task automatic ref_apply_set_tile(input Move move, input logic [6:0] data);
        automatic Tile tile = norm_tile(Tile'(data[3:0]));
        ref_board.tiles[move.to_pos] = tile;
        if (tile.piece_type == KING)
            ref_board.king_positions[tile.piece_color] = move.to_pos;
        ref_board.has_ep = ref_board.has_ep
            && ref_ep_has_capturer(ref_board, ref_board.turn, ref_board.ep_file);
    endtask

    task automatic ref_apply_set_turn(input logic [6:0] data);
        ref_board.turn = Color'(data[0]);
        ref_board.has_ep = ref_board.has_ep
            && ref_ep_has_capturer(ref_board, ref_board.turn, ref_board.ep_file);
    endtask

    task automatic ref_apply_set_castling_rights(input logic [6:0] data);
        ref_board.castling_rights = CastlingRights'(data[3:0]);
    endtask

    task automatic ref_apply_set_en_passant(input logic [6:0] data);
        ref_board.ep_file = BoardFile'(data[3:1]);
        ref_board.has_ep = data[0]
            && ref_ep_has_capturer(ref_board, ref_board.turn, ref_board.ep_file);
    endtask

    task automatic ref_apply_set_halfmove_clock(input logic [6:0] data);
        ref_board.halfmove_clock = HalfmoveClock'(data);
    endtask

    task automatic ref_apply_move(input Move move, input bit writes_history);
        automatic Position from_pos = move.from_pos;
        automatic Position to_pos = move.to_pos;
        automatic Tile moving_tile = norm_tile(ref_board.tiles[from_pos]);
        automatic Tile destination_tile = norm_tile(ref_board.tiles[to_pos]);
        automatic Color moved_color = moving_tile.piece_color;
        automatic Color captured_color = Color'(~moved_color);
        automatic logic is_promo = (moving_tile.piece_type == PAWN && (get_rank(to_pos) == BoardRank'('d0) || get_rank(to_pos) == BoardRank'('d7)));
        automatic logic is_castle = (moving_tile.piece_type == KING && get_file(from_pos) == BoardFile'('d4) && (get_file(to_pos) == BoardFile'('d2) || get_file(to_pos) == BoardFile'('d6)));
        automatic logic is_ep = (moving_tile.piece_type == PAWN && ref_board.has_ep && ref_board.ep_file == get_file(to_pos) && destination_tile.piece_type == NULL_PIECE && ((moved_color == WHITE && get_rank(to_pos) == BoardRank'('d5)) || (moved_color == BLACK && get_rank(to_pos) == BoardRank'('d2))));
        automatic PieceType placed_piece = is_promo ? ref_promo_to_piece(move.promo_piece) : moving_tile.piece_type;
        automatic Tile placed_tile = Tile'({moved_color, placed_piece});
        automatic Position ep_capture_pos = get_position(get_rank(from_pos), get_file(to_pos));
        automatic Position rook_from = ref_castle_rook_from(to_pos);
        automatic Position rook_to = ref_castle_rook_to(to_pos);
        automatic CastlingRights next_castle = ref_board.castling_rights;
        automatic logic next_has_ep;
        automatic HalfmoveClock next_halfmove;

        if (writes_history) begin
            ref_history[ref_ply].from_pos = from_pos;
            ref_history[ref_ply].to_pos = to_pos;
            ref_history[ref_ply].captured_piece = is_ep ? NULL_PIECE : destination_tile.piece_type;
            ref_history[ref_ply].castling_rights = ref_board.castling_rights;
            ref_history[ref_ply].move_flag = is_promo ? PROMO_MOVE : is_castle ? CASTLE_MOVE : is_ep ? EP_MOVE : NORM_MOVE;
            ref_history[ref_ply].has_ep = ref_board.has_ep;
            ref_history[ref_ply].ep_file = ref_board.ep_file;
            ref_history[ref_ply].halfmove_clock = ref_board.halfmove_clock;
        end

        ref_board.tiles[from_pos] = EMPTY_TILE;
        ref_board.tiles[to_pos] = placed_tile;
        if (moving_tile.piece_type == KING)
            ref_board.king_positions[moved_color] = to_pos;

        if (is_ep) begin
            ref_board.tiles[ep_capture_pos] = EMPTY_TILE;
        end

        if (is_castle) begin
            ref_board.tiles[rook_from] = EMPTY_TILE;
            ref_board.tiles[rook_to] = Tile'({moved_color, ROOK});
        end

        if (from_pos == Position'('d4)  || from_pos == Position'('d7)  || to_pos == Position'('d7))  next_castle.white_kingside = 1'b0;
        if (from_pos == Position'('d4)  || from_pos == Position'('d0)  || to_pos == Position'('d0))  next_castle.white_queenside = 1'b0;
        if (from_pos == Position'('d60) || from_pos == Position'('d63) || to_pos == Position'('d63)) next_castle.black_kingside = 1'b0;
        if (from_pos == Position'('d60) || from_pos == Position'('d56) || to_pos == Position'('d56)) next_castle.black_queenside = 1'b0;

        next_has_ep = moving_tile.piece_type == PAWN
            && ((moved_color == WHITE && get_rank(from_pos) == BoardRank'(1)
                    && get_rank(to_pos) == BoardRank'(3))
                || (moved_color == BLACK && get_rank(from_pos) == BoardRank'(6)
                    && get_rank(to_pos) == BoardRank'(4)))
            && ref_ep_has_capturer(ref_board, Color'(~ref_board.turn), get_file(to_pos));
        next_halfmove = (is_ep || destination_tile.piece_type != NULL_PIECE || moving_tile.piece_type == PAWN) ? HalfmoveClock'(0) : ref_board.halfmove_clock + HalfmoveClock'(1);

        ref_board.turn = Color'(~ref_board.turn);
        ref_board.castling_rights = next_castle;
        ref_board.has_ep = next_has_ep;
        ref_board.ep_file = get_file(to_pos);
        ref_board.halfmove_clock = next_halfmove;

        if (writes_history) begin
            ref_ply += PlyIndex'(1);
        end
    endtask

    task automatic ref_apply_reverse();
        automatic MoveRecord rec = ref_history[ref_ply - PlyIndex'(1)];
        automatic Position from_pos = rec.from_pos;
        automatic Position to_pos = rec.to_pos;
        automatic Color moved_color = Color'(~ref_board.turn);
        automatic Color captured_color = ref_board.turn;
        automatic Tile destination_tile = norm_tile(ref_board.tiles[to_pos]);
        automatic logic is_promo = (rec.move_flag == PROMO_MOVE);
        automatic logic is_ep = (rec.move_flag == EP_MOVE);
        automatic logic is_castle = (rec.move_flag == CASTLE_MOVE);
        automatic PieceType restored_piece = is_promo ? PAWN : destination_tile.piece_type;
        automatic Tile restored_mover = Tile'({moved_color, restored_piece});
        automatic Tile restored_capture = (rec.captured_piece == NULL_PIECE) ? EMPTY_TILE : Tile'({captured_color, rec.captured_piece});
        automatic Position ep_capture_pos = get_position(get_rank(from_pos), get_file(to_pos));
        automatic Position rook_from = ref_castle_rook_from(to_pos);
        automatic Position rook_to = ref_castle_rook_to(to_pos);

        if (from_pos != to_pos) begin
            ref_board.tiles[from_pos] = restored_mover;
            ref_board.tiles[to_pos] = restored_capture;
            if (restored_mover.piece_type == KING)
                ref_board.king_positions[moved_color] = from_pos;

            if (is_ep) begin
                ref_board.tiles[to_pos] = EMPTY_TILE;
                ref_board.tiles[ep_capture_pos] = Tile'({captured_color, PAWN});
            end

            if (is_castle) begin
                ref_board.tiles[rook_to] = EMPTY_TILE;
                ref_board.tiles[rook_from] = Tile'({moved_color, ROOK});
            end
        end

        ref_board.turn = moved_color;
        ref_board.castling_rights = rec.castling_rights;
        ref_board.has_ep = rec.has_ep;
        ref_board.ep_file = rec.ep_file;
        ref_board.halfmove_clock = rec.halfmove_clock;
        ref_ply -= PlyIndex'(1);
    endtask

    task automatic ref_apply_null();
        ref_history[ref_ply].from_pos = Position'(0);
        ref_history[ref_ply].to_pos = Position'(0);
        ref_history[ref_ply].captured_piece = NULL_PIECE;
        ref_history[ref_ply].castling_rights = ref_board.castling_rights;
        ref_history[ref_ply].move_flag = NORM_MOVE;
        ref_history[ref_ply].has_ep = ref_board.has_ep;
        ref_history[ref_ply].ep_file = ref_board.ep_file;
        ref_history[ref_ply].halfmove_clock = ref_board.halfmove_clock;
        ref_board.turn = Color'(~ref_board.turn);
        ref_board.has_ep = 1'b0;
        ref_board.halfmove_clock += HalfmoveClock'(1);
        ref_ply += PlyIndex'(1);
    endtask

    task automatic apply_ref_op(input BoardOp op, input Move move, input logic [6:0] data);
        case (op)
            BOARD_PUSH_MOVE_OP:           ref_apply_move(move, 1'b1);
            BOARD_COMMIT_MOVE_OP:         ref_apply_move(move, 1'b0);
            BOARD_SET_TILE_OP:            ref_apply_set_tile(move, data);
            BOARD_SET_TURN_OP:            ref_apply_set_turn(data);
            BOARD_SET_CASTLING_RIGHTS_OP:    ref_apply_set_castling_rights(data);
            BOARD_SET_EN_PASSANT_OP:      ref_apply_set_en_passant(data);
            BOARD_SET_HALFMOVE_CLOCK_OP:  ref_apply_set_halfmove_clock(data);
            BOARD_REVERSE_MOVE_OP:        ref_apply_reverse();
            BOARD_PUSH_NULL_OP:           ref_apply_null();
            default: begin end
        endcase

        refresh_ref_scores();
    endtask

    task automatic run_op(
        input BoardOp op,
        input Move move,
        input logic [6:0] data,
        input string test_name,
        input bit verify = 1'b1
    );
        automatic FullBoard old_board = ref_board;
        automatic ZobristKey old_zobrist = ref_zobrist;
        automatic EvalScore old_pst = ref_pst;
        automatic PlyIndex old_ply = ref_ply;

        apply_ref_op(op, move, data);

        board_in = old_board;
        zobrist_key_in = old_zobrist;
        pst_eval_in = old_pst;
        piece_count_in = ref_piece_count(old_board);
        move_in = move;
        set_data = data;
        thread_id = ThreadID'(0);
        search_ply = old_ply;
        board_op = op;

        do_clock(1);
        drive_idle();
        do_clock(BOARD_UPDATE_PIPELINE_STAGE_CNT - 1);
        if (verify) expect_ref_state(test_name);
    endtask

    task automatic run_raw_op(
        input BoardOp op,
        input FullBoard in_board,
        input ZobristKey in_zobrist,
        input EvalScore in_pst,
        input Move move,
        input logic [6:0] data,
        input ThreadID request_thread_id,
        input PlyIndex request_ply,
        output FullBoard out_board,
        output ZobristKey out_zobrist,
        output EvalScore out_pst
    );
        board_in = in_board;
        zobrist_key_in = in_zobrist;
        pst_eval_in = in_pst;
        piece_count_in = ref_piece_count(in_board);
        move_in = move;
        set_data = data;
        thread_id = request_thread_id;
        search_ply = request_ply;
        board_op = op;

        do_clock(1);
        drive_idle();
        do_clock(BOARD_UPDATE_PIPELINE_STAGE_CNT - 1);
        out_board = board_out;
        out_zobrist = zobrist_key_out;
        out_pst = pst_eval_out;
    endtask

    task automatic set_tile(
        input Tile tile,
        input Position pos,
        input string test_name,
        input bit verify = 1'b1
    );
        automatic Move move = NULL_MOVE;
        automatic logic [6:0] data = 7'd0;
        move.to_pos = pos;
        data[3:0] = tile;
        run_op(BOARD_SET_TILE_OP, move, data, test_name, verify);
    endtask

    task automatic set_turn(input Color color, input string test_name, input bit verify = 1'b1);
        automatic logic [6:0] data = 7'd0;
        data[0] = color;
        run_op(BOARD_SET_TURN_OP, NULL_MOVE, data, test_name, verify);
    endtask

    task automatic set_castling_rights(
        input CastlingRights castling_rights,
        input string test_name,
        input bit verify = 1'b1
    );
        automatic logic [6:0] data = 7'd0;
        data[3:0] = castling_rights;
        run_op(BOARD_SET_CASTLING_RIGHTS_OP, NULL_MOVE, data, test_name, verify);
    endtask

    task automatic set_en_passant(
        input logic has_ep,
        input BoardFile ep_file,
        input string test_name,
        input bit verify = 1'b1
    );
        automatic logic [6:0] data = 7'd0;
        data[0] = has_ep;
        data[3:1] = ep_file;
        run_op(BOARD_SET_EN_PASSANT_OP, NULL_MOVE, data, test_name, verify);
    endtask

    task automatic set_halfmove_clock(
        input HalfmoveClock halfmove_clock,
        input string test_name,
        input bit verify = 1'b1
    );
        automatic logic [6:0] data = halfmove_clock;
        run_op(BOARD_SET_HALFMOVE_CLOCK_OP, NULL_MOVE, data, test_name, verify);
    endtask

    task automatic push_move(input Position from_pos, input Position to_pos, input PromoType promo, input string test_name);
        run_op(BOARD_PUSH_MOVE_OP, Move'({from_pos, to_pos, promo}), 7'd0, test_name);
    endtask

    task automatic commit_move(input Position from_pos, input Position to_pos, input PromoType promo, input string test_name);
        run_op(BOARD_COMMIT_MOVE_OP, Move'({from_pos, to_pos, promo}), 7'd0, test_name);
    endtask

    task automatic reverse_move(input string test_name);
        run_op(BOARD_REVERSE_MOVE_OP, NULL_MOVE, 7'd0, test_name);
    endtask

    task automatic push_null(input string test_name);
        run_op(BOARD_PUSH_NULL_OP, NULL_MOVE, 7'd0, test_name);
    endtask

    task automatic setup_start_position();
        reset_ref_model();
        drive_idle();

        set_tile(WHITE_ROOK,   Position'(0),  "setup a1", 1'b0);
        set_tile(WHITE_KNIGHT, Position'(1),  "setup b1", 1'b0);
        set_tile(WHITE_BISHOP, Position'(2),  "setup c1", 1'b0);
        set_tile(WHITE_QUEEN,  Position'(3),  "setup d1", 1'b0);
        set_tile(WHITE_KING,   Position'(4),  "setup e1", 1'b0);
        set_tile(WHITE_BISHOP, Position'(5),  "setup f1", 1'b0);
        set_tile(WHITE_KNIGHT, Position'(6),  "setup g1", 1'b0);
        set_tile(WHITE_ROOK,   Position'(7),  "setup h1", 1'b0);
        for (int pos = 8; pos < 16; pos++) begin
            set_tile(WHITE_PAWN, Position'(pos), $sformatf("setup white pawn %0d", pos), 1'b0);
        end
        for (int pos = 48; pos < 56; pos++) begin
            set_tile(BLACK_PAWN, Position'(pos), $sformatf("setup black pawn %0d", pos), 1'b0);
        end
        set_tile(BLACK_ROOK,   Position'(56), "setup a8", 1'b0);
        set_tile(BLACK_KNIGHT, Position'(57), "setup b8", 1'b0);
        set_tile(BLACK_BISHOP, Position'(58), "setup c8", 1'b0);
        set_tile(BLACK_QUEEN,  Position'(59), "setup d8", 1'b0);
        set_tile(BLACK_KING,   Position'(60), "setup e8", 1'b0);
        set_tile(BLACK_BISHOP, Position'(61), "setup f8", 1'b0);
        set_tile(BLACK_KNIGHT, Position'(62), "setup g8", 1'b0);
        set_tile(BLACK_ROOK,   Position'(63), "setup h8", 1'b0);
        set_turn(WHITE, "setup turn", 1'b0);
        set_castling_rights(CastlingRights'(4'b1111), "setup castling rights", 1'b0);
        set_en_passant(1'b0, BoardFile'(0), "setup en passant", 1'b0);
        set_halfmove_clock(HalfmoveClock'(0), "setup halfmove clock", 1'b0);
        expect_ref_state("start position setup");
        expect_equal(ref_board.king_positions[WHITE] == Position'(4)
                && ref_board.king_positions[BLACK] == Position'(60),
            "start position tracks both king squares");
        expect_fen("rnbqkbnr/pppppppp/8/8/8/8/PPPPPPPP/RNBQKBNR w KQkq - 0", "start position");
    endtask

    task automatic test_main_move_sequence();
        setup_start_position();

        push_move(Position'(12), Position'(28), PROMO_QUEEN, "e2e4");
        expect_equal(!ref_board.has_ep, "e2e4 drops uncapturable en-passant target");
        expect_fen("rnbqkbnr/pppppppp/8/8/4P3/8/PPPP1PPP/RNBQKBNR b KQkq - 0", "after e2e4");
        push_move(Position'(53), Position'(37), PROMO_QUEEN, "f7f5");
        expect_fen("rnbqkbnr/ppppp1pp/8/5p2/4P3/8/PPPP1PPP/RNBQKBNR w KQkq - 0", "after f7f5");
        push_move(Position'(28), Position'(37), PROMO_QUEEN, "e4xf5");
        expect_fen("rnbqkbnr/ppppp1pp/8/5P2/8/8/PPPP1PPP/RNBQKBNR b KQkq - 0", "after e4xf5");
        push_move(Position'(52), Position'(36), PROMO_QUEEN, "e7e5");
        expect_equal(ref_board.has_ep && ref_board.ep_file == BoardFile'(4),
            "e7e5 retains capturable en-passant target");
        expect_fen("rnbqkbnr/pppp2pp/8/4pP2/8/8/PPPP1PPP/RNBQKBNR w KQkq e6 0", "after e7e5");
        push_move(Position'(37), Position'(44), PROMO_QUEEN, "f5xe6 ep");
        expect_fen("rnbqkbnr/pppp2pp/4P3/8/8/8/PPPP1PPP/RNBQKBNR b KQkq - 0", "after ep capture");
        push_move(Position'(62), Position'(45), PROMO_QUEEN, "g8f6");
        expect_fen("rnbqkb1r/pppp2pp/4Pn2/8/8/8/PPPP1PPP/RNBQKBNR w KQkq - 1", "after g8f6");
        push_move(Position'(44), Position'(51), PROMO_QUEEN, "e6d7");
        expect_fen("rnbqkb1r/pppP2pp/5n2/8/8/8/PPPP1PPP/RNBQKBNR b KQkq - 0", "after e6d7");
        push_move(Position'(60), Position'(53), PROMO_QUEEN, "e8f7");
        expect_equal(ref_board.king_positions[BLACK] == Position'(53),
            "black king move updates tracked square");
        expect_fen("rnbq1b1r/pppP1kpp/5n2/8/8/8/PPPP1PPP/RNBQKBNR w KQ - 1", "after e8f7");
        push_move(Position'(51), Position'(58), PROMO_QUEEN, "d7c8q");
        expect_fen("rnQq1b1r/ppp2kpp/5n2/8/8/8/PPPP1PPP/RNBQKBNR b KQ - 0", "after promotion");
        push_move(Position'(48), Position'(32), PROMO_QUEEN, "a7a5");
        expect_fen("rnQq1b1r/1pp2kpp/5n2/p7/8/8/PPPP1PPP/RNBQKBNR w KQ - 0", "after a7a5");
        push_move(Position'(5), Position'(12), PROMO_QUEEN, "f1e2");
        expect_fen("rnQq1b1r/1pp2kpp/5n2/p7/8/8/PPPPBPPP/RNBQK1NR b KQ - 1", "after f1e2");
        push_move(Position'(56), Position'(40), PROMO_QUEEN, "a8a6");
        expect_fen("1nQq1b1r/1pp2kpp/r4n2/p7/8/8/PPPPBPPP/RNBQK1NR w KQ - 2", "after a8a6");
        push_move(Position'(6), Position'(21), PROMO_QUEEN, "g1f3");
        expect_fen("1nQq1b1r/1pp2kpp/r4n2/p7/8/5N2/PPPPBPPP/RNBQK2R b KQ - 3", "after g1f3");
        push_move(Position'(59), Position'(60), PROMO_QUEEN, "d8e8");
        expect_fen("1nQ1qb1r/1pp2kpp/r4n2/p7/8/5N2/PPPPBPPP/RNBQK2R w KQ - 4", "after d8e8");
        push_move(Position'(4), Position'(6), PROMO_QUEEN, "e1g1 castle");
        expect_equal(ref_board.king_positions[WHITE] == Position'(6),
            "castling updates tracked king square");
        expect_fen("1nQ1qb1r/1pp2kpp/r4n2/p7/8/5N2/PPPPBPPP/RNBQ1RK1 b - - 5", "after white kingside castle");
        push_move(Position'(53), Position'(62), PROMO_QUEEN, "f7g8");
        expect_fen("1nQ1qbkr/1pp3pp/r4n2/p7/8/5N2/PPPPBPPP/RNBQ1RK1 w - - 6", "after f7g8");

        reverse_move("reverse f7g8");
        reverse_move("reverse e1g1 castle");
        expect_equal(ref_board.king_positions[WHITE] == Position'(4),
            "reversing castling restores tracked king square");
        reverse_move("reverse d8e8");
        reverse_move("reverse g1f3");
        reverse_move("reverse a8a6");
        reverse_move("reverse f1e2");
        reverse_move("reverse a7a5");
        reverse_move("reverse promotion");
        reverse_move("reverse e8f7");
        reverse_move("reverse e6d7");
        reverse_move("reverse g8f6");
        reverse_move("reverse ep capture");
        reverse_move("reverse e7e5");
        reverse_move("reverse e4xf5");
        reverse_move("reverse f7f5");
        reverse_move("reverse e2e4");
        expect_fen("rnbqkbnr/pppppppp/8/8/8/8/PPPPPPPP/RNBQKBNR w KQkq - 0", "after full reverse");
        expect_equal(ref_pst === DRAW_EVAL_SCORE, $sformatf("PST after full reverse expected=0 found=%0d", ref_pst));
    endtask

    task automatic test_null_move();
        setup_start_position();
        set_tile(EMPTY_TILE, Position'(11), "null remove d2 pawn");
        set_tile(WHITE_PAWN, Position'(35), "null place d5 pawn");
        set_en_passant(1'b1, BoardFile'(4), "null setup en passant");
        set_halfmove_clock(HalfmoveClock'(17), "null setup halfmove");
        push_null("push null");
        expect_equal(ref_board.turn == BLACK, "null toggles turn");
        expect_equal(!ref_board.has_ep, "null clears en passant");
        expect_equal(ref_board.halfmove_clock == HalfmoveClock'(18), "null increments halfmove clock");
        reverse_move("reverse null");
        expect_equal(ref_board.turn == WHITE, "null reverse restores turn");
        expect_equal(ref_board.has_ep && ref_board.ep_file == BoardFile'(4),
            "null reverse restores en passant");
        expect_equal(ref_board.halfmove_clock == HalfmoveClock'(17),
            "null reverse restores halfmove clock");
    endtask

    task automatic test_en_passant_canonicalization();
        automatic ZobristKey key_without_ep;

        setup_start_position();
        key_without_ep = ref_zobrist;
        set_en_passant(1'b1, BoardFile'(4), "ignore uncapturable en passant");
        expect_equal(!ref_board.has_ep, "uncapturable en-passant state is canonicalized away");
        expect_equal(ref_zobrist == key_without_ep,
            "uncapturable en-passant target does not change the key");

        set_tile(EMPTY_TILE, Position'(11), "canonical EP remove d2 pawn");
        set_tile(WHITE_PAWN, Position'(35), "canonical EP place d5 pawn");
        key_without_ep = ref_zobrist;
        set_en_passant(1'b1, BoardFile'(4), "retain capturable en passant");
        expect_equal(ref_board.has_ep, "capturable en-passant state is retained");
        expect_equal(ref_zobrist != key_without_ep,
            "capturable en-passant target changes the key");
        set_tile(EMPTY_TILE, Position'(35), "remove sole en-passant capturer");
        expect_equal(!ref_board.has_ep,
            "removing the sole capturer clears the en-passant state and key");
    endtask

    task automatic setup_castle_position(input Color color, input bit kingside);
        reset_ref_model();
        drive_idle();

        if (color == WHITE) begin
            set_tile(WHITE_KING, Position'(4), "castle setup white king", 1'b0);
            set_tile(WHITE_ROOK, kingside ? Position'(7) : Position'(0), "castle setup white rook", 1'b0);
            set_turn(WHITE, "castle setup white turn", 1'b0);
            set_castling_rights(kingside ? CastlingRights'(4'b1000) : CastlingRights'(4'b0100), "castle setup white rights", 1'b0);
        end else begin
            set_tile(BLACK_KING, Position'(60), "castle setup black king", 1'b0);
            set_tile(BLACK_ROOK, kingside ? Position'(63) : Position'(56), "castle setup black rook", 1'b0);
            set_turn(BLACK, "castle setup black turn", 1'b0);
            set_castling_rights(kingside ? CastlingRights'(4'b0010) : CastlingRights'(4'b0001), "castle setup black rights", 1'b0);
        end

        set_en_passant(1'b0, BoardFile'(0), "castle setup ep", 1'b0);
        set_halfmove_clock(HalfmoveClock'(0), "castle setup halfmove", 1'b0);
        expect_ref_state("castle setup");
    endtask

    task automatic test_castle_direction(input Color color, input bit kingside, input Position from_pos, input Position to_pos, input string fen_after, input string name);
        setup_castle_position(color, kingside);
        push_move(from_pos, to_pos, PROMO_QUEEN, {name, " push"});
        expect_fen(fen_after, {name, " fen"});
        reverse_move({name, " reverse"});
    endtask

    task automatic test_castles();
        test_castle_direction(WHITE, 1'b0, Position'(4), Position'(2), "8/8/8/8/8/8/8/2KR4 b - - 1", "white queenside castle");
        test_castle_direction(BLACK, 1'b1, Position'(60), Position'(62), "5rk1/8/8/8/8/8/8/8 w - - 1", "black kingside castle");
        test_castle_direction(BLACK, 1'b0, Position'(60), Position'(58), "2kr4/8/8/8/8/8/8/8 w - - 1", "black queenside castle");
    endtask

    task automatic test_set_tile_overwrite();
        setup_start_position();

        set_tile(BLACK_ROOK, Position'(0), "overwrite a1 with black rook");
        expect_fen("rnbqkbnr/pppppppp/8/8/8/8/PPPPPPPP/rNBQKBNR w KQkq - 0", "after overwrite black rook");
        expect_equal(ref_pst < DRAW_EVAL_SCORE, $sformatf("overwrite score expected negative found=%0d", ref_pst));

        set_tile(WHITE_ROOK, Position'(0), "restore a1 white rook");
        expect_fen("rnbqkbnr/pppppppp/8/8/8/8/PPPPPPPP/RNBQKBNR w KQkq - 0", "after overwrite restore");
        expect_equal(ref_pst === DRAW_EVAL_SCORE, $sformatf("restore score expected 0 found=%0d", ref_pst));

        for (int piece = PAWN; piece <= QUEEN; piece++) begin
            set_tile(Tile'({WHITE, PieceType'(piece)}), Position'(24), $sformatf("add white piece type %0d", piece));
            expect_equal(ref_pst > DRAW_EVAL_SCORE, $sformatf("white piece type %0d expected positive found=%0d", piece, ref_pst));
            set_tile(EMPTY_TILE, Position'(24), $sformatf("remove white piece type %0d", piece));
            expect_equal(ref_pst === DRAW_EVAL_SCORE, $sformatf("remove white piece type %0d expected 0 found=%0d", piece, ref_pst));
        end
    endtask

    task automatic test_commit_history_not_written();
        automatic MoveRecord saved_record;

        setup_start_position();
        push_move(Position'(12), Position'(28), PROMO_QUEEN, "history sentinel e2e4");
        saved_record = dut.move_hist_mem.mem[0];
        reverse_move("reverse sentinel e2e4");
        commit_move(Position'(1), Position'(18), PROMO_QUEEN, "commit b1c3 at ply 0");

        expect_equal(dut.move_hist_mem.mem[0] === saved_record, "commit move must not overwrite push history slot 0");
    endtask

    task automatic test_thread_history_isolation();
        automatic FullBoard start_board;
        automatic FullBoard thread0_after;
        automatic FullBoard thread1_after;
        automatic FullBoard thread0_restored;
        automatic FullBoard thread1_restored;
        automatic ZobristKey start_zobrist;
        automatic ZobristKey thread0_zobrist;
        automatic ZobristKey thread1_zobrist;
        automatic ZobristKey thread0_restored_zobrist;
        automatic ZobristKey thread1_restored_zobrist;
        automatic EvalScore start_pst;
        automatic EvalScore thread0_pst;
        automatic EvalScore thread1_pst;
        automatic EvalScore thread0_restored_pst;
        automatic EvalScore thread1_restored_pst;

        setup_start_position();
        start_board = ref_board;
        start_zobrist = ref_zobrist;
        start_pst = ref_pst;

        run_raw_op(
            BOARD_PUSH_MOVE_OP,
            start_board,
            start_zobrist,
            start_pst,
            Move'({Position'(12), Position'(28), PROMO_QUEEN}),
            7'd0,
            ThreadID'(0),
            PlyIndex'(0),
            thread0_after,
            thread0_zobrist,
            thread0_pst
        );
        run_raw_op(
            BOARD_PUSH_MOVE_OP,
            start_board,
            start_zobrist,
            start_pst,
            Move'({Position'(11), Position'(27), PROMO_QUEEN}),
            7'd0,
            ThreadID'(1),
            PlyIndex'(0),
            thread1_after,
            thread1_zobrist,
            thread1_pst
        );
        run_raw_op(
            BOARD_REVERSE_MOVE_OP,
            thread0_after,
            thread0_zobrist,
            thread0_pst,
            NULL_MOVE,
            7'd0,
            ThreadID'(0),
            PlyIndex'(1),
            thread0_restored,
            thread0_restored_zobrist,
            thread0_restored_pst
        );
        run_raw_op(
            BOARD_REVERSE_MOVE_OP,
            thread1_after,
            thread1_zobrist,
            thread1_pst,
            NULL_MOVE,
            7'd0,
            ThreadID'(1),
            PlyIndex'(1),
            thread1_restored,
            thread1_restored_zobrist,
            thread1_restored_pst
        );

        expect_equal(thread0_restored === start_board, "thread 0 reverse restores board");
        expect_equal(thread0_restored_zobrist === start_zobrist, "thread 0 reverse restores zobrist");
        expect_equal(thread0_restored_pst === start_pst, "thread 0 reverse restores pst");
        expect_equal(thread1_restored === start_board, "thread 1 reverse restores board");
        expect_equal(thread1_restored_zobrist === start_zobrist, "thread 1 reverse restores zobrist");
        expect_equal(thread1_restored_pst === start_pst, "thread 1 reverse restores pst");
    endtask

    task automatic test_back_to_back_independent_requests();
        automatic FullBoard base_board;
        automatic FullBoard expected_a;
        automatic FullBoard expected_b;
        automatic ZobristKey base_zobrist;
        automatic EvalScore base_pst;
        automatic Move move_a = NULL_MOVE;
        automatic Move move_b = NULL_MOVE;

        init_empty_board(base_board);
        expected_a = base_board;
        expected_b = base_board;
        expected_a.tiles[Position'(1)] = WHITE_KNIGHT;
        expected_b.tiles[Position'(58)] = BLACK_BISHOP;
        base_zobrist = ref_zobrist_full(base_board);
        base_pst = ref_eval(base_board);
        move_a.to_pos = Position'(1);
        move_b.to_pos = Position'(58);

        board_in = base_board;
        zobrist_key_in = base_zobrist;
        pst_eval_in = base_pst;
        piece_count_in = ref_piece_count(base_board);
        move_in = move_a;
        set_data = {3'b0, WHITE_KNIGHT};
        thread_id = ThreadID'(0);
        search_ply = PlyIndex'(0);
        board_op = BOARD_SET_TILE_OP;
        do_clock(1);

        board_in = base_board;
        zobrist_key_in = base_zobrist;
        pst_eval_in = base_pst;
        piece_count_in = ref_piece_count(base_board);
        move_in = move_b;
        set_data = {3'b0, BLACK_BISHOP};
        thread_id = ThreadID'(0);
        search_ply = PlyIndex'(0);
        board_op = BOARD_SET_TILE_OP;
        do_clock(1);

        drive_idle();
        do_clock(BOARD_UPDATE_PIPELINE_STAGE_CNT - 2);
        expect_state(expected_a, "back-to-back request A");
        do_clock(1);
        expect_state(expected_b, "back-to-back request B");
    endtask

    // Consecutive pushes must use each request's own post-move overlay when
    // checking whether the mover exposed its king.
    task automatic test_back_to_back_king_safety();
        automatic FullBoard board_a;
        automatic FullBoard board_b;
        automatic Move move_a = NULL_MOVE;
        automatic Move move_b = NULL_MOVE;

        init_empty_board(board_a);
        board_a.tiles[Position'(4)] = WHITE_KING;
        board_a.tiles[Position'(12)] = WHITE_ROOK;
        board_a.tiles[Position'(56)] = BLACK_KING;
        board_a.tiles[Position'(60)] = BLACK_ROOK;
        board_a.king_positions[WHITE] = Position'(4);
        board_a.king_positions[BLACK] = Position'(56);
        move_a.from_pos = Position'(12);
        move_a.to_pos = Position'(13);

        init_empty_board(board_b);
        board_b.tiles[Position'(4)] = WHITE_KING;
        board_b.tiles[Position'(1)] = WHITE_KNIGHT;
        board_b.tiles[Position'(56)] = BLACK_KING;
        board_b.king_positions[WHITE] = Position'(4);
        board_b.king_positions[BLACK] = Position'(56);
        move_b.from_pos = Position'(1);
        move_b.to_pos = Position'(18);

        board_in = board_a;
        zobrist_key_in = ref_zobrist_full(board_a);
        pst_eval_in = ref_eval(board_a);
        piece_count_in = ref_piece_count(board_a);
        move_in = move_a;
        set_data = 7'd0;
        thread_id = ThreadID'(0);
        search_ply = PlyIndex'(0);
        board_op = BOARD_PUSH_MOVE_OP;
        do_clock(1);

        board_in = board_b;
        zobrist_key_in = ref_zobrist_full(board_b);
        pst_eval_in = ref_eval(board_b);
        piece_count_in = ref_piece_count(board_b);
        move_in = move_b;
        board_op = BOARD_PUSH_MOVE_OP;
        do_clock(1);

        drive_idle();
        do_clock(BOARD_UPDATE_PIPELINE_STAGE_CNT - 2);
        expect_equal(mover_in_check_out, "back-to-back request A exposes its king");
        do_clock(1);
        expect_equal(!mover_in_check_out, "back-to-back request B keeps its king safe");
    endtask

    initial begin
        $readmemh("hardware/data/pst_values/pst_values.hex", pst_values);
        $readmemh(ZOBRIST_TILE_MEM_INIT_FILE, zobrist_tile_values);
        $readmemh(ZOBRIST_EP_MEM_INIT_FILE, zobrist_ep_values);

        clk = 1'b0;
        reset_ref_model();
        drive_idle();
        do_clock(2);

        $display("=== Board update pipeline testbench ===");
        test_back_to_back_independent_requests();
        test_back_to_back_king_safety();
        test_main_move_sequence();
        test_null_move();
        test_en_passant_canonicalization();
        test_castles();
        test_set_tile_overwrite();
        test_commit_history_not_written();
        test_thread_history_isolation();

        $display("Testbench run complete.");
        $display("Pass Count: %0d", pass_count);
        $display("Fail Count: %0d", fail_count);

        if (fail_count != 0) $fatal(1, "board_update_pipeline testbench failed");
        $finish;
    end

    // Bound all event waits so a broken pipeline fails promptly in CI.
    initial begin
        #1_000_000;
        $fatal(1, "board_update_pipeline testbench timed out");
    end

endmodule
