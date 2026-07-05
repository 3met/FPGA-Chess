// Run in Questa/ModelSim from the repository root after compiling RTL and this file:
// vsim -t ns work.tb_board_update_pipeline
// run -all

`timescale 1ns/1ns

import general_chess_defs::*;
import chess_helper_funcs::*;
import board_update_pipeline_defs::*;
import zobrist_defs::*;

module tb_board_update_pipeline;

    logic clk;
    BoardOp board_op;
    FullBoard board_in;
    ZobristKey zobrist_key_in;
    EvalScore pst_eval_in;
    Move move_in;
    logic [6:0] set_data;
    ThreadID thread_id;
    PlyIndex search_ply;

    FullBoard board_out;
    ZobristKey zobrist_key_out;
    EvalScore pst_eval_out;

    EvalScore pst_values[0:(6 * 64)-1];
    ZobristKey zobrist_values[0:ZOBRIST_ENTRY_CNT-1];

    FullBoard ref_board;
    MoveRecord ref_history[0:MAX_PLY_COUNT-1];
    PlyIndex ref_ply;
    EvalScore ref_pst;
    ZobristKey ref_zobrist;

    int pass_count = 0;
    int error_count = 0;

    board_update_pipeline dut (
        .clk(clk),
        .board_op(board_op),
        .board_in(board_in),
        .zobrist_key_in(zobrist_key_in),
        .pst_eval_in(pst_eval_in),
        .move_in(move_in),
        .set_data(set_data),
        .thread_id(thread_id),
        .search_ply(search_ply),
        .board_out(board_out),
        .zobrist_key_out(zobrist_key_out),
        .pst_eval_out(pst_eval_out)
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

        pst_pos = (normalized.piece_color == BLACK) ? mirrorPos(pos) : pos;
        pst_idx = (int'(normalized.piece_type) - 1) * 64 + int'(pst_pos);
        score = PIECE_VALS_128[normalized.piece_type] + pst_values[pst_idx];
        return (normalized.piece_color == WHITE) ? score : -score;
    endfunction

    function automatic EvalScore ref_eval(input FullBoard board);
        automatic int signed total = 0;

        for (int pos = 0; pos < 64; pos++) begin
            total += ref_tile_score(board.tiles[pos], Position'(pos));
        end

        return EvalScore'(total);
    endfunction

    function automatic ZobristKey ref_zobrist_tile(input Tile tile, input Position pos);
        automatic Tile normalized = norm_tile(tile);

        if (normalized.piece_type == NULL_PIECE) begin
            return ZobristKey'(0);
        end

        return zobrist_values[zobrist_tile_addr(normalized, pos)];
    endfunction

    function automatic ZobristKey ref_zobrist_full(input FullBoard board);
        automatic ZobristKey key = ZobristKey'(0);

        if (board.turn == BLACK) begin
            key ^= zobrist_values[ZOBRIST_TURN_BLACK_ADDR];
        end

        if (board.castle_perms.white_kingside)  key ^= zobrist_values[zobrist_castle_addr(0)];
        if (board.castle_perms.white_queenside) key ^= zobrist_values[zobrist_castle_addr(1)];
        if (board.castle_perms.black_kingside)  key ^= zobrist_values[zobrist_castle_addr(2)];
        if (board.castle_perms.black_queenside) key ^= zobrist_values[zobrist_castle_addr(3)];

        if (board.has_ep) begin
            key ^= zobrist_values[zobrist_ep_addr(board.ep_file)];
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

        board.turn = WHITE;
        board.castle_perms = CastlePerms'(4'b0000);
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
        move_in = NULL_MOVE;
        set_data = 'x;
        thread_id = ThreadID'(0);
        search_ply = ref_ply;
    endtask

    task automatic record_pass();
        pass_count += 1;
    endtask

    task automatic record_fail(input string message);
        error_count += 1;
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
            $sformatf("%s board mismatch expected=%s found=%s", test_name, toFen(expected_board), toFen(board_out)));
        expect_equal(pst_eval_out === expected_pst,
            $sformatf("%s PST mismatch expected=%0d found=%0d", test_name, expected_pst, pst_eval_out));
        expect_equal(zobrist_key_out === expected_zobrist,
            $sformatf("%s Zobrist mismatch expected=%h found=%h", test_name, expected_zobrist, zobrist_key_out));
    endtask

    task automatic expect_ref_state(input string test_name);
        expect_state(ref_board, test_name);
    endtask

    task automatic expect_fen(input string expected_fen, input string test_name);
        automatic string found_fen = toFen(ref_board);

        expect_equal(found_fen == expected_fen,
            $sformatf("%s FEN mismatch expected=%s found=%s", test_name, expected_fen, found_fen));
    endtask

    task automatic ref_apply_set_tile(input Move move, input logic [6:0] data);
        ref_board.tiles[move.to_pos] = norm_tile(Tile'(data[3:0]));
    endtask

    task automatic ref_apply_set_turn(input logic [6:0] data);
        ref_board.turn = Color'(data[0]);
    endtask

    task automatic ref_apply_set_castle_perms(input logic [6:0] data);
        ref_board.castle_perms = CastlePerms'(data[3:0]);
    endtask

    task automatic ref_apply_set_en_passant(input logic [6:0] data);
        ref_board.has_ep = data[0];
        ref_board.ep_file = BoardFile'(data[3:1]);
    endtask

    task automatic ref_apply_set_halfmove_clock(input logic [6:0] data);
        ref_board.halfmove_clock = HalfmoveClock'(data);
    endtask

    task automatic ref_apply_move(input Move move, input bit writes_history);
        automatic Position from_pos = move.from_pos;
        automatic Position to_pos = move.to_pos;
        automatic Tile start_tile = norm_tile(ref_board.tiles[from_pos]);
        automatic Tile end_tile = norm_tile(ref_board.tiles[to_pos]);
        automatic Color moved_color = start_tile.piece_color;
        automatic Color captured_color = Color'(~moved_color);
        automatic logic is_promo = (start_tile.piece_type == PAWN && (getRank(to_pos) == BoardRank'('d0) || getRank(to_pos) == BoardRank'('d7)));
        automatic logic is_castle = (start_tile.piece_type == KING && getFile(from_pos) == BoardFile'('d4) && (getFile(to_pos) == BoardFile'('d2) || getFile(to_pos) == BoardFile'('d6)));
        automatic logic is_ep = (start_tile.piece_type == PAWN && ref_board.has_ep && ref_board.ep_file == getFile(to_pos) && end_tile.piece_type == NULL_PIECE && ((moved_color == WHITE && getRank(to_pos) == BoardRank'('d5)) || (moved_color == BLACK && getRank(to_pos) == BoardRank'('d2))));
        automatic PieceType placed_piece = is_promo ? ref_promo_to_piece(move.promo_piece) : start_tile.piece_type;
        automatic Tile placed_tile = Tile'({moved_color, placed_piece});
        automatic Position ep_capture_pos = getPosition(getRank(from_pos), getFile(to_pos));
        automatic Position rook_from = ref_castle_rook_from(to_pos);
        automatic Position rook_to = ref_castle_rook_to(to_pos);
        automatic CastlePerms next_castle = ref_board.castle_perms;
        automatic logic next_has_ep;
        automatic HalfmoveClock next_halfmove;

        if (writes_history) begin
            ref_history[ref_ply].from_pos = from_pos;
            ref_history[ref_ply].to_pos = to_pos;
            ref_history[ref_ply].killed_piece = is_ep ? NULL_PIECE : end_tile.piece_type;
            ref_history[ref_ply].castle_perms = ref_board.castle_perms;
            ref_history[ref_ply].move_flag = is_promo ? PROMO_MOVE : is_castle ? CASTLE_MOVE : is_ep ? EP_MOVE : NORM_MOVE;
            ref_history[ref_ply].has_ep = ref_board.has_ep;
            ref_history[ref_ply].ep_file = ref_board.ep_file;
            ref_history[ref_ply].halfmove_clock = ref_board.halfmove_clock;
        end

        ref_board.tiles[from_pos] = EMPTY_TILE;
        ref_board.tiles[to_pos] = placed_tile;

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

        next_has_ep = (start_tile.piece_type == PAWN && ((moved_color == WHITE && getRank(from_pos) == BoardRank'('d1) && getRank(to_pos) == BoardRank'('d3)) || (moved_color == BLACK && getRank(from_pos) == BoardRank'('d6) && getRank(to_pos) == BoardRank'('d4))));
        next_halfmove = (is_ep || end_tile.piece_type != NULL_PIECE || start_tile.piece_type == PAWN) ? HalfmoveClock'(0) : ref_board.halfmove_clock + HalfmoveClock'(1);

        ref_board.turn = Color'(~ref_board.turn);
        ref_board.castle_perms = next_castle;
        ref_board.has_ep = next_has_ep;
        ref_board.ep_file = getFile(to_pos);
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
        automatic Tile end_tile = norm_tile(ref_board.tiles[to_pos]);
        automatic logic is_promo = (rec.move_flag == PROMO_MOVE);
        automatic logic is_ep = (rec.move_flag == EP_MOVE);
        automatic logic is_castle = (rec.move_flag == CASTLE_MOVE);
        automatic PieceType restored_piece = is_promo ? PAWN : end_tile.piece_type;
        automatic Tile restored_mover = Tile'({moved_color, restored_piece});
        automatic Tile restored_capture = (rec.killed_piece == NULL_PIECE) ? EMPTY_TILE : Tile'({captured_color, rec.killed_piece});
        automatic Position ep_capture_pos = getPosition(getRank(from_pos), getFile(to_pos));
        automatic Position rook_from = ref_castle_rook_from(to_pos);
        automatic Position rook_to = ref_castle_rook_to(to_pos);

        ref_board.tiles[from_pos] = restored_mover;
        ref_board.tiles[to_pos] = restored_capture;

        if (is_ep) begin
            ref_board.tiles[to_pos] = EMPTY_TILE;
            ref_board.tiles[ep_capture_pos] = Tile'({captured_color, PAWN});
        end

        if (is_castle) begin
            ref_board.tiles[rook_to] = EMPTY_TILE;
            ref_board.tiles[rook_from] = Tile'({moved_color, ROOK});
        end

        ref_board.turn = moved_color;
        ref_board.castle_perms = rec.castle_perms;
        ref_board.has_ep = rec.has_ep;
        ref_board.ep_file = rec.ep_file;
        ref_board.halfmove_clock = rec.halfmove_clock;
        ref_ply -= PlyIndex'(1);
    endtask

    task automatic apply_ref_op(input BoardOp op, input Move move, input logic [6:0] data);
        case (op)
            BOARD_PUSH_MOVE_OP:           ref_apply_move(move, 1'b1);
            BOARD_COMMIT_MOVE_OP:         ref_apply_move(move, 1'b0);
            BOARD_SET_TILE_OP:            ref_apply_set_tile(move, data);
            BOARD_SET_TURN_OP:            ref_apply_set_turn(data);
            BOARD_SET_CASTLE_PERMS_OP:    ref_apply_set_castle_perms(data);
            BOARD_SET_EN_PASSANT_OP:      ref_apply_set_en_passant(data);
            BOARD_SET_HALFMOVE_CLOCK_OP:  ref_apply_set_halfmove_clock(data);
            BOARD_REVERSE_MOVE_OP:        ref_apply_reverse();
            default: begin end
        endcase

        refresh_ref_scores();
    endtask

    task automatic run_op(input BoardOp op, input Move move, input logic [6:0] data, input string test_name);
        automatic FullBoard old_board = ref_board;
        automatic ZobristKey old_zobrist = ref_zobrist;
        automatic EvalScore old_pst = ref_pst;
        automatic PlyIndex old_ply = ref_ply;

        apply_ref_op(op, move, data);

        board_in = old_board;
        zobrist_key_in = old_zobrist;
        pst_eval_in = old_pst;
        move_in = move;
        set_data = data;
        thread_id = ThreadID'(0);
        search_ply = old_ply;
        board_op = op;

        do_clock(1);
        drive_idle();
        do_clock(BOARD_UPDATE_PIPELINE_STAGE_CNT - 1);
        expect_ref_state(test_name);
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

    task automatic set_tile(input Tile tile, input Position pos, input string test_name);
        automatic Move move = NULL_MOVE;
        automatic logic [6:0] data = 7'd0;
        move.to_pos = pos;
        data[3:0] = tile;
        run_op(BOARD_SET_TILE_OP, move, data, test_name);
    endtask

    task automatic set_turn(input Color color, input string test_name);
        automatic logic [6:0] data = 7'd0;
        data[0] = color;
        run_op(BOARD_SET_TURN_OP, NULL_MOVE, data, test_name);
    endtask

    task automatic set_castle_perms(input CastlePerms castle_perms, input string test_name);
        automatic logic [6:0] data = 7'd0;
        data[3:0] = castle_perms;
        run_op(BOARD_SET_CASTLE_PERMS_OP, NULL_MOVE, data, test_name);
    endtask

    task automatic set_en_passant(input logic has_ep, input BoardFile ep_file, input string test_name);
        automatic logic [6:0] data = 7'd0;
        data[0] = has_ep;
        data[3:1] = ep_file;
        run_op(BOARD_SET_EN_PASSANT_OP, NULL_MOVE, data, test_name);
    endtask

    task automatic set_halfmove_clock(input HalfmoveClock halfmove_clock, input string test_name);
        automatic logic [6:0] data = halfmove_clock;
        run_op(BOARD_SET_HALFMOVE_CLOCK_OP, NULL_MOVE, data, test_name);
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

    task automatic setup_start_position();
        reset_ref_model();
        drive_idle();

        set_tile(WHITE_ROOK,   Position'(0),  "setup a1");
        set_tile(WHITE_KNIGHT, Position'(1),  "setup b1");
        set_tile(WHITE_BISHOP, Position'(2),  "setup c1");
        set_tile(WHITE_QUEEN,  Position'(3),  "setup d1");
        set_tile(WHITE_KING,   Position'(4),  "setup e1");
        set_tile(WHITE_BISHOP, Position'(5),  "setup f1");
        set_tile(WHITE_KNIGHT, Position'(6),  "setup g1");
        set_tile(WHITE_ROOK,   Position'(7),  "setup h1");
        for (int pos = 8; pos < 16; pos++) begin
            set_tile(WHITE_PAWN, Position'(pos), $sformatf("setup white pawn %0d", pos));
        end
        for (int pos = 48; pos < 56; pos++) begin
            set_tile(BLACK_PAWN, Position'(pos), $sformatf("setup black pawn %0d", pos));
        end
        set_tile(BLACK_ROOK,   Position'(56), "setup a8");
        set_tile(BLACK_KNIGHT, Position'(57), "setup b8");
        set_tile(BLACK_BISHOP, Position'(58), "setup c8");
        set_tile(BLACK_QUEEN,  Position'(59), "setup d8");
        set_tile(BLACK_KING,   Position'(60), "setup e8");
        set_tile(BLACK_BISHOP, Position'(61), "setup f8");
        set_tile(BLACK_KNIGHT, Position'(62), "setup g8");
        set_tile(BLACK_ROOK,   Position'(63), "setup h8");
        set_turn(WHITE, "setup turn");
        set_castle_perms(CastlePerms'(4'b1111), "setup castle perms");
        set_en_passant(1'b0, BoardFile'(0), "setup en passant");
        set_halfmove_clock(HalfmoveClock'(0), "setup halfmove clock");
        expect_fen("rnbqkbnr/pppppppp/8/8/8/8/PPPPPPPP/RNBQKBNR w KQkq - 0", "start position");
    endtask

    task automatic test_main_move_sequence();
        setup_start_position();

        push_move(Position'(12), Position'(28), PROMO_QUEEN, "e2e4");
        expect_fen("rnbqkbnr/pppppppp/8/8/4P3/8/PPPP1PPP/RNBQKBNR b KQkq - 0", "after e2e4");
        push_move(Position'(53), Position'(37), PROMO_QUEEN, "f7f5");
        expect_fen("rnbqkbnr/ppppp1pp/8/5p2/4P3/8/PPPP1PPP/RNBQKBNR w KQkq - 0", "after f7f5");
        push_move(Position'(28), Position'(37), PROMO_QUEEN, "e4xf5");
        expect_fen("rnbqkbnr/ppppp1pp/8/5P2/8/8/PPPP1PPP/RNBQKBNR b KQkq - 0", "after e4xf5");
        push_move(Position'(52), Position'(36), PROMO_QUEEN, "e7e5");
        expect_fen("rnbqkbnr/pppp2pp/8/4pP2/8/8/PPPP1PPP/RNBQKBNR w KQkq e6 0", "after e7e5");
        push_move(Position'(37), Position'(44), PROMO_QUEEN, "f5xe6 ep");
        expect_fen("rnbqkbnr/pppp2pp/4P3/8/8/8/PPPP1PPP/RNBQKBNR b KQkq - 0", "after ep capture");
        push_move(Position'(62), Position'(45), PROMO_QUEEN, "g8f6");
        expect_fen("rnbqkb1r/pppp2pp/4Pn2/8/8/8/PPPP1PPP/RNBQKBNR w KQkq - 1", "after g8f6");
        push_move(Position'(44), Position'(51), PROMO_QUEEN, "e6d7");
        expect_fen("rnbqkb1r/pppP2pp/5n2/8/8/8/PPPP1PPP/RNBQKBNR b KQkq - 0", "after e6d7");
        push_move(Position'(60), Position'(53), PROMO_QUEEN, "e8f7");
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
        expect_fen("1nQ1qb1r/1pp2kpp/r4n2/p7/8/5N2/PPPPBPPP/RNBQ1RK1 b - - 5", "after white kingside castle");
        push_move(Position'(53), Position'(62), PROMO_QUEEN, "f7g8");
        expect_fen("1nQ1qbkr/1pp3pp/r4n2/p7/8/5N2/PPPPBPPP/RNBQ1RK1 w - - 6", "after f7g8");

        reverse_move("reverse f7g8");
        reverse_move("reverse e1g1 castle");
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

    task automatic setup_castle_position(input Color color, input bit kingside);
        reset_ref_model();
        drive_idle();

        if (color == WHITE) begin
            set_tile(WHITE_KING, Position'(4), "castle setup white king");
            set_tile(WHITE_ROOK, kingside ? Position'(7) : Position'(0), "castle setup white rook");
            set_turn(WHITE, "castle setup white turn");
            set_castle_perms(kingside ? CastlePerms'(4'b1000) : CastlePerms'(4'b0100), "castle setup white perms");
        end else begin
            set_tile(BLACK_KING, Position'(60), "castle setup black king");
            set_tile(BLACK_ROOK, kingside ? Position'(63) : Position'(56), "castle setup black rook");
            set_turn(BLACK, "castle setup black turn");
            set_castle_perms(kingside ? CastlePerms'(4'b0010) : CastlePerms'(4'b0001), "castle setup black perms");
        end

        set_en_passant(1'b0, BoardFile'(0), "castle setup ep");
        set_halfmove_clock(HalfmoveClock'(0), "castle setup halfmove");
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
        move_in = move_a;
        set_data = {3'b0, WHITE_KNIGHT};
        thread_id = ThreadID'(0);
        search_ply = PlyIndex'(0);
        board_op = BOARD_SET_TILE_OP;
        do_clock(1);

        board_in = base_board;
        zobrist_key_in = base_zobrist;
        pst_eval_in = base_pst;
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

    initial begin
        $readmemh("hardware/data/pst_values/pst_values.hex", pst_values);
        $readmemh(ZOBRIST_MEM_INIT_FILE, zobrist_values);

        clk = 1'b0;
        reset_ref_model();
        drive_idle();
        do_clock(2);

        $display("=== Board update pipeline testbench ===");
        test_back_to_back_independent_requests();
        test_main_move_sequence();
        test_castles();
        test_set_tile_overwrite();
        test_commit_history_not_written();
        test_thread_history_isolation();

        $display("Testbench run complete.");
        $display("Pass Count: %0d", pass_count);
        $display("Fail Count: %0d", error_count);

        if (error_count == 0) begin
            $finish;
        end else begin
            $fatal(1, "board_update_pipeline testbench failed");
        end
    end

endmodule
