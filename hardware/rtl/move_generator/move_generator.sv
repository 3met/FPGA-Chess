
// By Emet Behrendt

import general_chess_defs::*;
import chess_helper_funcs::*;
import move_generator_defs::*;


module move_generator #(parameter MAX_PLY_COUNT, parameter THREAD_COUNT) (
    input logic clk,
    input logic rst_n,

    // Move Generation Config
    input MoveGenOp move_gen_op,
    input logic start_node,
    input ThreadID thread_id,
    input PlyIndex ply,
    input Move target_move,

    // Board Data
    input Tile             board_tiles[64],
    input Color            turn,
    input CastlePerms      castle_perms,
    input logic            has_ep,
    input BoardFile        ep_file,
    // input reg [6:0]   halfmove_clock, // Unused?

    // Generated Output
    output Move candidate_move,
    output logic move_is_legal
);

    localparam int MASK_ENTRY_COUNT = THREAD_COUNT * MAX_PLY_COUNT;
    localparam int MASK_ADDR_BITS = $clog2(MASK_ENTRY_COUNT);

    typedef logic [MASK_ADDR_BITS-1:0] MoveMaskAddr;
    typedef logic [2:0] RayDistance;

    Move candidate_move_pipe[MOVE_GEN_STAGE_CNT];
    logic candidate_move_legal_pipe[MOVE_GEN_STAGE_CNT];
    MoveMaskAddr mask_rd_addr;
    MoveMaskAddr mask_wr_addr;
    logic mask_rd_en;
    logic mask_wr_en;
    MoveMask mask_rd_data;
    MoveMask request_consumed_mask;
    MoveMask proposal_consumed_mask_pipe[REDUCE_STAGE_CNT + 1];
    MoveMask next_consumed_mask;

    typedef struct packed {
        logic [1:0] count;
        Position first_checker;
        logic first_checker_is_slider;
        Direction first_checker_dir;
    } KingCheckInfo;

    typedef struct packed {
        logic is_pinned;
        Direction pin_dir;
    } PinInfo;

    localparam int TILE_SELECT_STAGE = PROP_STAGE_CNT;
    localparam int REDUCE_8_STAGE = TILE_SELECT_STAGE + 1;
    localparam int REDUCE_1_STAGE = REDUCE_8_STAGE + 1;
    localparam int LEGAL_STAGE = REDUCE_1_STAGE + 1;

    logic request_valid_pipe[MOVE_GEN_STAGE_CNT];
    logic start_node_pipe[MOVE_GEN_STAGE_CNT];
    MoveGenOp op_pipe[MOVE_GEN_STAGE_CNT];
    ThreadID thread_id_pipe[MOVE_GEN_STAGE_CNT];
    PlyIndex ply_pipe[MOVE_GEN_STAGE_CNT];
    Move target_move_pipe[MOVE_GEN_STAGE_CNT];
    Color turn_pipe[MOVE_GEN_STAGE_CNT];
    CastlePerms castle_perms_pipe[MOVE_GEN_STAGE_CNT];
    logic has_ep_pipe[MOVE_GEN_STAGE_CNT];
    BoardFile ep_file_pipe[MOVE_GEN_STAGE_CNT];
    Tile board_pipe[MOVE_GEN_STAGE_CNT][64];
    RayRecord ray_pipe[PROP_STAGE_CNT][64][8];
    Tile knight_tile[64][8];
    logic ray_consumed[64][8];
    logic knight_consumed[64][8];
    logic promotion_consumed[64][8][4];
    CandidateProposal tile_proposal_in[64];
    CandidateProposal tile_proposal_pipe[64];
    CandidateProposal reduce_8_pipe[8];
    CandidateProposal reduce_1_pipe;
    CandidateProposal castle_proposal_in;
    CandidateProposal castle_proposal_pipe;
    CandidateProposal reduced_proposal;
    logic reduced_proposal_legal;

    function automatic Tile normalize_tile(input Tile tile);
        if (tile.piece_type == NULL_PIECE) begin
            return EMPTY_TILE;
        end

        return tile;
    endfunction : normalize_tile

    function automatic int ray_max_distance(input Position pos, input Direction dir);
        automatic int rank = int'(getRank(pos));
        automatic int file = int'(getFile(pos));

        case (dir)
            NORTH:      return 7 - rank;
            NORTH_EAST: return ((7 - rank) < (7 - file)) ? (7 - rank) : (7 - file);
            EAST:       return 7 - file;
            SOUTH_EAST: return (rank < (7 - file)) ? rank : (7 - file);
            SOUTH:      return rank;
            SOUTH_WEST: return (rank < file) ? rank : file;
            WEST:       return file;
            NORTH_WEST: return ((7 - rank) < file) ? (7 - rank) : file;
            default:    return 0;
        endcase
    endfunction : ray_max_distance

    function automatic logic tile_is_empty(input Tile board[64], input Position pos);
        automatic Tile tile;

        tile = normalize_tile(board[pos]);
        return (tile.piece_type == NULL_PIECE);
    endfunction : tile_is_empty

    function automatic logic castle_perm(input CastlePerms perms, input int bit_index);
        return logic'(perms[bit_index]);
    endfunction : castle_perm

    function automatic PieceType promo_to_piece(input PromoType promo);
        case (promo)
            PROMO_QUEEN:  return QUEEN;
            PROMO_KNIGHT: return KNIGHT;
            PROMO_ROOK:   return ROOK;
            PROMO_BISHOP: return BISHOP;
            default:      return PieceType'('x);
        endcase
    endfunction : promo_to_piece

    function automatic Position castle_rook_from(input Position king_to);
        case (king_to)
            Position'('d2):  return Position'('d0);
            Position'('d6):  return Position'('d7);
            Position'('d58): return Position'('d56);
            Position'('d62): return Position'('d63);
            default:         return Position'('dx);
        endcase
    endfunction : castle_rook_from

    function automatic Position castle_rook_to(input Position king_to);
        case (king_to)
            Position'('d2):  return Position'('d3);
            Position'('d6):  return Position'('d5);
            Position'('d58): return Position'('d59);
            Position'('d62): return Position'('d61);
            default:         return Position'('dx);
        endcase
    endfunction : castle_rook_to

    function automatic logic same_abs_delta(input Position from_pos, input Position to_pos);
        automatic int rank_delta;
        automatic int file_delta;

        rank_delta = int'(getRank(to_pos)) - int'(getRank(from_pos));
        file_delta = int'(getFile(to_pos)) - int'(getFile(from_pos));
        if (rank_delta < 0) rank_delta = -rank_delta;
        if (file_delta < 0) file_delta = -file_delta;

        return (rank_delta == file_delta);
    endfunction : same_abs_delta

    function automatic logic [2:0] dist_to_shift(input int distance);
        return distance[2:0];
    endfunction : dist_to_shift

    function automatic logic is_diagonal_move(input Position from_pos, input Position to_pos);
        return (from_pos != to_pos && same_abs_delta(from_pos, to_pos));
    endfunction : is_diagonal_move

    function automatic logic is_cardinal_move(input Position from_pos, input Position to_pos);
        return (from_pos != to_pos && (getRank(from_pos) == getRank(to_pos) || getFile(from_pos) == getFile(to_pos)));
    endfunction : is_cardinal_move

    function automatic logic is_line_attacker(input PieceType piece, input Direction dir);
        return (piece == QUEEN || (piece == ROOK && isDirCardinal(dir)) || (piece == BISHOP && isDirDiag(dir)));
    endfunction : is_line_attacker

    function automatic Direction move_dir(input Position from_pos, input Position to_pos);
        automatic BoardRank from_rank;
        automatic BoardRank to_rank;
        automatic BoardFile from_file;
        automatic BoardFile to_file;

        from_rank = getRank(from_pos);
        to_rank = getRank(to_pos);
        from_file = getFile(from_pos);
        to_file = getFile(to_pos);

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
    endfunction : move_dir

    function automatic logic path_clear(input Tile board[64], input Position from_pos, input Position to_pos);
        automatic Direction dir;
        automatic Position pos;

        if (!(is_cardinal_move(from_pos, to_pos) || is_diagonal_move(from_pos, to_pos))) begin
            return 1'b0;
        end

        dir = move_dir(from_pos, to_pos);
        for (int distance=1; distance<8; distance++) begin
            pos = shiftPos(from_pos, dir, dist_to_shift(distance));
            if (pos == to_pos) begin
                return 1'b1;
            end

            if (!tile_is_empty(board, pos)) begin
                return 1'b0;
            end
        end

        return 1'b0;
    endfunction : path_clear

    function automatic Position find_king(input Tile board[64], input Color king_color);
        automatic Tile tile;

        for (int pos=0; pos<64; pos++) begin
            tile = normalize_tile(board[pos]);
            if (tile == Tile'({king_color, KING})) begin
                return Position'(pos);
            end
        end

        return Position'('dx);
    endfunction : find_king

    function automatic logic same_ray_from_origin(input Position origin, input Position target, input Direction ray_dir);
        if (origin == target) begin
            return 1'b0;
        end

        if (!(is_cardinal_move(origin, target) || is_diagonal_move(origin, target))) begin
            return 1'b0;
        end

        return (move_dir(origin, target) == ray_dir);
    endfunction : same_ray_from_origin

    function automatic logic square_on_ray_until(
        input Position origin,
        input Position target,
        input Direction ray_dir,
        input Position ray_end
    );
        automatic Position pos;

        for (int distance=1; distance<8; distance++) begin
            if (isShiftOnBoard(origin, ray_dir, dist_to_shift(distance))) begin
                pos = shiftPos(origin, ray_dir, dist_to_shift(distance));
                if (pos == target) begin
                    return 1'b1;
                end
                if (pos == ray_end) begin
                    return 1'b0;
                end
            end
        end

        return 1'b0;
    endfunction : square_on_ray_until

    function automatic KingCheckInfo get_check_info(input Tile board[64], input Position king_pos, input Color enemy_color);
        automatic KingCheckInfo info;
        automatic Position test_pos;
        automatic Tile test_tile;
        automatic logic ray_blocked;

        info.count = 2'd0;
        info.first_checker = Position'('dx);
        info.first_checker_is_slider = 1'b0;
        info.first_checker_dir = Direction'('dx);

        if (enemy_color == WHITE) begin
            if (isShiftOnBoard(king_pos, SOUTH_WEST, 3'd1)) begin
                test_pos = shiftPos(king_pos, SOUTH_WEST, 3'd1);
                if (normalize_tile(board[test_pos]) == WHITE_PAWN) begin
                    if (info.count != 2'd3) info.count += 2'd1;
                    if (info.count == 2'd1) info.first_checker = test_pos;
                end
            end
            if (isShiftOnBoard(king_pos, SOUTH_EAST, 3'd1)) begin
                test_pos = shiftPos(king_pos, SOUTH_EAST, 3'd1);
                if (normalize_tile(board[test_pos]) == WHITE_PAWN) begin
                    if (info.count != 2'd3) info.count += 2'd1;
                    if (info.count == 2'd1) info.first_checker = test_pos;
                end
            end
        end else begin
            if (isShiftOnBoard(king_pos, NORTH_WEST, 3'd1)) begin
                test_pos = shiftPos(king_pos, NORTH_WEST, 3'd1);
                if (normalize_tile(board[test_pos]) == BLACK_PAWN) begin
                    if (info.count != 2'd3) info.count += 2'd1;
                    if (info.count == 2'd1) info.first_checker = test_pos;
                end
            end
            if (isShiftOnBoard(king_pos, NORTH_EAST, 3'd1)) begin
                test_pos = shiftPos(king_pos, NORTH_EAST, 3'd1);
                if (normalize_tile(board[test_pos]) == BLACK_PAWN) begin
                    if (info.count != 2'd3) info.count += 2'd1;
                    if (info.count == 2'd1) info.first_checker = test_pos;
                end
            end
        end

        for (int knight_dir=0; knight_dir<8; knight_dir++) begin
            if (isKnightShiftOnBoard(king_pos, KnightDirection'(knight_dir))) begin
                test_pos = shiftKnightPos(king_pos, KnightDirection'(knight_dir));
                if (normalize_tile(board[test_pos]) == Tile'({enemy_color, KNIGHT})) begin
                    if (info.count != 2'd3) info.count += 2'd1;
                    if (info.count == 2'd1) info.first_checker = test_pos;
                end
            end
        end

        for (int dir_idx=0; dir_idx<8; dir_idx++) begin
            automatic Direction dir = Direction'(dir_idx);
            ray_blocked = 1'b0;
            for (int distance=1; distance<8; distance++) begin
                if (!ray_blocked && isShiftOnBoard(king_pos, dir, dist_to_shift(distance))) begin
                    test_pos = shiftPos(king_pos, dir, dist_to_shift(distance));
                    test_tile = normalize_tile(board[test_pos]);
                    if (test_tile.piece_type != NULL_PIECE) begin
                        if (test_tile.piece_color == enemy_color && is_line_attacker(test_tile.piece_type, dir)) begin
                            if (info.count != 2'd3) info.count += 2'd1;
                            if (info.count == 2'd1) begin
                                info.first_checker = test_pos;
                                info.first_checker_is_slider = 1'b1;
                                info.first_checker_dir = dir;
                            end
                        end
                        ray_blocked = 1'b1;
                    end
                end
            end
        end

        return info;
    endfunction : get_check_info

    function automatic PinInfo get_pin_info(input Tile board[64], input Position king_pos, input Position moving_pos, input Color moving_color);
        automatic PinInfo info;
        automatic Color enemy_color;
        automatic Position test_pos;
        automatic Tile test_tile;
        automatic logic found_candidate;
        automatic logic ray_done;

        info.is_pinned = 1'b0;
        info.pin_dir = Direction'('dx);
        enemy_color = Color'(~moving_color);

        for (int dir_idx=0; dir_idx<8; dir_idx++) begin
            automatic Direction dir = Direction'(dir_idx);
            found_candidate = 1'b0;
            ray_done = 1'b0;
            for (int distance=1; distance<8; distance++) begin
                if (!ray_done && isShiftOnBoard(king_pos, dir, dist_to_shift(distance))) begin
                    test_pos = shiftPos(king_pos, dir, dist_to_shift(distance));
                    test_tile = normalize_tile(board[test_pos]);
                    if (test_tile.piece_type != NULL_PIECE) begin
                        if (!found_candidate) begin
                            if (test_pos == moving_pos && test_tile.piece_color == moving_color) begin
                                found_candidate = 1'b1;
                            end else begin
                                ray_done = 1'b1;
                            end
                        end else begin
                            if (test_tile.piece_color == enemy_color && is_line_attacker(test_tile.piece_type, dir)) begin
                                info.is_pinned = 1'b1;
                                info.pin_dir = dir;
                            end
                            ray_done = 1'b1;
                        end
                    end
                end
            end
        end

        return info;
    endfunction : get_pin_info

    function automatic logic is_castle_move(input Tile board[64], input Move move, input Color moving_color);
        automatic Tile start_tile;

        start_tile = normalize_tile(board[move.from_pos]);
        return (start_tile.piece_type == KING
            && start_tile.piece_color == moving_color
            && (   (moving_color == WHITE && move.from_pos == Position'('d4)  && (move.to_pos == Position'('d2)  || move.to_pos == Position'('d6)))
                || (moving_color == BLACK && move.from_pos == Position'('d60) && (move.to_pos == Position'('d58) || move.to_pos == Position'('d62)))));
    endfunction : is_castle_move

    function automatic logic is_ep_move(input Tile board[64], input Move move, input Color moving_color, input logic ep_valid, input BoardFile ep_target_file);
        automatic Tile start_tile;
        automatic Tile end_tile;

        start_tile = normalize_tile(board[move.from_pos]);
        end_tile = normalize_tile(board[move.to_pos]);

        return (start_tile.piece_type == PAWN
            && start_tile.piece_color == moving_color
            && ep_valid
            && ep_target_file == getFile(move.to_pos)
            && end_tile.piece_type == NULL_PIECE
            && (   (moving_color == WHITE && getRank(move.to_pos) == BoardRank'('d5) && getRank(move.from_pos) == BoardRank'('d4))
                || (moving_color == BLACK && getRank(move.to_pos) == BoardRank'('d2) && getRank(move.from_pos) == BoardRank'('d3))));
    endfunction : is_ep_move

    function automatic logic is_ep_move_from_tiles(
        input Tile start_tile,
        input Tile end_tile,
        input Move move,
        input Color moving_color,
        input logic ep_valid,
        input BoardFile ep_target_file
    );
        return (start_tile.piece_type == PAWN
            && start_tile.piece_color == moving_color
            && ep_valid
            && ep_target_file == getFile(move.to_pos)
            && end_tile.piece_type == NULL_PIECE
            && (   (moving_color == WHITE && getRank(move.to_pos) == BoardRank'('d5) && getRank(move.from_pos) == BoardRank'('d4))
                || (moving_color == BLACK && getRank(move.to_pos) == BoardRank'('d2) && getRank(move.from_pos) == BoardRank'('d3))));
    endfunction : is_ep_move_from_tiles

    function automatic Tile tile_after_move(
        input Tile board[64],
        input Move move,
        input Position pos,
        input Color moving_color,
        input logic ep_move,
        input logic castle_move
    );
        automatic Tile start_tile;
        automatic Position ep_capture_pos;
        automatic Position rook_from;
        automatic Position rook_to;

        if (isNullMove(move)) begin
            return normalize_tile(board[pos]);
        end

        start_tile = normalize_tile(board[move.from_pos]);
        ep_capture_pos = getPosition(getRank(move.from_pos), getFile(move.to_pos));
        rook_from = castle_rook_from(move.to_pos);
        rook_to = castle_rook_to(move.to_pos);

        if (pos == move.from_pos) begin
            return EMPTY_TILE;
        end

        if (ep_move && pos == ep_capture_pos) begin
            return EMPTY_TILE;
        end

        if (castle_move && pos == rook_from) begin
            return EMPTY_TILE;
        end

        if (castle_move && pos == rook_to) begin
            return Tile'({moving_color, ROOK});
        end

        if (pos == move.to_pos) begin
            if (start_tile.piece_type == PAWN && (getRank(move.to_pos) == BoardRank'('d0) || getRank(move.to_pos) == BoardRank'('d7))) begin
                return Tile'({moving_color, promo_to_piece(move.promo_piece)});
            end

            return start_tile;
        end

        return normalize_tile(board[pos]);
    endfunction : tile_after_move

    function automatic logic square_attacked_after_move(
        input Tile board[64],
        input Position square,
        input Color attacker_color,
        input Move move,
        input Color moving_color,
        input logic ep_move,
        input logic castle_move
    );
        automatic Position test_pos;
        automatic Tile test_tile;

        if (attacker_color == WHITE) begin
            if (isShiftOnBoard(square, SOUTH_WEST, 3'd1)) begin
                test_pos = shiftPos(square, SOUTH_WEST, 3'd1);
                if (tile_after_move(board, move, test_pos, moving_color, ep_move, castle_move) == WHITE_PAWN) return 1'b1;
            end
            if (isShiftOnBoard(square, SOUTH_EAST, 3'd1)) begin
                test_pos = shiftPos(square, SOUTH_EAST, 3'd1);
                if (tile_after_move(board, move, test_pos, moving_color, ep_move, castle_move) == WHITE_PAWN) return 1'b1;
            end
        end else begin
            if (isShiftOnBoard(square, NORTH_WEST, 3'd1)) begin
                test_pos = shiftPos(square, NORTH_WEST, 3'd1);
                if (tile_after_move(board, move, test_pos, moving_color, ep_move, castle_move) == BLACK_PAWN) return 1'b1;
            end
            if (isShiftOnBoard(square, NORTH_EAST, 3'd1)) begin
                test_pos = shiftPos(square, NORTH_EAST, 3'd1);
                if (tile_after_move(board, move, test_pos, moving_color, ep_move, castle_move) == BLACK_PAWN) return 1'b1;
            end
        end

        for (int dir=0; dir<8; dir++) begin
            if (isKnightShiftOnBoard(square, KnightDirection'(dir))) begin
                test_pos = shiftKnightPos(square, KnightDirection'(dir));
                test_tile = tile_after_move(board, move, test_pos, moving_color, ep_move, castle_move);
                if (test_tile == Tile'({attacker_color, KNIGHT})) return 1'b1;
            end
        end

        for (int dir_idx=0; dir_idx<8; dir_idx++) begin
            automatic Direction dir = Direction'(dir_idx);
            if (isShiftOnBoard(square, dir, 3'd1)) begin
                test_pos = shiftPos(square, dir, 3'd1);
                test_tile = tile_after_move(board, move, test_pos, moving_color, ep_move, castle_move);
                if (test_tile == Tile'({attacker_color, KING})) return 1'b1;
            end
        end

        for (int dir_idx=0; dir_idx<8; dir_idx++) begin
            automatic Direction dir = Direction'(dir_idx);
            automatic logic blocked = 1'b0;
            for (int distance=1; distance<8; distance++) begin
                if (!blocked && isShiftOnBoard(square, dir, dist_to_shift(distance))) begin
                    test_pos = shiftPos(square, dir, dist_to_shift(distance));
                    test_tile = tile_after_move(board, move, test_pos, moving_color, ep_move, castle_move);
                    if (test_tile.piece_type != NULL_PIECE) begin
                        if (test_tile.piece_color == attacker_color) begin
                            if (test_tile.piece_type == QUEEN) return 1'b1;
                            if (test_tile.piece_type == ROOK && isDirCardinal(dir)) return 1'b1;
                            if (test_tile.piece_type == BISHOP && isDirDiag(dir)) return 1'b1;
                        end
                        blocked = 1'b1;
                    end
                end
            end
        end

        return 1'b0;
    endfunction : square_attacked_after_move

    function automatic logic is_pseudo_legal_move(
        input Tile board[64],
        input Move move,
        input Color moving_color,
        input CastlePerms curr_castle_perms,
        input logic ep_valid,
        input BoardFile ep_target_file
    );
        automatic Tile start_tile;
        automatic Tile end_tile;
        automatic int rank_delta;
        automatic int file_delta;
        automatic Position between_pos;

        if (isNullMove(move)) begin
            return 1'b0;
        end

        start_tile = normalize_tile(board[move.from_pos]);
        end_tile = normalize_tile(board[move.to_pos]);
        rank_delta = int'(getRank(move.to_pos)) - int'(getRank(move.from_pos));
        file_delta = int'(getFile(move.to_pos)) - int'(getFile(move.from_pos));

        if (start_tile.piece_type == NULL_PIECE || start_tile.piece_color != moving_color) begin
            return 1'b0;
        end

        if (end_tile.piece_type != NULL_PIECE && end_tile.piece_color == moving_color) begin
            return 1'b0;
        end

        case (start_tile.piece_type)
            PAWN: begin
                if (moving_color == WHITE) begin
                    if (file_delta == 0 && rank_delta == 1 && end_tile.piece_type == NULL_PIECE) return 1'b1;
                    if (file_delta == 0 && rank_delta == 2 && getRank(move.from_pos) == BoardRank'('d1) && end_tile.piece_type == NULL_PIECE) begin
                        between_pos = getPosition(BoardRank'(getRank(move.from_pos) + 3'd1), getFile(move.from_pos));
                        return tile_is_empty(board, between_pos);
                    end
                    if ((file_delta == 1 || file_delta == -1) && rank_delta == 1) begin
                        return ((end_tile.piece_type != NULL_PIECE && end_tile.piece_color == BLACK) || is_ep_move(board, move, moving_color, ep_valid, ep_target_file));
                    end
                end else begin
                    if (file_delta == 0 && rank_delta == -1 && end_tile.piece_type == NULL_PIECE) return 1'b1;
                    if (file_delta == 0 && rank_delta == -2 && getRank(move.from_pos) == BoardRank'('d6) && end_tile.piece_type == NULL_PIECE) begin
                        between_pos = getPosition(BoardRank'(getRank(move.from_pos) - 3'd1), getFile(move.from_pos));
                        return tile_is_empty(board, between_pos);
                    end
                    if ((file_delta == 1 || file_delta == -1) && rank_delta == -1) begin
                        return ((end_tile.piece_type != NULL_PIECE && end_tile.piece_color == WHITE) || is_ep_move(board, move, moving_color, ep_valid, ep_target_file));
                    end
                end
                return 1'b0;
            end

            KNIGHT: begin
                if (rank_delta < 0) rank_delta = -rank_delta;
                if (file_delta < 0) file_delta = -file_delta;
                return ((rank_delta == 2 && file_delta == 1) || (rank_delta == 1 && file_delta == 2));
            end

            BISHOP: return (is_diagonal_move(move.from_pos, move.to_pos) && path_clear(board, move.from_pos, move.to_pos));
            ROOK:   return (is_cardinal_move(move.from_pos, move.to_pos) && path_clear(board, move.from_pos, move.to_pos));
            QUEEN:  return ((is_cardinal_move(move.from_pos, move.to_pos) || is_diagonal_move(move.from_pos, move.to_pos)) && path_clear(board, move.from_pos, move.to_pos));

            KING: begin
                if (rank_delta < 0) rank_delta = -rank_delta;
                if (file_delta < 0) file_delta = -file_delta;
                if (rank_delta <= 1 && file_delta <= 1 && (rank_delta != 0 || file_delta != 0)) return 1'b1;

                if (is_castle_move(board, move, moving_color)) begin
                    if (moving_color == WHITE && move.to_pos == Position'('d6)) begin
                        return (castle_perm(curr_castle_perms, 3)
                            && tile_is_empty(board, Position'('d5))
                            && tile_is_empty(board, Position'('d6))
                            && normalize_tile(board[Position'('d7)]) == WHITE_ROOK);
                    end
                    if (moving_color == WHITE && move.to_pos == Position'('d2)) begin
                        return (castle_perm(curr_castle_perms, 2)
                            && tile_is_empty(board, Position'('d1))
                            && tile_is_empty(board, Position'('d2))
                            && tile_is_empty(board, Position'('d3))
                            && normalize_tile(board[Position'('d0)]) == WHITE_ROOK);
                    end
                    if (moving_color == BLACK && move.to_pos == Position'('d62)) begin
                        return (castle_perm(curr_castle_perms, 1)
                            && tile_is_empty(board, Position'('d61))
                            && tile_is_empty(board, Position'('d62))
                            && normalize_tile(board[Position'('d63)]) == BLACK_ROOK);
                    end
                    if (moving_color == BLACK && move.to_pos == Position'('d58)) begin
                        return (castle_perm(curr_castle_perms, 0)
                            && tile_is_empty(board, Position'('d57))
                            && tile_is_empty(board, Position'('d58))
                            && tile_is_empty(board, Position'('d59))
                            && normalize_tile(board[Position'('d56)]) == BLACK_ROOK);
                    end
                end

                return 1'b0;
            end

            default: return 1'b0;
        endcase
    endfunction : is_pseudo_legal_move

    function automatic Position king_pos_after_move(
        input Tile board[64],
        input Move move,
        input Color moving_color,
        input logic ep_move,
        input logic castle_move
    );
        automatic Tile test_tile;

        if (normalize_tile(board[move.from_pos]) == Tile'({moving_color, KING})) begin
            return move.to_pos;
        end

        for (int pos=0; pos<64; pos++) begin
            test_tile = tile_after_move(board, move, Position'(pos), moving_color, ep_move, castle_move);
            if (test_tile == Tile'({moving_color, KING})) begin
                return Position'(pos);
            end
        end

        return Position'('dx);
    endfunction : king_pos_after_move

    function automatic logic is_strictly_legal_move(
        input Tile board[64],
        input Move move,
        input Color moving_color,
        input CastlePerms curr_castle_perms,
        input logic ep_valid,
        input BoardFile ep_target_file
    );
        automatic Color enemy_color;
        automatic logic ep_move;
        automatic logic castle_move;
        automatic Position own_king_pos;
        automatic Move transit_move;
        automatic Position transit_pos;
        automatic Tile start_tile;

        enemy_color = Color'(~moving_color);
        ep_move = is_ep_move(board, move, moving_color, ep_valid, ep_target_file);
        castle_move = is_castle_move(board, move, moving_color);

        if (!is_pseudo_legal_move(board, move, moving_color, curr_castle_perms, ep_valid, ep_target_file)) begin
            return 1'b0;
        end

        start_tile = normalize_tile(board[move.from_pos]);

        if (start_tile.piece_type == KING) begin
            if (castle_move) begin
                if (square_attacked_after_move(board, move.from_pos, enemy_color, NULL_MOVE, moving_color, 1'b0, 1'b0)) begin
                    return 1'b0;
                end

                transit_pos = (getFile(move.to_pos) == BoardFile'('d6))
                    ? getPosition(getRank(move.from_pos), BoardFile'('d5))
                    : getPosition(getRank(move.from_pos), BoardFile'('d3));
                transit_move = move;
                transit_move.to_pos = transit_pos;

                if (square_attacked_after_move(board, transit_pos, enemy_color, transit_move, moving_color, 1'b0, 1'b0)) begin
                    return 1'b0;
                end
            end

            return !square_attacked_after_move(board, move.to_pos, enemy_color, move, moving_color, ep_move, castle_move);
        end

        own_king_pos = find_king(board, moving_color);
        return !square_attacked_after_move(board, own_king_pos, enemy_color, move, moving_color, ep_move, 1'b0);
    endfunction : is_strictly_legal_move

    function automatic int move_mask_addr(input ThreadID tid, input PlyIndex search_ply);
        return (int'(tid) * MAX_PLY_COUNT) + int'(search_ply);
    endfunction : move_mask_addr

    function automatic logic move_is_promotion(input Tile board[64], input Move move, input Color moving_color);
        automatic Tile start_tile;

        start_tile = normalize_tile(board[move.from_pos]);
        return (start_tile.piece_type == PAWN
            && start_tile.piece_color == moving_color
            && (getRank(move.to_pos) == BoardRank'('d0) || getRank(move.to_pos) == BoardRank'('d7)));
    endfunction : move_is_promotion

    function automatic int promotion_edge_index(input Move move, input Color moving_color);
        automatic int from_file;
        automatic int to_file;
        automatic int edge_idx;

        from_file = int'(getFile(move.from_pos));
        to_file = int'(getFile(move.to_pos));
        edge_idx = from_file;

        if (to_file < from_file) begin
            edge_idx = 8 + to_file;
        end else if (to_file > from_file) begin
            edge_idx = 15 + from_file;
        end

        return edge_idx;
    endfunction : promotion_edge_index

    function automatic int normal_edge_mask_index(input Move move);
        automatic int from_rank;
        automatic int to_rank;
        automatic int from_file;
        automatic int to_file;
        automatic int rank_delta;
        automatic int file_delta;
        automatic Direction dir;

        from_rank = int'(getRank(move.from_pos));
        to_rank = int'(getRank(move.to_pos));
        from_file = int'(getFile(move.from_pos));
        to_file = int'(getFile(move.to_pos));
        rank_delta = to_rank - from_rank;
        file_delta = to_file - from_file;

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

        dir = move_dir(move.from_pos, move.to_pos);
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
    endfunction : normal_edge_mask_index

    function automatic int castling_mask_index(input Move move, input Color moving_color);
        if (moving_color == WHITE) begin
            return CASTLING_MASK_OFFSET + ((move.to_pos == Position'('d6)) ? 0 : 1);
        end

        return CASTLING_MASK_OFFSET + ((move.to_pos == Position'('d62)) ? 0 : 1);
    endfunction : castling_mask_index

    function automatic MoveMaskIndex candidate_mask_index_from_flags(
        input Move move,
        input Color moving_color,
        input logic is_promotion,
        input logic is_castle
    );
        automatic int index;

        if (is_promotion) begin
            index = PROMOTION_MASK_OFFSET + (promotion_edge_index(move, moving_color) * 4) + int'(move.promo_piece);
        end else if (is_castle) begin
            index = castling_mask_index(move, moving_color);
        end else begin
            index = normal_edge_mask_index(move);
        end

        return MoveMaskIndex'(index);
    endfunction : candidate_mask_index_from_flags

    function automatic MoveMaskIndex candidate_mask_index(input Tile board[64], input Move move, input Color moving_color);
        automatic int index;

        if (move_is_promotion(board, move, moving_color)) begin
            index = PROMOTION_MASK_OFFSET + (promotion_edge_index(move, moving_color) * 4) + int'(move.promo_piece);
        end else if (is_castle_move(board, move, moving_color)) begin
            index = castling_mask_index(move, moving_color);
        end else begin
            index = normal_edge_mask_index(move);
        end

        return MoveMaskIndex'(index);
    endfunction : candidate_mask_index

    function automatic logic same_candidate_identity(input Tile board[64], input Move a, input Move b, input Color moving_color);
        if (a.from_pos != b.from_pos || a.to_pos != b.to_pos) begin
            return 1'b0;
        end

        if (move_is_promotion(board, a, moving_color)) begin
            return (a.promo_piece == b.promo_piece);
        end

        return 1'b1;
    endfunction : same_candidate_identity

    function automatic logic candidate_is_capture_or_promotion(
        input Tile board[64],
        input Move move,
        input Color moving_color,
        input logic ep_valid,
        input BoardFile ep_target_file
    );
        automatic Tile end_tile;

        end_tile = normalize_tile(board[move.to_pos]);
        return move_is_promotion(board, move, moving_color)
            || (end_tile.piece_type != NULL_PIECE && end_tile.piece_color != moving_color)
            || is_ep_move(board, move, moving_color, ep_valid, ep_target_file);
    endfunction : candidate_is_capture_or_promotion

    function automatic int promo_order_bonus(input PromoType promo);
        case (promo)
            PROMO_QUEEN:  return 4;
            PROMO_KNIGHT: return 3;
            PROMO_ROOK:   return 2;
            PROMO_BISHOP: return 1;
            default:      return 0;
        endcase
    endfunction : promo_order_bonus

    function automatic CandidateProposal better_proposal(
        input CandidateProposal left,
        input CandidateProposal right
    );
        if (right.valid && (!left.valid || right.score > left.score)) return right;
        return left;
    endfunction

    assign mask_rd_addr = MoveMaskAddr'(move_mask_addr(thread_id_pipe[PROP_STAGE_CNT - 2], ply_pipe[PROP_STAGE_CNT - 2]));
    assign mask_rd_en = request_valid_pipe[PROP_STAGE_CNT - 2] && !start_node_pipe[PROP_STAGE_CNT - 2];
    assign mask_wr_addr = MoveMaskAddr'(move_mask_addr(thread_id_pipe[REDUCE_1_STAGE], ply_pipe[REDUCE_1_STAGE]));
    assign mask_wr_en = request_valid_pipe[REDUCE_1_STAGE] && reduced_proposal.valid;

    synchronous_simple_dual_port_ram #(
        .NUM_WORDS(MASK_ENTRY_COUNT),
        .WORD_SIZE(MOVE_MASK_BITS)
    ) consumed_mask_memory (
        .clock(clk),
        .data(next_consumed_mask),
        .rdaddress(mask_rd_addr),
        .rden(mask_rd_en),
        .wraddress(mask_wr_addr),
        .wren(mask_wr_en),
        .q(mask_rd_data)
    );

    always_comb request_consumed_mask = start_node_pipe[PROP_STAGE_CNT - 1] ? MoveMask'(0) : mask_rd_data;

    genvar tile_idx;
    genvar knight_idx;
    genvar ray_idx;
    genvar promo_valid_idx;
    genvar promo_invalid_idx;
    generate
        for (tile_idx=0; tile_idx<64; tile_idx=tile_idx+1) begin : gen_tile_pe
            for (knight_idx=0; knight_idx<8; knight_idx=knight_idx+1) begin : gen_knight_input
                if (isKnightShiftOnBoard(Position'(tile_idx), KnightDirection'(knight_idx))) begin
                    localparam Position KNIGHT_POS = shiftKnightPos(Position'(tile_idx), KnightDirection'(knight_idx));
                    localparam Move KNIGHT_MOVE = Move'({KNIGHT_POS, Position'(tile_idx), PROMO_QUEEN});
                    localparam MoveMaskIndex KNIGHT_INDEX = MoveMaskIndex'(normal_edge_mask_index(KNIGHT_MOVE));
                    always_comb knight_tile[tile_idx][knight_idx] = board_pipe[PROP_STAGE_CNT-1][KNIGHT_POS];
                    always_comb knight_consumed[tile_idx][knight_idx] = request_consumed_mask[KNIGHT_INDEX];
                end else begin
                    always_comb knight_tile[tile_idx][knight_idx] = EMPTY_TILE;
                    always_comb knight_consumed[tile_idx][knight_idx] = 1'b1;
                end
            end

            for (ray_idx=0; ray_idx<8; ray_idx=ray_idx+1) begin : gen_ray_mask
                if (isShiftOnBoard(Position'(tile_idx), Direction'(ray_idx), 3'd1)) begin
                    localparam Position RAY_POS = shiftPos(Position'(tile_idx), Direction'(ray_idx), 3'd1);
                    localparam Move RAY_MOVE = Move'({RAY_POS, Position'(tile_idx), PROMO_QUEEN});
                    localparam MoveMaskIndex RAY_INDEX = MoveMaskIndex'(normal_edge_mask_index(RAY_MOVE));
                    localparam int WHITE_PROMO_EDGE = promotion_edge_index(RAY_MOVE, WHITE);
                    localparam int BLACK_PROMO_EDGE = promotion_edge_index(RAY_MOVE, BLACK);
                    always_comb ray_consumed[tile_idx][ray_idx] = request_consumed_mask[RAY_INDEX];
                    for (promo_valid_idx=0; promo_valid_idx<4; promo_valid_idx=promo_valid_idx+1) begin : gen_promo_mask
                        localparam MoveMaskIndex WHITE_PROMO_INDEX = MoveMaskIndex'(
                            PROMOTION_MASK_OFFSET + WHITE_PROMO_EDGE * 4 + promo_valid_idx);
                        localparam MoveMaskIndex BLACK_PROMO_INDEX = MoveMaskIndex'(
                            PROMOTION_MASK_OFFSET + BLACK_PROMO_EDGE * 4 + promo_valid_idx);
                        always_comb begin
                            promotion_consumed[tile_idx][ray_idx][promo_valid_idx] =
                                (turn_pipe[PROP_STAGE_CNT-1] == WHITE)
                                    ? request_consumed_mask[WHITE_PROMO_INDEX]
                                    : request_consumed_mask[BLACK_PROMO_INDEX];
                        end
                    end
                end else begin
                    always_comb ray_consumed[tile_idx][ray_idx] = 1'b1;
                    for (promo_invalid_idx=0; promo_invalid_idx<4; promo_invalid_idx=promo_invalid_idx+1) begin : gen_no_promo_mask
                        always_comb promotion_consumed[tile_idx][ray_idx][promo_invalid_idx] = 1'b1;
                    end
                end
            end

            move_generator_tile_PE #(.POS(tile_idx)) tile_pe (
                .tile_data(board_pipe[PROP_STAGE_CNT-1][tile_idx]),
                .ray_in(ray_pipe[PROP_STAGE_CNT-1][tile_idx]),
                .knight_tile_in(knight_tile[tile_idx]),
                .turn(turn_pipe[PROP_STAGE_CNT-1]),
                .move_gen_op(op_pipe[PROP_STAGE_CNT-1]),
                .target_move(target_move_pipe[PROP_STAGE_CNT-1]),
                .has_ep(has_ep_pipe[PROP_STAGE_CNT-1]),
                .ep_file(ep_file_pipe[PROP_STAGE_CNT-1]),
                .ray_consumed(ray_consumed[tile_idx]),
                .knight_consumed(knight_consumed[tile_idx]),
                .promotion_consumed(promotion_consumed[tile_idx]),
                .proposal(tile_proposal_in[tile_idx])
            );
        end
    endgenerate

    always_comb begin
        automatic Move move;
        automatic MoveMaskIndex index;
        automatic logic pseudo_legal;

        castle_proposal_in = NULL_PROPOSAL;
        move.promo_piece = PROMO_QUEEN;
        move.from_pos = (turn_pipe[PROP_STAGE_CNT-1] == WHITE) ? Position'(4) : Position'(60);
        move.to_pos = (turn_pipe[PROP_STAGE_CNT-1] == WHITE) ? Position'(6) : Position'(62);
        index = MoveMaskIndex'(castling_mask_index(move, turn_pipe[PROP_STAGE_CNT-1]));
        pseudo_legal = is_pseudo_legal_move(
            board_pipe[PROP_STAGE_CNT-1], move, turn_pipe[PROP_STAGE_CNT-1],
            castle_perms_pipe[PROP_STAGE_CNT-1], has_ep_pipe[PROP_STAGE_CNT-1],
            ep_file_pipe[PROP_STAGE_CNT-1]);
        if (op_pipe[PROP_STAGE_CNT-1] != MOVE_GEN_IDLE_OP
            && op_pipe[PROP_STAGE_CNT-1] != MOVE_GEN_QSEARCH_OP
            && pseudo_legal && !request_consumed_mask[index]) begin
            castle_proposal_in.valid = 1'b1;
            castle_proposal_in.move = move;
            castle_proposal_in.score = (op_pipe[PROP_STAGE_CNT-1] == MOVE_GEN_TARGETED_OP
                && move.from_pos == target_move_pipe[PROP_STAGE_CNT-1].from_pos
                && move.to_pos == target_move_pipe[PROP_STAGE_CNT-1].to_pos) ? MoveScore'(6'h3f) : MoveScore'(6'd24);
        end

        move.to_pos = (turn_pipe[PROP_STAGE_CNT-1] == WHITE) ? Position'(2) : Position'(58);
        index = MoveMaskIndex'(castling_mask_index(move, turn_pipe[PROP_STAGE_CNT-1]));
        pseudo_legal = is_pseudo_legal_move(
            board_pipe[PROP_STAGE_CNT-1], move, turn_pipe[PROP_STAGE_CNT-1],
            castle_perms_pipe[PROP_STAGE_CNT-1], has_ep_pipe[PROP_STAGE_CNT-1],
            ep_file_pipe[PROP_STAGE_CNT-1]);
        if (op_pipe[PROP_STAGE_CNT-1] != MOVE_GEN_IDLE_OP
            && op_pipe[PROP_STAGE_CNT-1] != MOVE_GEN_QSEARCH_OP
            && pseudo_legal && !request_consumed_mask[index]) begin
            automatic CandidateProposal queenside;
            queenside = NULL_PROPOSAL;
            queenside.valid = 1'b1;
            queenside.move = move;
            queenside.score = (op_pipe[PROP_STAGE_CNT-1] == MOVE_GEN_TARGETED_OP
                && move.from_pos == target_move_pipe[PROP_STAGE_CNT-1].from_pos
                && move.to_pos == target_move_pipe[PROP_STAGE_CNT-1].to_pos) ? MoveScore'(6'h3f) : MoveScore'(6'd24);
            castle_proposal_in = better_proposal(castle_proposal_in, queenside);
        end
    end

    always_comb begin
        reduced_proposal = reduce_1_pipe;
        reduced_proposal_legal = reduced_proposal.valid
            && is_strictly_legal_move(
                board_pipe[REDUCE_1_STAGE], reduced_proposal.move,
                turn_pipe[REDUCE_1_STAGE], castle_perms_pipe[REDUCE_1_STAGE],
                has_ep_pipe[REDUCE_1_STAGE], ep_file_pipe[REDUCE_1_STAGE]);
        next_consumed_mask = proposal_consumed_mask_pipe[REDUCE_STAGE_CNT];
        if (reduced_proposal.valid)
            next_consumed_mask[candidate_mask_index(
                board_pipe[REDUCE_1_STAGE], reduced_proposal.move,
                turn_pipe[REDUCE_1_STAGE])] = 1'b1;
    end


    // ========== Register the systolic pipeline ==========
    always_ff @(posedge clk) begin
        if (!rst_n) begin
            for (int stage=0; stage<MOVE_GEN_STAGE_CNT; stage++) begin
                request_valid_pipe[stage] <= 1'b0;
                start_node_pipe[stage] <= 1'bx;
                op_pipe[stage] <= MoveGenOp'('x);
                thread_id_pipe[stage] <= ThreadID'('x);
                ply_pipe[stage] <= PlyIndex'('x);
                target_move_pipe[stage] <= Move'('x);
                turn_pipe[stage] <= Color'('x);
                castle_perms_pipe[stage] <= CastlePerms'('x);
                has_ep_pipe[stage] <= 1'bx;
                ep_file_pipe[stage] <= BoardFile'('x);
                candidate_move_pipe[stage] <= Move'('x);
                candidate_move_legal_pipe[stage] <= 1'b0;
                for (int pos=0; pos<64; pos++) board_pipe[stage][pos] <= Tile'('x);
            end
            for (int idx=0; idx<=REDUCE_STAGE_CNT; idx++)
                proposal_consumed_mask_pipe[idx] <= MoveMask'('x);
            for (int stage=0; stage<PROP_STAGE_CNT; stage++)
                for (int pos=0; pos<64; pos++)
                    for (int dir_idx=0; dir_idx<8; dir_idx++)
                        ray_pipe[stage][pos][dir_idx] <= RayRecord'('x);
            for (int pos=0; pos<64; pos++) tile_proposal_pipe[pos] <= NULL_PROPOSAL;
            for (int idx=0; idx<8; idx++) reduce_8_pipe[idx] <= NULL_PROPOSAL;
            reduce_1_pipe <= NULL_PROPOSAL;
            castle_proposal_pipe <= NULL_PROPOSAL;
            candidate_move <= NULL_MOVE;
            move_is_legal <= 1'b0;
        end else begin
            request_valid_pipe[0] <= (move_gen_op != MOVE_GEN_IDLE_OP);
            start_node_pipe[0] <= start_node;
            op_pipe[0] <= move_gen_op;
            thread_id_pipe[0] <= thread_id;
            ply_pipe[0] <= ply;
            target_move_pipe[0] <= target_move;
            turn_pipe[0] <= turn;
            castle_perms_pipe[0] <= castle_perms;
            has_ep_pipe[0] <= has_ep;
            ep_file_pipe[0] <= ep_file;
            for (int pos=0; pos<64; pos++) board_pipe[0][pos] <= board_tiles[pos];

            // Start each ray only early enough to inspect its geometrically reachable squares by stage 6.
            for (int pos=0; pos<64; pos++) begin
                for (int dir_idx=0; dir_idx<8; dir_idx++) begin
                    automatic Direction dir = Direction'(dir_idx);
                    automatic int max_distance = ray_max_distance(Position'(pos), dir);
                    automatic int start_stage = PROP_STAGE_CNT - max_distance;

                    if (start_stage == 0) begin
                        automatic Position scan_pos = shiftPos(Position'(pos), dir, 3'd1);
                        ray_pipe[0][pos][dir_idx].tile <= normalize_tile(board_tiles[scan_pos]);
                        ray_pipe[0][pos][dir_idx].distance <= 3'd1;
                    end else ray_pipe[0][pos][dir_idx] <= NULL_RAY;
                end
            end

            for (int stage=1; stage<PROP_STAGE_CNT; stage++) begin
                for (int pos=0; pos<64; pos++) begin
                    for (int dir_idx=0; dir_idx<8; dir_idx++) begin
                        automatic Direction dir = Direction'(dir_idx);
                        automatic int max_distance = ray_max_distance(Position'(pos), dir);
                        automatic int start_stage = PROP_STAGE_CNT - max_distance;

                        if (stage < start_stage) begin
                            ray_pipe[stage][pos][dir_idx] <= NULL_RAY;
                        end else if (stage == start_stage) begin
                            automatic Position scan_pos = shiftPos(Position'(pos), dir, 3'd1);
                            ray_pipe[stage][pos][dir_idx].tile <= normalize_tile(board_pipe[stage-1][scan_pos]);
                            ray_pipe[stage][pos][dir_idx].distance <= 3'd1;
                        end else if (ray_pipe[stage-1][pos][dir_idx].tile.piece_type != NULL_PIECE) begin
                            ray_pipe[stage][pos][dir_idx] <= ray_pipe[stage-1][pos][dir_idx];
                        end else begin
                            automatic int scan_distance = stage - start_stage + 1;
                            automatic Position scan_pos = shiftPos(
                                Position'(pos), dir, RayDistance'(scan_distance));
                            ray_pipe[stage][pos][dir_idx].tile <= normalize_tile(board_pipe[stage-1][scan_pos]);
                            ray_pipe[stage][pos][dir_idx].distance <= RayDistance'(scan_distance);
                        end
                    end
                end
            end

            for (int stage=1; stage<MOVE_GEN_STAGE_CNT; stage++) begin
                request_valid_pipe[stage] <= request_valid_pipe[stage-1];
                start_node_pipe[stage] <= start_node_pipe[stage-1];
                op_pipe[stage] <= op_pipe[stage-1];
                thread_id_pipe[stage] <= thread_id_pipe[stage-1];
                ply_pipe[stage] <= ply_pipe[stage-1];
                target_move_pipe[stage] <= target_move_pipe[stage-1];
                turn_pipe[stage] <= turn_pipe[stage-1];
                castle_perms_pipe[stage] <= castle_perms_pipe[stage-1];
                has_ep_pipe[stage] <= has_ep_pipe[stage-1];
                ep_file_pipe[stage] <= ep_file_pipe[stage-1];
                for (int pos=0; pos<64; pos++) board_pipe[stage][pos] <= board_pipe[stage-1][pos];
            end

            for (int pos=0; pos<64; pos++) tile_proposal_pipe[pos] <= tile_proposal_in[pos];
            castle_proposal_pipe <= castle_proposal_in;
            proposal_consumed_mask_pipe[0] <= request_consumed_mask;

            for (int group=0; group<8; group++) begin
                automatic CandidateProposal winner = (group == 0)
                    ? better_proposal(tile_proposal_pipe[group*8], castle_proposal_pipe)
                    : tile_proposal_pipe[group*8];
                for (int lane=1; lane<8; lane++)
                    winner = better_proposal(winner, tile_proposal_pipe[group*8+lane]);
                reduce_8_pipe[group] <= winner;
            end
            proposal_consumed_mask_pipe[1] <= proposal_consumed_mask_pipe[0];

            begin
                automatic CandidateProposal winner = reduce_8_pipe[0];
                for (int lane=1; lane<8; lane++)
                    winner = better_proposal(winner, reduce_8_pipe[lane]);
                reduce_1_pipe <= winner;
            end
            proposal_consumed_mask_pipe[2] <= proposal_consumed_mask_pipe[1];

            if (request_valid_pipe[REDUCE_1_STAGE] && reduced_proposal.valid) begin
                candidate_move_pipe[LEGAL_STAGE] <= reduced_proposal.move;
                candidate_move_legal_pipe[LEGAL_STAGE] <= reduced_proposal_legal;
            end else begin
                candidate_move_pipe[LEGAL_STAGE] <= NULL_MOVE;
                candidate_move_legal_pipe[LEGAL_STAGE] <= 1'b0;
            end

            candidate_move <= candidate_move_pipe[LEGAL_STAGE];
            move_is_legal <= candidate_move_legal_pipe[LEGAL_STAGE];
        end
    end

endmodule
