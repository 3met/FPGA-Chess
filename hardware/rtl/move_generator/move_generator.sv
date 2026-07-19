
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

    Move candidate_move_pipe;
    logic candidate_move_legal_pipe;
    MoveMaskAddr mask_rd_addr;
    MoveMaskAddr mask_wr_addr;
    logic mask_rd_en;
    logic mask_wr_en;
    MoveMask mask_rd_data;
    MoveMask request_consumed_mask;
    MoveMask proposal_consumed_mask_pipe[REDUCE_STAGE_CNT + 1];
    MoveMask next_consumed_mask;

    localparam int TILE_SELECT_STAGE = PROP_STAGE_CNT;
    localparam int REDUCE_8_STAGE = TILE_SELECT_STAGE + 1;
    localparam int REDUCE_1_STAGE = REDUCE_8_STAGE + 1;

    logic request_valid_pipe[MOVE_GEN_STAGE_CNT];
    logic start_node_pipe[PROP_STAGE_CNT];
    MoveGenOp op_pipe[PROP_STAGE_CNT];
    ThreadID thread_id_pipe[MOVE_GEN_STAGE_CNT];
    PlyIndex ply_pipe[MOVE_GEN_STAGE_CNT];
    Move target_move_pipe[MOVE_GEN_STAGE_CNT];
    Color turn_pipe[MOVE_GEN_STAGE_CNT];
    CastlePerms castle_perms_pipe[PROP_STAGE_CNT];
    logic has_ep_pipe[PROP_STAGE_CNT];
    BoardFile ep_file_pipe[PROP_STAGE_CNT];
    Tile board_pipe[PROP_STAGE_CNT][64];
    RayRecord ray_pipe[PROP_STAGE_CNT][64][8];
    RayRecord king_vacated_ray[64][8];
    Tile knight_tile[64][8];
    logic ray_consumed[64][8];
    logic knight_consumed[64][8];
    logic promotion_consumed[64][8][4];
    logic target_destination[64];
    logic tile_target_valid[64];
    logic tile_target_is_promotion[64];
    logic target_valid_in;
    logic target_is_promotion_in;
    logic target_is_castle_in;
    logic target_king_safe_in;
    logic target_valid_pipe[REDUCE_STAGE_CNT + 1];
    logic target_is_promotion_pipe[REDUCE_STAGE_CNT + 1];
    logic target_is_castle_pipe[REDUCE_STAGE_CNT + 1];
    logic target_king_safe_pipe[REDUCE_STAGE_CNT + 1];
    TileCandidateProposal tile_proposal_in[64];
    CandidateProposal tile_proposal_pipe[64];
    CandidateProposal reduce_8_pipe[8];
    CandidateProposal reduce_1_pipe;
    CandidateProposal castle_proposal_in;
    CandidateProposal castle_proposal_pipe;
    CandidateProposal reduced_proposal;
    Move reduced_move;
    Move selected_move;
    logic selected_valid;
    logic selected_is_promotion;
    logic selected_is_castle;
    logic reduced_proposal_legal;
    logic tile_enemy_attacked[64];
    logic tile_king_move_attacked[64];

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
            default:    return 'x;
        endcase
    endfunction : ray_max_distance

    function automatic int tile_max_distance(input Position pos);
        automatic int rank = int'(getRank(pos));
        automatic int file = int'(getFile(pos));
        automatic int rank_distance = (rank > (7 - rank)) ? rank : (7 - rank);
        automatic int file_distance = (file > (7 - file)) ? file : (7 - file);
        return (rank_distance > file_distance) ? rank_distance : file_distance;
    endfunction : tile_max_distance

    function automatic logic tile_is_empty(input Tile board[64], input Position pos);
        return (board[pos].piece_type == NULL_PIECE);
    endfunction : tile_is_empty

    function automatic logic castle_perm(input CastlePerms perms, input int bit_index);
        return logic'(perms[bit_index]);
    endfunction : castle_perm

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

    function automatic logic is_castle_move(input Tile board[64], input Move move, input Color moving_color);
        automatic Tile start_tile;

        start_tile = board[move.from_pos];
        return (start_tile.piece_type == KING
            && start_tile.piece_color == moving_color
            && (   (moving_color == WHITE && move.from_pos == Position'('d4)  && (move.to_pos == Position'('d2)  || move.to_pos == Position'('d6)))
                || (moving_color == BLACK && move.from_pos == Position'('d60) && (move.to_pos == Position'('d58) || move.to_pos == Position'('d62)))));
    endfunction : is_castle_move

    // Castling candidates need only fixed-square permission and occupancy checks.
    function automatic logic castle_is_pseudo_legal(
        input Tile board[64],
        input Position king_to,
        input Color moving_color,
        input CastlePerms curr_castle_perms
    );
        if (moving_color == WHITE) begin
            if (king_to == Position'('d6)) begin
                return castle_perm(curr_castle_perms, 3)
                    && tile_is_empty(board, Position'('d5))
                    && tile_is_empty(board, Position'('d6))
                    && board[Position'('d7)] == WHITE_ROOK;
            end

            return castle_perm(curr_castle_perms, 2)
                && tile_is_empty(board, Position'('d1))
                && tile_is_empty(board, Position'('d2))
                && tile_is_empty(board, Position'('d3))
                && board[Position'('d0)] == WHITE_ROOK;
        end

        if (king_to == Position'('d62)) begin
            return castle_perm(curr_castle_perms, 1)
                && tile_is_empty(board, Position'('d61))
                && tile_is_empty(board, Position'('d62))
                && board[Position'('d63)] == BLACK_ROOK;
        end

        return castle_perm(curr_castle_perms, 0)
            && tile_is_empty(board, Position'('d57))
            && tile_is_empty(board, Position'('d58))
            && tile_is_empty(board, Position'('d59))
            && board[Position'('d56)] == BLACK_ROOK;
    endfunction : castle_is_pseudo_legal

    function automatic int move_mask_addr(input ThreadID tid, input PlyIndex search_ply);
        return (int'(tid) * MAX_PLY_COUNT) + int'(search_ply);
    endfunction : move_mask_addr

    function automatic logic move_is_promotion(input Tile board[64], input Move move, input Color moving_color);
        automatic Tile start_tile;

        start_tile = board[move.from_pos];
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
            SOUTH:      return NS_MASK_OFFSET + 56 + (to_file * 7) + to_rank;
            EAST:       return EW_MASK_OFFSET + ((to_file - 1) * 8) + to_rank;
            WEST:       return EW_MASK_OFFSET + 56 + (to_file * 8) + to_rank;
            NORTH_EAST: return POS_DIAG_MASK_OFFSET + ((to_file - 1) * 7) + (to_rank - 1);
            SOUTH_WEST: return POS_DIAG_MASK_OFFSET + 49 + (to_file * 7) + to_rank;
            SOUTH_EAST: return NEG_DIAG_MASK_OFFSET + ((to_file - 1) * 7) + to_rank;
            NORTH_WEST: return NEG_DIAG_MASK_OFFSET + 49 + (to_file * 7) + (to_rank - 1);
            default:    return 'x;
        endcase
    endfunction : normal_edge_mask_index

    function automatic int castling_mask_index(input Move move, input Color moving_color);
        if (moving_color == WHITE) begin
            return CASTLING_MASK_OFFSET + ((move.to_pos == Position'('d6)) ? 0 : 1);
        end

        return CASTLING_MASK_OFFSET + ((move.to_pos == Position'('d62)) ? 0 : 1);
    endfunction : castling_mask_index

    function automatic MoveMaskIndex candidate_mask_index(
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
    endfunction : candidate_mask_index

    function automatic CandidateProposal better_proposal(
        input CandidateProposal left,
        input CandidateProposal right
    );
        if (right.score > left.score) return right;
        return left;
    endfunction

    // Add the destination only after the destination-local candidate comparison.
    function automatic CandidateProposal add_proposal_destination(
        input TileCandidateProposal tile_proposal,
        input Position destination
    );
        automatic CandidateProposal proposal;

        proposal.to_pos = destination;
        proposal.source_dir = tile_proposal.source_dir;
        proposal.source_distance = tile_proposal.source_distance;
        proposal.promo_piece = tile_proposal.promo_piece;
        proposal.is_promotion = tile_proposal.is_promotion;
        proposal.is_castle = 1'b0;
        proposal.score = tile_proposal.score;
        proposal.king_safe = 1'bx;
        return proposal;
    endfunction

    // Reconstruct the selected source only after the global proposal reduction.
    function automatic Move proposal_move(input CandidateProposal proposal);
        automatic Move move;

        move.to_pos = proposal.to_pos;
        move.promo_piece = proposal.promo_piece;
        if (proposal.source_distance == KNIGHT_SOURCE_DISTANCE)
            move.from_pos = shiftKnightPos(proposal.to_pos, KnightDirection'(proposal.source_dir));
        else
            move.from_pos = shiftPos(proposal.to_pos, proposal.source_dir,
                3'(proposal.source_distance + 3'd1));
        return move;
    endfunction

    assign mask_rd_addr = MoveMaskAddr'(move_mask_addr(thread_id_pipe[PROP_STAGE_CNT - 2], ply_pipe[PROP_STAGE_CNT - 2]));
    assign mask_rd_en = request_valid_pipe[PROP_STAGE_CNT - 2] && !start_node_pipe[PROP_STAGE_CNT - 2];
    assign mask_wr_addr = MoveMaskAddr'(move_mask_addr(thread_id_pipe[REDUCE_1_STAGE], ply_pipe[REDUCE_1_STAGE]));
    assign mask_wr_en = request_valid_pipe[REDUCE_1_STAGE] && selected_valid;

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
    always_comb
        for (int pos=0; pos<64; pos++)
            target_destination[pos] = op_pipe[PROP_STAGE_CNT-1] == MOVE_GEN_TARGETED_OP
                && target_move_pipe[PROP_STAGE_CNT-1].to_pos == Position'(pos);

    genvar tile_idx;
    genvar knight_idx;
    genvar ray_idx;
    genvar promo_valid_idx;
    genvar promo_invalid_idx;
    generate
        for (tile_idx=0; tile_idx<64; tile_idx=tile_idx+1) begin : gen_tile_pe
            localparam int TILE_DISTANCE_BITS = $clog2(tile_max_distance(Position'(tile_idx)));
            localparam bit ENABLE_CASTLE_ATTACKS = tile_idx == 2 || tile_idx == 3 || tile_idx == 4
                || tile_idx == 5 || tile_idx == 6 || tile_idx == 58 || tile_idx == 59
                || tile_idx == 60 || tile_idx == 61 || tile_idx == 62;
            for (knight_idx=0; knight_idx<8; knight_idx=knight_idx+1) begin : gen_knight_input
                if (isKnightShiftOnBoard(Position'(tile_idx), KnightDirection'(knight_idx))) begin
                    localparam Position KNIGHT_POS = shiftKnightPos(Position'(tile_idx), KnightDirection'(knight_idx));
                    localparam Move KNIGHT_MOVE = Move'({KNIGHT_POS, Position'(tile_idx), PROMO_QUEEN});
                    localparam MoveMaskIndex KNIGHT_INDEX = MoveMaskIndex'(normal_edge_mask_index(KNIGHT_MOVE));
                    always_comb knight_tile[tile_idx][knight_idx] = board_pipe[PROP_STAGE_CNT-1][KNIGHT_POS];
                    always_comb knight_consumed[tile_idx][knight_idx] =
                        request_consumed_mask[KNIGHT_INDEX];
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
                    always_comb king_vacated_ray[tile_idx][ray_idx] =
                        ray_pipe[PROP_STAGE_CNT-1][RAY_POS][ray_idx];
                    always_comb ray_consumed[tile_idx][ray_idx] =
                        request_consumed_mask[RAY_INDEX];
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
                    always_comb king_vacated_ray[tile_idx][ray_idx] = NULL_RAY;
                    always_comb ray_consumed[tile_idx][ray_idx] = 1'b1;
                    for (promo_invalid_idx=0; promo_invalid_idx<4; promo_invalid_idx=promo_invalid_idx+1) begin : gen_no_promo_mask
                        always_comb promotion_consumed[tile_idx][ray_idx][promo_invalid_idx] = 1'b1;
                    end
                end
            end

            move_generator_tile_PE #(
                .POS(tile_idx),
                .DIST_BITS(TILE_DISTANCE_BITS),
                .ENABLE_CASTLE_ATTACKS(ENABLE_CASTLE_ATTACKS)
            ) tile_pe (
                .tile_data(board_pipe[PROP_STAGE_CNT-1][tile_idx]),
                .ray_in(ray_pipe[PROP_STAGE_CNT-1][tile_idx]),
                .king_vacated_ray_in(king_vacated_ray[tile_idx]),
                .knight_tile_in(knight_tile[tile_idx]),
                .turn(turn_pipe[PROP_STAGE_CNT-1]),
                .move_gen_op(op_pipe[PROP_STAGE_CNT-1]),
                .target_move(target_move_pipe[PROP_STAGE_CNT-1]),
                .target_destination(target_destination[tile_idx]),
                .has_ep(has_ep_pipe[PROP_STAGE_CNT-1]),
                .ep_file(ep_file_pipe[PROP_STAGE_CNT-1]),
                .ray_consumed(ray_consumed[tile_idx]),
                .knight_consumed(knight_consumed[tile_idx]),
                .promotion_consumed(promotion_consumed[tile_idx]),
                .proposal(tile_proposal_in[tile_idx]),
                .target_valid(tile_target_valid[tile_idx]),
                .target_is_promotion(tile_target_is_promotion[tile_idx]),
                .enemy_attacked(tile_enemy_attacked[tile_idx]),
                .king_move_attacked(tile_king_move_attacked[tile_idx])
            );
        end
    endgenerate

    always_comb begin
        automatic Move move;
        automatic MoveMaskIndex index;
        automatic logic pseudo_legal;

        castle_proposal_in = NULL_PROPOSAL;
        target_valid_in = 1'b0;
        target_is_promotion_in = 1'bx;
        target_is_castle_in = 1'bx;
        target_king_safe_in = 1'bx;
        for (int pos=0; pos<64; pos++) begin
            if (tile_target_valid[pos]) begin
                target_valid_in = 1'b1;
                target_is_promotion_in = tile_target_is_promotion[pos];
                target_is_castle_in = 1'b0;
                target_king_safe_in = 1'bx;
            end
        end
        move.promo_piece = PROMO_QUEEN;
        move.from_pos = (turn_pipe[PROP_STAGE_CNT-1] == WHITE) ? Position'(4) : Position'(60);
        move.to_pos = (turn_pipe[PROP_STAGE_CNT-1] == WHITE) ? Position'(6) : Position'(62);
        index = MoveMaskIndex'(castling_mask_index(move, turn_pipe[PROP_STAGE_CNT-1]));
        pseudo_legal = castle_is_pseudo_legal(
            board_pipe[PROP_STAGE_CNT-1], move.to_pos, turn_pipe[PROP_STAGE_CNT-1],
            castle_perms_pipe[PROP_STAGE_CNT-1]);
        if (op_pipe[PROP_STAGE_CNT-1] != MOVE_GEN_IDLE_OP
            && op_pipe[PROP_STAGE_CNT-1] != MOVE_GEN_QSEARCH_OP
            && pseudo_legal && !request_consumed_mask[index]) begin
            castle_proposal_in.to_pos = move.to_pos;
            castle_proposal_in.source_dir = WEST;
            castle_proposal_in.source_distance = 3'd1;
            castle_proposal_in.promo_piece = move.promo_piece;
            castle_proposal_in.is_promotion = 1'b0;
            castle_proposal_in.is_castle = 1'b1;
            castle_proposal_in.score = CASTLE_MOVE_SCORE;
            castle_proposal_in.king_safe =
                !tile_enemy_attacked[move.from_pos]
                && !tile_king_move_attacked[Position'((turn_pipe[PROP_STAGE_CNT-1] == WHITE) ? 5 : 61)]
                && !tile_king_move_attacked[move.to_pos];
            if (target_destination[move.to_pos]
                && move.from_pos == target_move_pipe[PROP_STAGE_CNT-1].from_pos) begin
                target_valid_in = 1'b1;
                target_is_promotion_in = 1'b0;
                target_is_castle_in = 1'b1;
                target_king_safe_in = castle_proposal_in.king_safe;
            end
        end

        move.to_pos = (turn_pipe[PROP_STAGE_CNT-1] == WHITE) ? Position'(2) : Position'(58);
        index = MoveMaskIndex'(castling_mask_index(move, turn_pipe[PROP_STAGE_CNT-1]));
        pseudo_legal = castle_is_pseudo_legal(
            board_pipe[PROP_STAGE_CNT-1], move.to_pos, turn_pipe[PROP_STAGE_CNT-1],
            castle_perms_pipe[PROP_STAGE_CNT-1]);
        if (op_pipe[PROP_STAGE_CNT-1] != MOVE_GEN_IDLE_OP
            && op_pipe[PROP_STAGE_CNT-1] != MOVE_GEN_QSEARCH_OP
            && pseudo_legal && !request_consumed_mask[index]) begin
            automatic CandidateProposal queenside;
            queenside = NULL_PROPOSAL;
            queenside.to_pos = move.to_pos;
            queenside.source_dir = EAST;
            queenside.source_distance = 3'd1;
            queenside.promo_piece = move.promo_piece;
            queenside.is_promotion = 1'b0;
            queenside.is_castle = 1'b1;
            queenside.score = CASTLE_MOVE_SCORE;
            queenside.king_safe =
                !tile_enemy_attacked[move.from_pos]
                && !tile_king_move_attacked[Position'((turn_pipe[PROP_STAGE_CNT-1] == WHITE) ? 3 : 59)]
                && !tile_king_move_attacked[move.to_pos];
            if (target_destination[move.to_pos]
                && move.from_pos == target_move_pipe[PROP_STAGE_CNT-1].from_pos) begin
                target_valid_in = 1'b1;
                target_is_promotion_in = 1'b0;
                target_is_castle_in = 1'b1;
                target_king_safe_in = queenside.king_safe;
            end
            castle_proposal_in = better_proposal(castle_proposal_in, queenside);
        end
    end

    always_comb begin
        reduced_proposal = reduce_1_pipe;
        reduced_move = proposal_move(reduced_proposal);
        selected_valid = target_valid_pipe[REDUCE_STAGE_CNT]
            || reduced_proposal.score != INVALID_MOVE_SCORE;
        selected_move = target_valid_pipe[REDUCE_STAGE_CNT]
            ? target_move_pipe[REDUCE_1_STAGE] : reduced_move;
        selected_is_promotion = target_valid_pipe[REDUCE_STAGE_CNT]
            ? target_is_promotion_pipe[REDUCE_STAGE_CNT] : reduced_proposal.is_promotion;
        selected_is_castle = target_valid_pipe[REDUCE_STAGE_CNT]
            ? target_is_castle_pipe[REDUCE_STAGE_CNT] : reduced_proposal.is_castle;
        reduced_proposal_legal = 1'b0;

        if (selected_valid) begin
            // Only castling needs an early strict check because its origin and
            // transit squares are no longer observable after board update.
            if (selected_is_castle) begin
                reduced_proposal_legal = target_valid_pipe[REDUCE_STAGE_CNT]
                    ? target_king_safe_pipe[REDUCE_STAGE_CNT] : reduced_proposal.king_safe;
            end else begin
                reduced_proposal_legal = 1'b1;
            end
        end

        next_consumed_mask = proposal_consumed_mask_pipe[REDUCE_STAGE_CNT];
        if (selected_valid) begin
            automatic MoveMaskIndex selected_mask_index;
            selected_mask_index = candidate_mask_index(
                selected_move, turn_pipe[REDUCE_1_STAGE],
                selected_is_promotion, selected_is_castle);
            next_consumed_mask[selected_mask_index] = 1'b1;
        end
    end


    // ========== Register the systolic pipeline ==========
    always_ff @(posedge clk) begin
        if (!rst_n) begin
            for (int stage=0; stage<MOVE_GEN_STAGE_CNT; stage++) begin
                request_valid_pipe[stage] <= 1'b0;
                thread_id_pipe[stage] <= ThreadID'('x);
                ply_pipe[stage] <= PlyIndex'('x);
                target_move_pipe[stage] <= Move'('x);
                turn_pipe[stage] <= Color'('x);
            end
            for (int stage=0; stage<PROP_STAGE_CNT; stage++) begin
                start_node_pipe[stage] <= 1'bx;
                op_pipe[stage] <= MoveGenOp'('x);
                castle_perms_pipe[stage] <= CastlePerms'('x);
                has_ep_pipe[stage] <= 1'bx;
                ep_file_pipe[stage] <= BoardFile'('x);
            end
            for (int stage=0; stage<PROP_STAGE_CNT; stage++)
                for (int pos=0; pos<64; pos++) board_pipe[stage][pos] <= Tile'('x);
            candidate_move_pipe <= Move'('x);
            candidate_move_legal_pipe <= 1'b0;
            for (int idx=0; idx<=REDUCE_STAGE_CNT; idx++)
                proposal_consumed_mask_pipe[idx] <= MoveMask'('x);
            for (int idx=0; idx<=REDUCE_STAGE_CNT; idx++) begin
                target_valid_pipe[idx] <= 1'b0;
                target_is_promotion_pipe[idx] <= 1'bx;
                target_is_castle_pipe[idx] <= 1'bx;
                target_king_safe_pipe[idx] <= 1'bx;
            end
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

            // Start each ray only early enough to inspect up to three reachable squares per stage.
            for (int pos=0; pos<64; pos++) begin
                for (int dir_idx=0; dir_idx<8; dir_idx++) begin
                    automatic Direction dir = Direction'(dir_idx);
                    automatic int max_distance = ray_max_distance(Position'(pos), dir);
                    automatic int active_stage_count = (max_distance + 2) / 3;
                    automatic int start_stage = PROP_STAGE_CNT - active_stage_count;

                    if (start_stage == 0) begin
                        automatic int scan_end = max_distance - 3 * (PROP_STAGE_CNT - 1);
                        automatic int scan_start = (scan_end > 2) ? scan_end - 2 : 1;
                        automatic Position first_pos = shiftPos(
                            Position'(pos), dir, RayDistance'(scan_start));
                        if (board_tiles[first_pos].piece_type != NULL_PIECE || scan_start == scan_end) begin
                            ray_pipe[0][pos][dir_idx].tile <= board_tiles[first_pos];
                            ray_pipe[0][pos][dir_idx].distance <= RayDistance'(scan_start - 1);
                        end else begin
                            automatic Position second_pos = shiftPos(
                                Position'(pos), dir, RayDistance'(scan_start + 1));
                            if (board_tiles[second_pos].piece_type != NULL_PIECE
                                || scan_start + 1 == scan_end) begin
                                ray_pipe[0][pos][dir_idx].tile <= board_tiles[second_pos];
                                ray_pipe[0][pos][dir_idx].distance <= RayDistance'(scan_start);
                            end else begin
                                automatic Position third_pos = shiftPos(
                                    Position'(pos), dir, RayDistance'(scan_end));
                                ray_pipe[0][pos][dir_idx].tile <= board_tiles[third_pos];
                                ray_pipe[0][pos][dir_idx].distance <= RayDistance'(scan_end - 1);
                            end
                        end
                    end else ray_pipe[0][pos][dir_idx] <= NULL_RAY;
                end
            end

            for (int stage=1; stage<PROP_STAGE_CNT; stage++) begin
                for (int pos=0; pos<64; pos++) begin
                    for (int dir_idx=0; dir_idx<8; dir_idx++) begin
                        automatic Direction dir = Direction'(dir_idx);
                        automatic int max_distance = ray_max_distance(Position'(pos), dir);
                        automatic int active_stage_count = (max_distance + 2) / 3;
                        automatic int start_stage = PROP_STAGE_CNT - active_stage_count;

                        if (stage < start_stage) begin
                            ray_pipe[stage][pos][dir_idx] <= NULL_RAY;
                        end else if (ray_pipe[stage-1][pos][dir_idx].tile.piece_type != NULL_PIECE) begin
                            ray_pipe[stage][pos][dir_idx] <= ray_pipe[stage-1][pos][dir_idx];
                        end else begin
                            automatic int scan_end = max_distance
                                - 3 * (PROP_STAGE_CNT - 1 - stage);
                            automatic int scan_start = (scan_end > 2) ? scan_end - 2 : 1;
                            automatic Position first_pos = shiftPos(
                                Position'(pos), dir, RayDistance'(scan_start));
                            if (board_pipe[stage-1][first_pos].piece_type != NULL_PIECE
                                || scan_start == scan_end) begin
                                ray_pipe[stage][pos][dir_idx].tile <= board_pipe[stage-1][first_pos];
                                ray_pipe[stage][pos][dir_idx].distance <= RayDistance'(scan_start - 1);
                            end else begin
                                automatic Position second_pos = shiftPos(
                                    Position'(pos), dir, RayDistance'(scan_start + 1));
                                if (board_pipe[stage-1][second_pos].piece_type != NULL_PIECE
                                    || scan_start + 1 == scan_end) begin
                                    ray_pipe[stage][pos][dir_idx].tile <= board_pipe[stage-1][second_pos];
                                    ray_pipe[stage][pos][dir_idx].distance <= RayDistance'(scan_start);
                                end else begin
                                    automatic Position third_pos = shiftPos(
                                        Position'(pos), dir, RayDistance'(scan_end));
                                    ray_pipe[stage][pos][dir_idx].tile <= board_pipe[stage-1][third_pos];
                                    ray_pipe[stage][pos][dir_idx].distance <= RayDistance'(scan_end - 1);
                                end
                            end
                        end
                    end
                end
            end

            for (int stage=1; stage<MOVE_GEN_STAGE_CNT; stage++) begin
                request_valid_pipe[stage] <= request_valid_pipe[stage-1];
                thread_id_pipe[stage] <= thread_id_pipe[stage-1];
                ply_pipe[stage] <= ply_pipe[stage-1];
                target_move_pipe[stage] <= target_move_pipe[stage-1];
                turn_pipe[stage] <= turn_pipe[stage-1];
            end
            for (int stage=1; stage<PROP_STAGE_CNT; stage++) begin
                start_node_pipe[stage] <= start_node_pipe[stage-1];
                op_pipe[stage] <= op_pipe[stage-1];
                castle_perms_pipe[stage] <= castle_perms_pipe[stage-1];
                has_ep_pipe[stage] <= has_ep_pipe[stage-1];
                ep_file_pipe[stage] <= ep_file_pipe[stage-1];
            end
            for (int stage=1; stage<PROP_STAGE_CNT; stage++)
                for (int pos=0; pos<64; pos++) board_pipe[stage][pos] <= board_pipe[stage-1][pos];

            for (int pos=0; pos<64; pos++)
                tile_proposal_pipe[pos] <= add_proposal_destination(
                    tile_proposal_in[pos], Position'(pos));
            castle_proposal_pipe <= castle_proposal_in;
            proposal_consumed_mask_pipe[0] <= request_consumed_mask;
            target_valid_pipe[0] <= target_valid_in;
            target_is_promotion_pipe[0] <= target_is_promotion_in;
            target_is_castle_pipe[0] <= target_is_castle_in;
            target_king_safe_pipe[0] <= target_king_safe_in;

            for (int group=0; group<8; group++) begin
                automatic CandidateProposal winner = (group == 0)
                    ? better_proposal(tile_proposal_pipe[group*8], castle_proposal_pipe)
                    : tile_proposal_pipe[group*8];
                for (int lane=1; lane<8; lane++)
                    winner = better_proposal(winner, tile_proposal_pipe[group*8+lane]);
                reduce_8_pipe[group] <= winner;
            end
            proposal_consumed_mask_pipe[1] <= proposal_consumed_mask_pipe[0];
            target_valid_pipe[1] <= target_valid_pipe[0];
            target_is_promotion_pipe[1] <= target_is_promotion_pipe[0];
            target_is_castle_pipe[1] <= target_is_castle_pipe[0];
            target_king_safe_pipe[1] <= target_king_safe_pipe[0];

            begin
                automatic CandidateProposal winner = reduce_8_pipe[0];
                for (int lane=1; lane<8; lane++)
                    winner = better_proposal(winner, reduce_8_pipe[lane]);
                reduce_1_pipe <= winner;
            end
            proposal_consumed_mask_pipe[2] <= proposal_consumed_mask_pipe[1];
            target_valid_pipe[2] <= target_valid_pipe[1];
            target_is_promotion_pipe[2] <= target_is_promotion_pipe[1];
            target_is_castle_pipe[2] <= target_is_castle_pipe[1];
            target_king_safe_pipe[2] <= target_king_safe_pipe[1];

            if (request_valid_pipe[REDUCE_1_STAGE] && selected_valid) begin
                candidate_move_pipe <= selected_move;
                candidate_move_legal_pipe <= reduced_proposal_legal;
            end else begin
                candidate_move_pipe <= NULL_MOVE;
                candidate_move_legal_pipe <= 1'b0;
            end

            candidate_move <= candidate_move_pipe;
            move_is_legal <= candidate_move_legal_pipe;
        end
    end

endmodule
