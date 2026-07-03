// Run in Questa/ModelSim from the repository root after compiling RTL and this file:
// vsim -t ns work.tb_move_generator
// run -all

`timescale 1ns/1ns

import general_chess_defs::*;
import chess_helper_funcs::*;
import move_generator_defs::*;

module tb_move_generator;

    localparam int DUT_OUTPUT_LATENCY = MOVE_GEN_STAGE_CNT + 1;
    localparam int MAX_DUT_CANDIDATES = 512;

    logic clk;
    logic rst_n;

    MoveGenOp move_gen_op;
    logic start_node;
    ThreadID thread_id;
    PlyIndex ply;
    Move target_move;

    Tile board_tiles[64];
    Color turn;
    CastlePerms castle_perms;
    logic has_ep;
    BoardFile ep_file;

    Move candidate_move;
    logic move_is_legal;

    int pass_count = 0;
    int error_count = 0;

    move_generator #(
        .MAX_PLY_COUNT(MAX_PLY_COUNT),
        .THREAD_COUNT(THREAD_COUNT)
    ) dut (
        .clk(clk),
        .rst_n(rst_n),
        .move_gen_op(move_gen_op),
        .start_node(start_node),
        .thread_id(thread_id),
        .ply(ply),
        .target_move(target_move),
        .board_tiles(board_tiles),
        .turn(turn),
        .castle_perms(castle_perms),
        .has_ep(has_ep),
        .ep_file(ep_file),
        .candidate_move(candidate_move),
        .move_is_legal(move_is_legal)
    );

    task automatic do_clock(input int cnt = 1);
        for (int i = 0; i < cnt; i++) begin
            clk = 1'b0; #5;
            clk = 1'b1; #5;
        end
    endtask

    function automatic Move make_move(input Position from_pos, input Position to_pos, input PromoType promo);
        automatic Move move;

        move.from_pos = from_pos;
        move.to_pos = to_pos;
        move.promo_piece = promo;
        return move;
    endfunction

    function automatic int abs_int(input int value);
        return (value < 0) ? -value : value;
    endfunction

    function automatic logic [2:0] dist_to_shift(input int distance);
        return distance[2:0];
    endfunction

    function automatic Tile norm_tile(input Tile tile);
        if (tile.piece_type == NULL_PIECE) begin
            return EMPTY_TILE;
        end

        return tile;
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

    function automatic PieceType ref_promo_to_piece(input PromoType promo);
        case (promo)
            PROMO_QUEEN:  return QUEEN;
            PROMO_KNIGHT: return KNIGHT;
            PROMO_ROOK:   return ROOK;
            PROMO_BISHOP: return BISHOP;
            default:      return QUEEN;
        endcase
    endfunction

    function automatic bit ref_tile_empty(input FullBoard board, input Position pos);
        return (norm_tile(board.tiles[pos]).piece_type == NULL_PIECE);
    endfunction

    function automatic Position ref_find_king(input FullBoard board, input Color color);
        for (int pos = 0; pos < 64; pos++) begin
            if (norm_tile(board.tiles[pos]) == Tile'({color, KING})) begin
                return Position'(pos);
            end
        end

        return Position'('dx);
    endfunction

    function automatic bit ref_same_abs_delta(input Position from_pos, input Position to_pos);
        automatic int rank_delta = int'(getRank(to_pos)) - int'(getRank(from_pos));
        automatic int file_delta = int'(getFile(to_pos)) - int'(getFile(from_pos));

        return (abs_int(rank_delta) == abs_int(file_delta));
    endfunction

    function automatic bit ref_line_move(input Position from_pos, input Position to_pos);
        return (from_pos != to_pos && (getRank(from_pos) == getRank(to_pos) || getFile(from_pos) == getFile(to_pos)));
    endfunction

    function automatic bit ref_diag_move(input Position from_pos, input Position to_pos);
        return (from_pos != to_pos && ref_same_abs_delta(from_pos, to_pos));
    endfunction

    function automatic Direction ref_move_dir(input Position from_pos, input Position to_pos);
        automatic BoardRank from_rank = getRank(from_pos);
        automatic BoardRank to_rank = getRank(to_pos);
        automatic BoardFile from_file = getFile(from_pos);
        automatic BoardFile to_file = getFile(to_pos);

        if (from_file == to_file) begin
            return (from_rank < to_rank) ? NORTH : SOUTH;
        end else if (from_rank == to_rank) begin
            return (from_file < to_file) ? EAST : WEST;
        end else if ((from_rank < to_rank) && (from_file < to_file)) begin
            return NORTH_EAST;
        end else if ((from_rank < to_rank) && (from_file > to_file)) begin
            return NORTH_WEST;
        end else if ((from_rank > to_rank) && (from_file < to_file)) begin
            return SOUTH_EAST;
        end else begin
            return SOUTH_WEST;
        end
    endfunction

    function automatic bit ref_path_clear(input FullBoard board, input Position from_pos, input Position to_pos);
        automatic Direction dir;
        automatic Position pos;

        if (!(ref_line_move(from_pos, to_pos) || ref_diag_move(from_pos, to_pos))) begin
            return 1'b0;
        end

        dir = ref_move_dir(from_pos, to_pos);
        for (int distance = 1; distance < 8; distance++) begin
            pos = shiftPos(from_pos, dir, dist_to_shift(distance));
            if (pos == to_pos) begin
                return 1'b1;
            end
            if (!ref_tile_empty(board, pos)) begin
                return 1'b0;
            end
        end

        return 1'b0;
    endfunction

    function automatic bit ref_is_castle_move(input FullBoard board, input Move move);
        automatic Tile start_tile = norm_tile(board.tiles[move.from_pos]);

        return (start_tile.piece_type == KING
            && start_tile.piece_color == board.turn
            && (   (board.turn == WHITE && move.from_pos == Position'('d4)  && (move.to_pos == Position'('d2)  || move.to_pos == Position'('d6)))
                || (board.turn == BLACK && move.from_pos == Position'('d60) && (move.to_pos == Position'('d58) || move.to_pos == Position'('d62)))));
    endfunction

    function automatic bit ref_move_is_promotion(input FullBoard board, input Move move);
        automatic Tile start_tile = norm_tile(board.tiles[move.from_pos]);

        return (start_tile.piece_type == PAWN
            && start_tile.piece_color == board.turn
            && (getRank(move.to_pos) == BoardRank'('d0) || getRank(move.to_pos) == BoardRank'('d7)));
    endfunction

    function automatic int ref_promotion_edge_index(input Move move, input Color moving_color);
        automatic int from_file = int'(getFile(move.from_pos));
        automatic int to_file = int'(getFile(move.to_pos));
        automatic int edge_idx = from_file;

        if (to_file < from_file) begin
            edge_idx = 8 + to_file;
        end else if (to_file > from_file) begin
            edge_idx = 15 + from_file;
        end

        return (moving_color == WHITE) ? edge_idx : (22 + edge_idx);
    endfunction

    function automatic int ref_normal_edge_mask_index(input Move move);
        automatic int from_rank = int'(getRank(move.from_pos));
        automatic int to_rank = int'(getRank(move.to_pos));
        automatic int from_file = int'(getFile(move.from_pos));
        automatic int to_file = int'(getFile(move.to_pos));
        automatic int rank_delta = to_rank - from_rank;
        automatic int file_delta = to_file - from_file;
        automatic Direction dir;

        if (rank_delta == 2 && file_delta == 1) begin
            return NNE_SSW_KNIGHT_MASK_OFFSET + (from_file * 6) + from_rank;
        end else if (rank_delta == -2 && file_delta == -1) begin
            return NNE_SSW_KNIGHT_MASK_OFFSET + (to_file * 6) + to_rank;
        end else if (rank_delta == 1 && file_delta == 2) begin
            return NEE_SWW_KNIGHT_MASK_OFFSET + (from_file * 7) + from_rank;
        end else if (rank_delta == -1 && file_delta == -2) begin
            return NEE_SWW_KNIGHT_MASK_OFFSET + (to_file * 7) + to_rank;
        end else if (rank_delta == -1 && file_delta == 2) begin
            return SEE_NWW_KNIGHT_MASK_OFFSET + (from_file * 7) + to_rank;
        end else if (rank_delta == 1 && file_delta == -2) begin
            return SEE_NWW_KNIGHT_MASK_OFFSET + (to_file * 7) + from_rank;
        end else if (rank_delta == -2 && file_delta == 1) begin
            return SSE_NNW_KNIGHT_MASK_OFFSET + (from_file * 6) + to_rank;
        end else if (rank_delta == 2 && file_delta == -1) begin
            return SSE_NNW_KNIGHT_MASK_OFFSET + (to_file * 6) + from_rank;
        end

        dir = ref_move_dir(move.from_pos, move.to_pos);
        case (dir)
            NORTH:      return NS_MASK_OFFSET + (to_file * 7) + (to_rank - 1);
            SOUTH:      return NS_MASK_OFFSET + (to_file * 7) + to_rank;
            EAST:       return EW_MASK_OFFSET + ((to_file - 1) * 8) + to_rank;
            WEST:       return EW_MASK_OFFSET + (to_file * 8) + to_rank;
            NORTH_EAST: return POS_DIAG_MASK_OFFSET + ((to_file - 1) * 7) + (to_rank - 1);
            SOUTH_WEST: return POS_DIAG_MASK_OFFSET + (to_file * 7) + to_rank;
            SOUTH_EAST: return NEG_DIAG_MASK_OFFSET + ((to_file - 1) * 7) + to_rank;
            NORTH_WEST: return NEG_DIAG_MASK_OFFSET + (to_file * 7) + (to_rank - 1);
            default:    return 0;
        endcase
    endfunction

    function automatic int ref_castling_mask_index(input Move move, input Color moving_color);
        if (moving_color == WHITE) begin
            return CASTLING_MASK_OFFSET + ((move.to_pos == Position'('d6)) ? 0 : 1);
        end

        return CASTLING_MASK_OFFSET + ((move.to_pos == Position'('d62)) ? 2 : 3);
    endfunction

    function automatic MoveMaskIndex ref_candidate_index(input FullBoard board, input Move move);
        automatic int index;

        if (ref_move_is_promotion(board, move)) begin
            index = PROMOTION_MASK_OFFSET + (ref_promotion_edge_index(move, board.turn) * 4) + int'(move.promo_piece);
        end else if (ref_is_castle_move(board, move)) begin
            index = ref_castling_mask_index(move, board.turn);
        end else begin
            index = ref_normal_edge_mask_index(move);
        end

        return MoveMaskIndex'(index);
    endfunction

    function automatic bit ref_is_ep_move(input FullBoard board, input Move move);
        automatic Tile start_tile = norm_tile(board.tiles[move.from_pos]);
        automatic Tile end_tile = norm_tile(board.tiles[move.to_pos]);

        return (start_tile.piece_type == PAWN
            && start_tile.piece_color == board.turn
            && board.has_ep
            && board.ep_file == getFile(move.to_pos)
            && end_tile.piece_type == NULL_PIECE
            && (   (board.turn == WHITE && getRank(move.to_pos) == BoardRank'('d5) && getRank(move.from_pos) == BoardRank'('d4))
                || (board.turn == BLACK && getRank(move.to_pos) == BoardRank'('d2) && getRank(move.from_pos) == BoardRank'('d3))));
    endfunction

    function automatic bit ref_square_attacked(input FullBoard board, input Position square, input Color attacker_color);
        automatic Position test_pos;
        automatic Tile test_tile;
        automatic bit ray_done;

        if (attacker_color == WHITE) begin
            if (isShiftOnBoard(square, SOUTH_WEST, 3'd1) && norm_tile(board.tiles[shiftPos(square, SOUTH_WEST, 3'd1)]) == WHITE_PAWN) return 1'b1;
            if (isShiftOnBoard(square, SOUTH_EAST, 3'd1) && norm_tile(board.tiles[shiftPos(square, SOUTH_EAST, 3'd1)]) == WHITE_PAWN) return 1'b1;
        end else begin
            if (isShiftOnBoard(square, NORTH_WEST, 3'd1) && norm_tile(board.tiles[shiftPos(square, NORTH_WEST, 3'd1)]) == BLACK_PAWN) return 1'b1;
            if (isShiftOnBoard(square, NORTH_EAST, 3'd1) && norm_tile(board.tiles[shiftPos(square, NORTH_EAST, 3'd1)]) == BLACK_PAWN) return 1'b1;
        end

        for (int knight_dir = 0; knight_dir < 8; knight_dir++) begin
            if (isKnightShiftOnBoard(square, KnightDirection'(knight_dir))) begin
                test_pos = shiftKnightPos(square, KnightDirection'(knight_dir));
                if (norm_tile(board.tiles[test_pos]) == Tile'({attacker_color, KNIGHT})) return 1'b1;
            end
        end

        for (int dir_idx = 0; dir_idx < 8; dir_idx++) begin
            automatic Direction dir = Direction'(dir_idx);
            ray_done = 1'b0;
            for (int distance = 1; distance < 8; distance++) begin
                if (!ray_done && isShiftOnBoard(square, dir, dist_to_shift(distance))) begin
                    test_pos = shiftPos(square, dir, dist_to_shift(distance));
                    test_tile = norm_tile(board.tiles[test_pos]);
                    if (test_tile.piece_type != NULL_PIECE) begin
                        if (test_tile.piece_color == attacker_color) begin
                            if (distance == 1 && test_tile.piece_type == KING) return 1'b1;
                            if (test_tile.piece_type == QUEEN) return 1'b1;
                            if (test_tile.piece_type == ROOK && isDirCardinal(dir)) return 1'b1;
                            if (test_tile.piece_type == BISHOP && isDirDiag(dir)) return 1'b1;
                        end
                        ray_done = 1'b1;
                    end
                end
            end
        end

        return 1'b0;
    endfunction

    function automatic bit ref_is_pseudo_legal(input FullBoard board, input Move move);
        automatic Tile start_tile = norm_tile(board.tiles[move.from_pos]);
        automatic Tile end_tile = norm_tile(board.tiles[move.to_pos]);
        automatic int rank_delta = int'(getRank(move.to_pos)) - int'(getRank(move.from_pos));
        automatic int file_delta = int'(getFile(move.to_pos)) - int'(getFile(move.from_pos));
        automatic Position mid_pos;

        if (move.from_pos == move.to_pos) return 1'b0;
        if (start_tile.piece_type == NULL_PIECE || start_tile.piece_color != board.turn) return 1'b0;
        if (end_tile.piece_type != NULL_PIECE && end_tile.piece_color == board.turn) return 1'b0;

        case (start_tile.piece_type)
            PAWN: begin
                if (board.turn == WHITE) begin
                    if (file_delta == 0 && rank_delta == 1 && end_tile.piece_type == NULL_PIECE) return 1'b1;
                    if (file_delta == 0 && rank_delta == 2 && getRank(move.from_pos) == BoardRank'('d1) && end_tile.piece_type == NULL_PIECE) begin
                        mid_pos = getPosition(BoardRank'(getRank(move.from_pos) + 1'b1), getFile(move.from_pos));
                        return ref_tile_empty(board, mid_pos);
                    end
                    if (abs_int(file_delta) == 1 && rank_delta == 1 && end_tile.piece_type != NULL_PIECE && end_tile.piece_color == BLACK) return 1'b1;
                    return ref_is_ep_move(board, move);
                end else begin
                    if (file_delta == 0 && rank_delta == -1 && end_tile.piece_type == NULL_PIECE) return 1'b1;
                    if (file_delta == 0 && rank_delta == -2 && getRank(move.from_pos) == BoardRank'('d6) && end_tile.piece_type == NULL_PIECE) begin
                        mid_pos = getPosition(BoardRank'(getRank(move.from_pos) - 1'b1), getFile(move.from_pos));
                        return ref_tile_empty(board, mid_pos);
                    end
                    if (abs_int(file_delta) == 1 && rank_delta == -1 && end_tile.piece_type != NULL_PIECE && end_tile.piece_color == WHITE) return 1'b1;
                    return ref_is_ep_move(board, move);
                end
            end

            KNIGHT: return ((abs_int(rank_delta) == 2 && abs_int(file_delta) == 1) || (abs_int(rank_delta) == 1 && abs_int(file_delta) == 2));
            BISHOP: return ref_diag_move(move.from_pos, move.to_pos) && ref_path_clear(board, move.from_pos, move.to_pos);
            ROOK:   return ref_line_move(move.from_pos, move.to_pos) && ref_path_clear(board, move.from_pos, move.to_pos);
            QUEEN:  return (ref_line_move(move.from_pos, move.to_pos) || ref_diag_move(move.from_pos, move.to_pos)) && ref_path_clear(board, move.from_pos, move.to_pos);

            KING: begin
                if (abs_int(rank_delta) <= 1 && abs_int(file_delta) <= 1) return 1'b1;
                if (!ref_is_castle_move(board, move)) return 1'b0;
                if (board.turn == WHITE && move.to_pos == Position'('d6)) begin
                    return board.castle_perms.white_kingside && ref_tile_empty(board, Position'('d5)) && ref_tile_empty(board, Position'('d6)) && norm_tile(board.tiles[Position'('d7)]) == WHITE_ROOK;
                end
                if (board.turn == WHITE && move.to_pos == Position'('d2)) begin
                    return board.castle_perms.white_queenside && ref_tile_empty(board, Position'('d1)) && ref_tile_empty(board, Position'('d2)) && ref_tile_empty(board, Position'('d3)) && norm_tile(board.tiles[Position'('d0)]) == WHITE_ROOK;
                end
                if (board.turn == BLACK && move.to_pos == Position'('d62)) begin
                    return board.castle_perms.black_kingside && ref_tile_empty(board, Position'('d61)) && ref_tile_empty(board, Position'('d62)) && norm_tile(board.tiles[Position'('d63)]) == BLACK_ROOK;
                end
                if (board.turn == BLACK && move.to_pos == Position'('d58)) begin
                    return board.castle_perms.black_queenside && ref_tile_empty(board, Position'('d57)) && ref_tile_empty(board, Position'('d58)) && ref_tile_empty(board, Position'('d59)) && norm_tile(board.tiles[Position'('d56)]) == BLACK_ROOK;
                end
                return 1'b0;
            end

            default: return 1'b0;
        endcase
    endfunction

    function automatic FullBoard ref_apply_move(input FullBoard board, input Move move);
        automatic FullBoard next_board = board;
        automatic Tile start_tile = norm_tile(board.tiles[move.from_pos]);
        automatic Tile end_tile = norm_tile(board.tiles[move.to_pos]);
        automatic bit is_ep = ref_is_ep_move(board, move);
        automatic bit is_castle = ref_is_castle_move(board, move);
        automatic Position ep_capture_pos = getPosition(getRank(move.from_pos), getFile(move.to_pos));
        automatic Position rook_from = ref_castle_rook_from(move.to_pos);
        automatic Position rook_to = ref_castle_rook_to(move.to_pos);
        automatic PieceType placed_piece = (start_tile.piece_type == PAWN && (getRank(move.to_pos) == BoardRank'('d0) || getRank(move.to_pos) == BoardRank'('d7)))
            ? ref_promo_to_piece(move.promo_piece)
            : start_tile.piece_type;

        next_board.tiles[move.from_pos] = EMPTY_TILE;
        next_board.tiles[move.to_pos] = Tile'({start_tile.piece_color, placed_piece});

        if (is_ep) begin
            next_board.tiles[ep_capture_pos] = EMPTY_TILE;
        end

        if (is_castle) begin
            next_board.tiles[rook_from] = EMPTY_TILE;
            next_board.tiles[rook_to] = Tile'({start_tile.piece_color, ROOK});
        end

        if (move.from_pos == Position'('d4)  || move.from_pos == Position'('d7)  || move.to_pos == Position'('d7))  next_board.castle_perms.white_kingside = 1'b0;
        if (move.from_pos == Position'('d4)  || move.from_pos == Position'('d0)  || move.to_pos == Position'('d0))  next_board.castle_perms.white_queenside = 1'b0;
        if (move.from_pos == Position'('d60) || move.from_pos == Position'('d63) || move.to_pos == Position'('d63)) next_board.castle_perms.black_kingside = 1'b0;
        if (move.from_pos == Position'('d60) || move.from_pos == Position'('d56) || move.to_pos == Position'('d56)) next_board.castle_perms.black_queenside = 1'b0;

        next_board.has_ep = (start_tile.piece_type == PAWN
            && (   (start_tile.piece_color == WHITE && getRank(move.from_pos) == BoardRank'('d1) && getRank(move.to_pos) == BoardRank'('d3))
                || (start_tile.piece_color == BLACK && getRank(move.from_pos) == BoardRank'('d6) && getRank(move.to_pos) == BoardRank'('d4))));
        next_board.ep_file = getFile(move.to_pos);
        next_board.turn = Color'(~board.turn);
        next_board.halfmove_clock = (start_tile.piece_type == PAWN || end_tile.piece_type != NULL_PIECE || is_ep) ? HalfmoveClock'(0) : board.halfmove_clock + HalfmoveClock'(1);

        return next_board;
    endfunction

    function automatic bit ref_is_legal(input FullBoard board, input Move move);
        automatic FullBoard next_board;
        automatic Move transit_move;
        automatic Position transit_pos;

        if (!ref_is_pseudo_legal(board, move)) begin
            return 1'b0;
        end

        if (ref_is_castle_move(board, move)) begin
            if (ref_square_attacked(board, move.from_pos, Color'(~board.turn))) begin
                return 1'b0;
            end

            transit_pos = (getFile(move.to_pos) == BoardFile'('d6))
                ? getPosition(getRank(move.from_pos), BoardFile'('d5))
                : getPosition(getRank(move.from_pos), BoardFile'('d3));
            transit_move = move;
            transit_move.to_pos = transit_pos;
            next_board = ref_apply_move(board, transit_move);
            if (ref_square_attacked(next_board, transit_pos, Color'(~board.turn))) begin
                return 1'b0;
            end
        end

        next_board = ref_apply_move(board, move);
        return !ref_square_attacked(next_board, ref_find_king(next_board, board.turn), Color'(~board.turn));
    endfunction

    function automatic int ref_perft(input FullBoard board, input int depth);
        automatic int nodes = 0;
        automatic Move move;
        automatic FullBoard child;
        automatic bit is_promotion;

        if (depth == 0) begin
            return 1;
        end

        for (int from_pos = 0; from_pos < 64; from_pos++) begin
            if (norm_tile(board.tiles[from_pos]).piece_color == board.turn && norm_tile(board.tiles[from_pos]).piece_type != NULL_PIECE) begin
                for (int to_pos = 0; to_pos < 64; to_pos++) begin
                    for (int promo_idx = 0; promo_idx < 4; promo_idx++) begin
                        move = make_move(Position'(from_pos), Position'(to_pos), PromoType'(promo_idx));
                        is_promotion = ref_move_is_promotion(board, move);
                        if (is_promotion || promo_idx == 0) begin
                            if (ref_is_legal(board, move)) begin
                                child = ref_apply_move(board, move);
                                nodes += ref_perft(child, depth - 1);
                            end
                        end
                    end
                end
            end
        end

        return nodes;
    endfunction

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

    task automatic drive_idle();
        move_gen_op = MOVE_GEN_IDLE_OP;
        start_node = 1'b0;
        thread_id = ThreadID'(0);
        ply = PlyIndex'(0);
        target_move = NULL_MOVE;
        turn = WHITE;
        castle_perms = CastlePerms'(4'b0000);
        has_ep = 1'b0;
        ep_file = BoardFile'(0);
        for (int pos = 0; pos < 64; pos++) begin
            board_tiles[pos] = EMPTY_TILE;
        end
    endtask

    task automatic drive_board(input FullBoard board);
        for (int pos = 0; pos < 64; pos++) begin
            board_tiles[pos] = board.tiles[pos];
        end

        turn = board.turn;
        castle_perms = board.castle_perms;
        has_ep = board.has_ep;
        ep_file = board.ep_file;
    endtask

    function automatic bit is_null_move_value(input Move move);
        return (move.from_pos == 6'd0 && move.to_pos == 6'd0);
    endfunction

    task automatic dispatch_dut_candidate(
        input FullBoard board,
        input MoveGenOp op,
        input bit is_first_request,
        input Move target,
        output Move move,
        output logic legal
    );
        automatic bit captured = 1'b0;

        drive_board(board);
        move_gen_op = op;
        start_node = is_first_request;
        thread_id = ThreadID'(0);
        ply = PlyIndex'(0);
        target_move = target;
        do_clock(1);
        drive_idle();
        move = NULL_MOVE;
        legal = 1'b0;
        for (int wait_cycle = 0; wait_cycle < DUT_OUTPUT_LATENCY + 4; wait_cycle++) begin
            do_clock(1);
            if (!captured && !is_null_move_value(candidate_move)) begin
                move = candidate_move;
                legal = move_is_legal;
                captured = 1'b1;
            end
        end
    endtask

    task automatic collect_dut_candidates(
        input string test_name,
        input FullBoard board,
        input MoveGenOp op,
        output int candidate_count,
        output int legal_count
    );
        automatic Move move;
        automatic logic legal;
        automatic MoveMask seen = MoveMask'('0);
        automatic MoveMaskIndex idx;
        automatic bit done = 1'b0;

        candidate_count = 0;
        legal_count = 0;

        for (int iter = 0; iter < MAX_DUT_CANDIDATES; iter++) begin
            dispatch_dut_candidate(board, op, iter == 0, NULL_MOVE, move, legal);
            if (is_null_move_value(move)) begin
                done = 1'b1;
                break;
            end

            idx = ref_candidate_index(board, move);
            expect_equal(!seen[idx], $sformatf("%s duplicate candidate %0d->%0d promo=%0d", test_name, move.from_pos, move.to_pos, move.promo_piece));
            seen[idx] = 1'b1;
            candidate_count += 1;
            if (legal) begin
                legal_count += 1;
            end
        end

        expect_equal(done, {test_name, " reached NULL_MOVE"});
    endtask

    task automatic run_legality_case(input string test_name, input FullBoard board, input Move move, input bit expected_legal);
        automatic bit ref_legal = ref_is_legal(board, move);
        automatic bit dut_legal;

        expect_equal(ref_legal == expected_legal,
            $sformatf("%s reference legality expected=%0d found=%0d", test_name, expected_legal, ref_legal));

        drive_board(board);
        target_move = move;
        move_gen_op = MOVE_GEN_IDLE_OP;
        #1;
        dut_legal = dut.is_strictly_legal_move(board_tiles, move, board.turn, board.castle_perms, board.has_ep, board.ep_file);
        expect_equal(dut_legal === expected_legal,
            $sformatf("%s DUT strict legality expected=%0d found=%0d", test_name, expected_legal, dut_legal));

        drive_idle();
    endtask

    task automatic setup_kings(output FullBoard board, input Color side_to_move);
        init_empty_board(board);
        board.tiles[Position'('d4)] = WHITE_KING;
        board.tiles[Position'('d60)] = BLACK_KING;
        board.turn = side_to_move;
    endtask

    task automatic setup_start_position(output FullBoard board);
        init_empty_board(board);
        board.tiles[Position'(0)] = WHITE_ROOK;
        board.tiles[Position'(1)] = WHITE_KNIGHT;
        board.tiles[Position'(2)] = WHITE_BISHOP;
        board.tiles[Position'(3)] = WHITE_QUEEN;
        board.tiles[Position'(4)] = WHITE_KING;
        board.tiles[Position'(5)] = WHITE_BISHOP;
        board.tiles[Position'(6)] = WHITE_KNIGHT;
        board.tiles[Position'(7)] = WHITE_ROOK;
        for (int pos = 8; pos < 16; pos++) begin
            board.tiles[pos] = WHITE_PAWN;
        end
        for (int pos = 48; pos < 56; pos++) begin
            board.tiles[pos] = BLACK_PAWN;
        end
        board.tiles[Position'(56)] = BLACK_ROOK;
        board.tiles[Position'(57)] = BLACK_KNIGHT;
        board.tiles[Position'(58)] = BLACK_BISHOP;
        board.tiles[Position'(59)] = BLACK_QUEEN;
        board.tiles[Position'(60)] = BLACK_KING;
        board.tiles[Position'(61)] = BLACK_BISHOP;
        board.tiles[Position'(62)] = BLACK_KNIGHT;
        board.tiles[Position'(63)] = BLACK_ROOK;
        board.turn = WHITE;
        board.castle_perms = CastlePerms'(4'b1111);
    endtask

    task automatic test_pins_and_checks();
        automatic FullBoard board;

        setup_kings(board, WHITE);
        board.tiles[Position'('d12)] = WHITE_ROOK;
        board.tiles[Position'('d60)] = BLACK_ROOK;
        board.tiles[Position'('d63)] = BLACK_KING;
        run_legality_case("pinned rook off pin line", board, make_move(Position'('d12), Position'('d11), PROMO_QUEEN), 1'b0);
        run_legality_case("pinned rook along pin line", board, make_move(Position'('d12), Position'('d20), PROMO_QUEEN), 1'b1);

        setup_kings(board, WHITE);
        board.tiles[Position'('d60)] = BLACK_ROOK;
        board.tiles[Position'('d63)] = BLACK_KING;
        board.tiles[Position'('d11)] = WHITE_BISHOP;
        board.tiles[Position'('d6)] = WHITE_KNIGHT;
        run_legality_case("single check unrelated knight move", board, make_move(Position'('d6), Position'('d21), PROMO_QUEEN), 1'b0);
        run_legality_case("single check bishop block", board, make_move(Position'('d11), Position'('d20), PROMO_QUEEN), 1'b1);

        setup_kings(board, WHITE);
        board.tiles[Position'('d60)] = BLACK_ROOK;
        board.tiles[Position'('d63)] = BLACK_KING;
        board.tiles[Position'('d31)] = BLACK_BISHOP;
        board.tiles[Position'('d11)] = WHITE_BISHOP;
        run_legality_case("double check non-king block", board, make_move(Position'('d11), Position'('d20), PROMO_QUEEN), 1'b0);
    endtask

    task automatic test_king_castle_and_ep();
        automatic FullBoard board;

        setup_kings(board, WHITE);
        board.tiles[Position'('d60)] = BLACK_ROOK;
        board.tiles[Position'('d63)] = BLACK_KING;
        run_legality_case("king moves onto attacked file", board, make_move(Position'('d4), Position'('d12), PROMO_QUEEN), 1'b0);

        setup_kings(board, WHITE);
        board.tiles[Position'('d7)] = WHITE_ROOK;
        board.tiles[Position'('d56)] = BLACK_KING;
        board.castle_perms.white_kingside = 1'b1;
        run_legality_case("legal white kingside castle", board, make_move(Position'('d4), Position'('d6), PROMO_QUEEN), 1'b1);

        setup_kings(board, WHITE);
        board.tiles[Position'('d7)] = WHITE_ROOK;
        board.tiles[Position'('d56)] = BLACK_KING;
        board.tiles[Position'('d61)] = BLACK_ROOK;
        board.castle_perms.white_kingside = 1'b1;
        run_legality_case("castle through attacked transit", board, make_move(Position'('d4), Position'('d6), PROMO_QUEEN), 1'b0);

        init_empty_board(board);
        board.tiles[Position'('d36)] = WHITE_KING;
        board.tiles[Position'('d37)] = WHITE_PAWN;
        board.tiles[Position'('d38)] = BLACK_PAWN;
        board.tiles[Position'('d39)] = BLACK_ROOK;
        board.tiles[Position'('d56)] = BLACK_KING;
        board.turn = WHITE;
        board.has_ep = 1'b1;
        board.ep_file = BoardFile'('d6);
        run_legality_case("en passant discovered check", board, make_move(Position'('d37), Position'('d46), PROMO_QUEEN), 1'b0);
    endtask

    task automatic test_small_reference_perft();
        automatic FullBoard board;
        automatic int depth1;
        automatic int depth2;

        init_empty_board(board);
        board.tiles[Position'('d4)] = WHITE_KING;
        board.tiles[Position'('d60)] = BLACK_KING;
        board.turn = WHITE;

        depth1 = ref_perft(board, 1);
        depth2 = ref_perft(board, 2);

        $display("Reference perft kings-only depth 1: %0d", depth1);
        $display("Reference perft kings-only depth 2: %0d", depth2);
        expect_equal(depth1 == 5, $sformatf("kings-only perft depth 1 expected=5 found=%0d", depth1));
        expect_equal(depth2 == 25, $sformatf("kings-only perft depth 2 expected=25 found=%0d", depth2));
    endtask

    task automatic test_dut_streaming_perft();
        automatic FullBoard board;
        automatic int candidates;
        automatic int legal;
        automatic int ref_nodes;

        init_empty_board(board);
        board.tiles[Position'('d4)] = WHITE_KING;
        board.tiles[Position'('d60)] = BLACK_KING;
        board.turn = WHITE;
        collect_dut_candidates("kings-only normal", board, MOVE_GEN_NORMAL_OP, candidates, legal);
        expect_equal(legal == ref_perft(board, 1), $sformatf("kings-only DUT legal count expected=%0d found=%0d", ref_perft(board, 1), legal));
        expect_equal(ref_perft(board, 2) == 25, $sformatf("kings-only reference depth 2 expected=25 found=%0d", ref_perft(board, 2)));

        setup_start_position(board);
        collect_dut_candidates("initial normal", board, MOVE_GEN_NORMAL_OP, candidates, legal);
        expect_equal(legal == 20, $sformatf("initial DUT legal count expected=20 found=%0d", legal));
        collect_dut_candidates("initial qsearch", board, MOVE_GEN_QSEARCH_OP, candidates, legal);
        expect_equal(candidates == 0 && legal == 0, $sformatf("initial qsearch expected=0/0 found=%0d/%0d", candidates, legal));

        setup_kings(board, WHITE);
        board.tiles[Position'('d7)] = WHITE_ROOK;
        board.tiles[Position'('d56)] = BLACK_KING;
        board.castle_perms.white_kingside = 1'b1;
        collect_dut_candidates("castling normal", board, MOVE_GEN_NORMAL_OP, candidates, legal);
        expect_equal(legal == ref_perft(board, 1), $sformatf("castling DUT legal count expected=%0d found=%0d", ref_perft(board, 1), legal));

        init_empty_board(board);
        board.tiles[Position'('d36)] = WHITE_KING;
        board.tiles[Position'('d37)] = WHITE_PAWN;
        board.tiles[Position'('d38)] = BLACK_PAWN;
        board.tiles[Position'('d56)] = BLACK_KING;
        board.turn = WHITE;
        board.has_ep = 1'b1;
        board.ep_file = BoardFile'('d6);
        collect_dut_candidates("en passant normal", board, MOVE_GEN_NORMAL_OP, candidates, legal);
        expect_equal(legal == ref_perft(board, 1), $sformatf("en passant DUT legal count expected=%0d found=%0d", ref_perft(board, 1), legal));

        init_empty_board(board);
        board.tiles[Position'('d4)] = WHITE_KING;
        board.tiles[Position'('d48)] = WHITE_PAWN;
        board.tiles[Position'('d60)] = BLACK_KING;
        board.turn = WHITE;
        collect_dut_candidates("promotion normal", board, MOVE_GEN_NORMAL_OP, candidates, legal);
        ref_nodes = ref_perft(board, 1);
        expect_equal(legal == ref_nodes, $sformatf("promotion DUT legal count expected=%0d found=%0d", ref_nodes, legal));
        collect_dut_candidates("promotion qsearch", board, MOVE_GEN_QSEARCH_OP, candidates, legal);
        expect_equal(legal == 4, $sformatf("promotion qsearch legal count expected=4 found=%0d", legal));

        setup_kings(board, WHITE);
        board.tiles[Position'('d12)] = WHITE_ROOK;
        board.tiles[Position'('d60)] = BLACK_ROOK;
        board.tiles[Position'('d63)] = BLACK_KING;
        collect_dut_candidates("pinned normal", board, MOVE_GEN_NORMAL_OP, candidates, legal);
        expect_equal(candidates > legal, $sformatf("pinned normal expected at least one illegal consumed candidate found candidates=%0d legal=%0d", candidates, legal));
        expect_equal(legal == ref_perft(board, 1), $sformatf("pinned DUT legal count expected=%0d found=%0d", ref_perft(board, 1), legal));
    endtask

    initial begin
        clk = 1'b0;
        rst_n = 1'b0;
        drive_idle();
        do_clock(2);
        rst_n = 1'b1;
        do_clock(2);

        $display("=== Move generator testbench ===");
        test_pins_and_checks();
        test_king_castle_and_ep();
        test_small_reference_perft();
        test_dut_streaming_perft();

        $display("Testbench run complete.");
        $display("Pass Count: %0d", pass_count);
        $display("Fail Count: %0d", error_count);

        if (error_count == 0) begin
            $finish;
        end else begin
            $fatal(1, "move_generator testbench failed");
        end
    end

    initial begin
        #1000000;
        $fatal(1, "move_generator testbench timed out");
    end

endmodule : tb_move_generator
