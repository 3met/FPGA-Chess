
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

    // Move Config Pipeline
    MoveGenOp move_gen_op_pipe[11];
    logic start_node_pipe[11];
    ThreadID thread_id_pipe[11];
    PlyIndex ply_pipe[11];
    Move target_move_pipe[9];
    logic is_target_move_knight, is_target_move_knight_wire;
    Direction target_move_direction, target_move_direction_wire;

    // Piece Propagation Pipeline Registers
    Tile board_pipe[7][64];        // Indexed like [layer][position]
    Tile adj_piece_in[7][64][8];     // Indexed like [layer][position][direction]
    reg [2:0] adj_dist_in[7][64][8]; // Indexed like [layer][position][direction]
    KnightBusData knight_data_in[64][8]; // Indexed like [layer][position][direction];

    // Board State Pipeline
    Color       turn_pipe[8];
    CastlePerms castle_perms_pipe[8];
    reg         has_ep_pipe[8];
    BoardFile   ep_file_pipe[8];

    // Move Generation State
    PlyIndex prev_ply[THREAD_COUNT];

    // Board Mask Pipeline
    reg NS_cardinal_mask[4][8][7];    // Indexed like [layer][file][rank]
    reg EW_cardinal_mask[4][7][8];    // Indexed like [layer][file][rank]
    reg pos_diag_mask[4][7][7];       // Indexed like [layer][file][rank]
    reg neg_diag_mask[4][7][7];       // Indexed like [layer][file][rank]
    reg NNE_SSW_knight_mask[4][7][6]; // Indexed like [layer][file][rank]
    reg NEE_SWW_knight_mask[4][6][7]; // Indexed like [layer][file][rank]
    reg SEE_NWW_knight_mask[4][6][7]; // Indexed like [layer][file][rank]
    reg SSE_NNW_knight_mask[4][7][6]; // Indexed like [layer][file][rank]

    // Result Pipeline
    MovePriority tile_move_priority[64]; // The best score a given tile can produce
    Direction tile_move_dir[64]; // Direction of origin from the destination tile
    logic [2:0] tile_move_dist[64]; // Distance of best move
    MovePriority selected_move_priority;  // The best score for the entire board
    Position selected_to_pos;
    Direction selected_move_dir;  // The direction of origin from the best destination tile
    logic [2:0] selected_move_dist;  // The distance of the best move
    logic selected_move_is_knight;
    Move selected_move;
    logic selected_move_is_legal;

    logic is_candidate_move_knight, is_candidate_move_knight_wire;
    Direction candidate_move_direction, candidate_move_direction_wire;

    Move candidate_move_pipe[MOVE_GEN_STAGE_CNT];
    logic candidate_move_legal_pipe[MOVE_GEN_STAGE_CNT];
    Move selected_move_in;
    logic selected_move_legal_in;
    MoveMask consumed_masks[THREAD_COUNT * MAX_PLY_COUNT];
    MoveMask request_consumed_mask;
    MoveMask next_consumed_mask;
    MoveMaskIndex selected_move_index;
    logic selected_move_valid;

    // Depth of memory to allocate
    // TODO: Round up to BRAM size?
    // localparam MEM_DEPTH = $ceil(MAX_PLY_COUNT * 0.8);

    // Valid Mask Chunk BRAM
    // simple_dual_port_ram valid_mask_chunk_mem #(NUM_WORDS=(THREAD_COUNT * MAX_PLY_COUNT), WORD_SIZE=(378)) (
    //     .clock(),
    //     .data(),
    //     .rdaddress(),
    //     .rden(),
    //     .wraddress(),
    //     .wren(),
    //     .q()
    // );

    wire [378-1:0] combined_mask[4]; // Indexed like [layer]
    wire [378-1:0] loaded_mask;
    logic adj_mask[64][8]; // Indexed like [pos][dir]
    logic knight_mask[64][8]; // Indexed like [pos][dir]

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

    function automatic Tile normalize_tile(input Tile tile);
        if (tile.piece_type == NULL_PIECE) begin
            return EMPTY_TILE;
        end

        return tile;
    endfunction : normalize_tile

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
            default:      return QUEEN;
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
        automatic KingCheckInfo check_info;
        automatic PinInfo pin_info;
        automatic Tile start_tile;
        automatic Position ep_capture_pos;
        automatic logic captures_checker;

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
        check_info = get_check_info(board, own_king_pos, enemy_color);
        pin_info = get_pin_info(board, own_king_pos, move.from_pos, moving_color);
        ep_capture_pos = getPosition(getRank(move.from_pos), getFile(move.to_pos));
        captures_checker = (move.to_pos == check_info.first_checker) || (ep_move && ep_capture_pos == check_info.first_checker);

        if (check_info.count > 2'd1) begin
            return 1'b0;
        end

        if (pin_info.is_pinned && !same_ray_from_origin(own_king_pos, move.to_pos, pin_info.pin_dir)) begin
            return 1'b0;
        end

        if (check_info.count == 2'd1) begin
            if (check_info.first_checker_is_slider) begin
                if (!(captures_checker || square_on_ray_until(own_king_pos, move.to_pos, check_info.first_checker_dir, check_info.first_checker))) begin
                    return 1'b0;
                end
            end else if (!captures_checker) begin
                return 1'b0;
            end
        end

        if (ep_move) begin
            return !square_attacked_after_move(board, own_king_pos, enemy_color, move, moving_color, ep_move, 1'b0);
        end

        return 1'b1;
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

        return (moving_color == WHITE) ? edge_idx : (22 + edge_idx);
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

        return CASTLING_MASK_OFFSET + ((move.to_pos == Position'('d62)) ? 2 : 3);
    endfunction : castling_mask_index

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

    function automatic int candidate_score(
        input Tile board[64],
        input Move move,
        input MoveGenOp op,
        input Move target,
        input Color moving_color,
        input CastlePerms curr_castle_perms,
        input logic ep_valid,
        input BoardFile ep_target_file
    );
        automatic Tile start_tile;
        automatic Tile end_tile;
        automatic int score;

        start_tile = normalize_tile(board[move.from_pos]);
        end_tile = normalize_tile(board[move.to_pos]);
        score = 10;

        if (end_tile.piece_type != NULL_PIECE && end_tile.piece_color != moving_color) begin
            score += 100 + int'(PIECE_VALS_1[end_tile.piece_type]);
        end

        if (is_ep_move(board, move, moving_color, ep_valid, ep_target_file)) begin
            score += 101;
        end

        if (move_is_promotion(board, move, moving_color)) begin
            score += 120 + promo_order_bonus(move.promo_piece);
        end

        if (is_castle_move(board, move, moving_color)) begin
            score += 5;
        end

        if (op == MOVE_GEN_TARGETED_OP
            && same_candidate_identity(board, move, target, moving_color)
            && is_strictly_legal_move(board, move, moving_color, curr_castle_perms, ep_valid, ep_target_file)) begin
            score = 1000;
        end

        return score;
    endfunction : candidate_score

    task automatic select_next_candidate(
        input Tile board[64],
        input Color moving_color,
        input CastlePerms curr_castle_perms,
        input logic ep_valid,
        input BoardFile ep_target_file,
        input MoveGenOp op,
        input Move target,
        input MoveMask consumed_mask,
        output Move selected,
        output logic selected_valid,
        output logic selected_legal,
        output MoveMaskIndex selected_index
    );
        automatic Move candidate;
        automatic MoveMaskIndex candidate_index;
        automatic int best_score;
        automatic int score;
        automatic logic is_promotion;
        automatic logic op_allowed;
        automatic Tile from_tile;

        selected = NULL_MOVE;
        selected_valid = 1'b0;
        selected_legal = 1'b0;
        selected_index = MoveMaskIndex'(0);
        best_score = -1;

        if (op == MOVE_GEN_IDLE_OP) begin
            return;
        end

        for (int from_pos=0; from_pos<64; from_pos++) begin
            from_tile = normalize_tile(board[from_pos]);
            if (from_tile.piece_type != NULL_PIECE && from_tile.piece_color == moving_color) begin
                for (int to_pos=0; to_pos<64; to_pos++) begin
                    for (int promo_idx=0; promo_idx<4; promo_idx++) begin
                        candidate.from_pos = Position'(from_pos);
                        candidate.to_pos = Position'(to_pos);
                        candidate.promo_piece = PromoType'(promo_idx);
                        is_promotion = move_is_promotion(board, candidate, moving_color);

                        if ((is_promotion || promo_idx == 0)
                            && is_pseudo_legal_move(board, candidate, moving_color, curr_castle_perms, ep_valid, ep_target_file)) begin
                            candidate_index = candidate_mask_index(board, candidate, moving_color);
                            op_allowed = (op != MOVE_GEN_QSEARCH_OP)
                                || candidate_is_capture_or_promotion(board, candidate, moving_color, ep_valid, ep_target_file);

                            if (op_allowed && !consumed_mask[candidate_index]) begin
                                score = candidate_score(board, candidate, op, target, moving_color, curr_castle_perms, ep_valid, ep_target_file);
                                if (score > best_score) begin
                                    best_score = score;
                                    selected = candidate;
                                    selected_valid = 1'b1;
                                    selected_index = candidate_index;
                                end
                            end
                        end
                    end
                end
            end
        end

        if (selected_valid) begin
            selected_legal = is_strictly_legal_move(board, selected, moving_color, curr_castle_perms, ep_valid, ep_target_file);
        end
    endtask : select_next_candidate

    // ========== Select Best Candidate Move ==========
    always_comb begin
        request_consumed_mask = start_node ? MoveMask'('0) : consumed_masks[move_mask_addr(thread_id, ply)];
        select_next_candidate(
            board_tiles,
            turn,
            castle_perms,
            has_ep,
            ep_file,
            move_gen_op,
            target_move,
            request_consumed_mask,
            selected_move_in,
            selected_move_valid,
            selected_move_legal_in,
            selected_move_index
        );

        next_consumed_mask = request_consumed_mask;
        if (selected_move_valid) begin
            next_consumed_mask[selected_move_index] = 1'b1;
        end
    end


    // ========== Register candidate_move and strict legality status ==========
    always_ff @(posedge clk) begin
        if (!rst_n) begin
            for (int stage=0; stage<MOVE_GEN_STAGE_CNT; stage++) begin
                move_gen_op_pipe[stage] <= MOVE_GEN_IDLE_OP;
                start_node_pipe[stage] <= 1'b0;
                thread_id_pipe[stage] <= ThreadID'(0);
                ply_pipe[stage] <= PlyIndex'(0);
            end
            for (int stage=0; stage<9; stage++) begin
                target_move_pipe[stage] <= NULL_MOVE;
            end
            for (int stage=0; stage<MOVE_GEN_STAGE_CNT; stage++) begin
                candidate_move_pipe[stage] <= NULL_MOVE;
                candidate_move_legal_pipe[stage] <= 1'b0;
            end
            candidate_move <= NULL_MOVE;
            move_is_legal <= 1'b0;
        end else begin
            if (move_gen_op != MOVE_GEN_IDLE_OP) begin
                consumed_masks[move_mask_addr(thread_id, ply)] <= next_consumed_mask;
            end

            move_gen_op_pipe[0] <= move_gen_op;
            start_node_pipe[0] <= start_node;
            thread_id_pipe[0] <= thread_id;
            ply_pipe[0] <= ply;
            target_move_pipe[0] <= target_move;
            candidate_move_pipe[0] <= selected_move_in;
            candidate_move_legal_pipe[0] <= selected_move_valid && selected_move_legal_in;

            for (int stage=1; stage<MOVE_GEN_STAGE_CNT; stage++) begin
                move_gen_op_pipe[stage] <= move_gen_op_pipe[stage-1];
                start_node_pipe[stage] <= start_node_pipe[stage-1];
                thread_id_pipe[stage] <= thread_id_pipe[stage-1];
                ply_pipe[stage] <= ply_pipe[stage-1];
                candidate_move_pipe[stage] <= candidate_move_pipe[stage-1];
                candidate_move_legal_pipe[stage] <= candidate_move_legal_pipe[stage-1];
            end

            for (int stage=1; stage<9; stage++) begin
                target_move_pipe[stage] <= target_move_pipe[stage-1];
            end

            candidate_move <= candidate_move_pipe[MOVE_GEN_STAGE_CNT-1];
            move_is_legal <= candidate_move_legal_pipe[MOVE_GEN_STAGE_CNT-1];
        end
    end

endmodule
