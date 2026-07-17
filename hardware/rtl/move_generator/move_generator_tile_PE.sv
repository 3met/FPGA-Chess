// By Emet Behrendt

import general_chess_defs::*;
import chess_helper_funcs::*;
import move_generator_defs::*;

module move_generator_tile_PE #(
    parameter int POS = 0,
    parameter int DIST_BITS = 3,
    parameter bit ENABLE_CASTLE_ATTACKS = 1'b0
) (
    input Tile tile_data,
    input RayRecord ray_in[8],
    input RayRecord king_vacated_ray_in[8],
    input Tile knight_tile_in[8],
    input Color turn,
    input MoveGenOp move_gen_op,
    input Move target_move,
    input logic target_destination,
    input logic has_ep,
    input BoardFile ep_file,
    input logic ray_consumed[8],
    input logic knight_consumed[8],
    input logic promotion_consumed[8][4],
    output TileCandidateProposal proposal,
    output logic target_valid,
    output logic target_is_promotion,
    output logic enemy_attacked,
    output logic king_move_attacked
);

    localparam Position DEST_POS = Position'(POS);
    localparam BoardRank DEST_RANK = BoardRank'(POS / 8);
    localparam BoardFile DEST_FILE = BoardFile'(POS % 8);

    // Reconstruct the nearest source square on a ray
    typedef logic [DIST_BITS-1:0] EncodedDistance;

    // Ray distances encode the adjacent square as zero, so add one only where
    // the board-position helper requires the physical number of steps.
    function automatic logic [2:0] physical_distance(input EncodedDistance distance);
        return 3'(distance) + 3'd1;
    endfunction

    function automatic Position ray_source(input Direction dir, input EncodedDistance distance);
        return shiftPos(DEST_POS, dir, physical_distance(distance));
    endfunction

    // Identify an en passant move into this destination
    function automatic logic is_ep_candidate(input Tile source, input Move move);
        if (source.piece_type == SPARE_PIECE) return 1'bx;
        if (!has_ep || source.piece_type != PAWN || tile_data.piece_type != NULL_PIECE) return 1'b0;
        if (DEST_FILE != ep_file) return 1'b0;
        if (turn == WHITE) return getRank(move.from_pos) == 3'd4 && DEST_RANK == 3'd5;
        return getRank(move.from_pos) == 3'd3 && DEST_RANK == 3'd2;
    endfunction

    // Check pseudo-legal movement from a ray source
    function automatic logic ray_can_move(
        input Tile source,
        input Direction dir,
        input EncodedDistance distance,
        input logic ep_move
    );
        if (tile_data.piece_type == SPARE_PIECE) return 1'bx;

        case (source.piece_type)
            PAWN: begin
                if (turn == WHITE) begin
                    if (dir == SOUTH && tile_data.piece_type == NULL_PIECE)
                        return distance == 0 || (distance == 1 && DEST_RANK == 3);
                    return distance == 0 && (dir == SOUTH_WEST || dir == SOUTH_EAST)
                        && ((tile_data.piece_type != NULL_PIECE && tile_data.piece_color == BLACK) || ep_move);
                end
                if (dir == NORTH && tile_data.piece_type == NULL_PIECE)
                    return distance == 0 || (distance == 1 && DEST_RANK == 4);
                return distance == 0 && (dir == NORTH_WEST || dir == NORTH_EAST)
                    && ((tile_data.piece_type != NULL_PIECE && tile_data.piece_color == WHITE) || ep_move);
            end
            KNIGHT: return 1'b0;
            BISHOP: return isDirDiag(dir);
            ROOK: return isDirCardinal(dir);
            QUEEN: return 1'b1;
            KING: return distance == 0;
            default: return 1'bx;
        endcase
    endfunction

    // Test whether a nearest ray source attacks this destination
    function automatic logic ray_source_attacks(input Tile source, input Direction dir, input EncodedDistance distance);
        if (source.piece_type == SPARE_PIECE) return 1'bx;
        if (source.piece_type == NULL_PIECE || source.piece_color == turn) return 1'b0;

        case (source.piece_type)
            PAWN: begin
                if (source.piece_color == WHITE)
                    return distance == 0 && (dir == SOUTH_WEST || dir == SOUTH_EAST);
                return distance == 0 && (dir == NORTH_WEST || dir == NORTH_EAST);
            end
            KNIGHT: return 1'b0;
            BISHOP: return isDirDiag(dir);
            ROOK: return isDirCardinal(dir);
            QUEEN: return 1'b1;
            KING: return distance == 0;
            default: return 1'bx;
        endcase
    endfunction

    // Test whether a ray source is an attacking slider
    function automatic logic ray_slider_attacks(input Tile source, input Direction dir);
        if (source.piece_type == SPARE_PIECE) return 1'bx;
        return source.piece_type != NULL_PIECE
            && source.piece_color != turn
            && (source.piece_type == QUEEN
                || (source.piece_type == ROOK && isDirCardinal(dir))
                || (source.piece_type == BISHOP && isDirDiag(dir)));
    endfunction

    // Compact MVV ordering avoids replicated source-piece arithmetic in every PE.
    function automatic MoveScore move_order_score(input PieceType source_piece);
        if (source_piece == SPARE_PIECE || tile_data.piece_type == SPARE_PIECE)
            return MoveScore'('x);
        if (tile_data.piece_type != NULL_PIECE)
            return MoveScore'({2'b10, tile_data.piece_type});
        return QUIET_MOVE_SCORE;
    endfunction

    always_comb begin
        automatic TileCandidateProposal ordinary_best;
        automatic TileCandidateProposal promotion_best;
        automatic logic promotion_found[4];
        automatic Direction promotion_dir[4];
        automatic logic [2:0] promotion_distance[4];
        automatic Move move;
        automatic Tile source;
        automatic logic ep_move;
        automatic logic tactical;

        ordinary_best = NULL_TILE_PROPOSAL;
        promotion_best = NULL_TILE_PROPOSAL;
        target_valid = 1'b0;
        target_is_promotion = 1'bx;
        for (int promo_idx=0; promo_idx<4; promo_idx++) begin
            promotion_found[promo_idx] = 1'b0;
            promotion_dir[promo_idx] = Direction'('x);
            promotion_distance[promo_idx] = 3'bxxx;
        end
        enemy_attacked = 1'b0;
        king_move_attacked = 1'b0;

        // Only the ten castling origin/transit/destination squares need attack outputs.
        if (ENABLE_CASTLE_ATTACKS) begin
            for (int dir_idx=0; dir_idx<8; dir_idx++) begin
                automatic EncodedDistance ray_distance = EncodedDistance'(ray_in[dir_idx].distance);
                if (isShiftOnBoard(DEST_POS, Direction'(dir_idx), 3'd1)) begin
                    source = ray_in[dir_idx].tile;
                    if (ray_source_attacks(source, Direction'(dir_idx), ray_distance)) begin
                        enemy_attacked = 1'b1;
                        king_move_attacked = 1'b1;
                    end
                    if (source == Tile'({turn, KING}) && ray_distance == EncodedDistance'(0)
                        && ray_slider_attacks(
                            king_vacated_ray_in[dir_idx].tile,
                            Direction'(dir_idx))) begin
                        king_move_attacked = 1'b1;
                    end
                end
                if (isKnightShiftOnBoard(DEST_POS, KnightDirection'(dir_idx))) begin
                    source = knight_tile_in[dir_idx];
                    if (source.piece_type == KNIGHT) begin
                        if (source.piece_color != turn) begin
                            enemy_attacked = 1'b1;
                            king_move_attacked = 1'b1;
                        end
                    end
                end
            end
        end

        if (move_gen_op != MOVE_GEN_IDLE_OP
            && !(tile_data.piece_type != NULL_PIECE && tile_data.piece_color == turn)) begin
            for (int dir_idx=0; dir_idx<8; dir_idx++) begin
                automatic EncodedDistance ray_distance = EncodedDistance'(ray_in[dir_idx].distance);
                if (isShiftOnBoard(DEST_POS, Direction'(dir_idx), 3'd1)) begin
                    source = ray_in[dir_idx].tile;
                    move.from_pos = ray_source(Direction'(dir_idx), ray_distance);
                    move.to_pos = DEST_POS;
                    move.promo_piece = PROMO_QUEEN;
                    ep_move = is_ep_candidate(source, move);
                    if (source.piece_type != NULL_PIECE && source.piece_color == turn
                        && ray_can_move(source, Direction'(dir_idx), ray_distance, ep_move)) begin
                        if (source.piece_type == PAWN && (DEST_RANK == 0 || DEST_RANK == 7)) begin
                            for (int promo_idx=0; promo_idx<4; promo_idx++) begin
                                if (!promotion_consumed[dir_idx][promo_idx]
                                    && !promotion_found[promo_idx]) begin
                                    promotion_found[promo_idx] = 1'b1;
                                    promotion_dir[promo_idx] = Direction'(dir_idx);
                                    promotion_distance[promo_idx] = 3'(ray_distance);
                                end
                                if (!promotion_consumed[dir_idx][promo_idx]
                                    && target_destination
                                    && move.from_pos == target_move.from_pos
                                    && PromoType'(promo_idx) == target_move.promo_piece) begin
                                    target_valid = 1'b1;
                                    target_is_promotion = 1'b1;
                                end
                            end
                        end else begin
                            tactical = ep_move
                                || (tile_data.piece_type != NULL_PIECE
                                    && tile_data.piece_color != turn);
                            if (!ray_consumed[dir_idx]
                                && (move_gen_op != MOVE_GEN_QSEARCH_OP || tactical)
                                && ordinary_best.score == INVALID_MOVE_SCORE) begin
                                ordinary_best.source_dir = Direction'(dir_idx);
                                ordinary_best.source_distance = 3'(ray_distance);
                                ordinary_best.promo_piece = PROMO_QUEEN;
                                ordinary_best.is_promotion = 1'b0;
                                ordinary_best.score = move_order_score(source.piece_type);
                            end
                            if (!ray_consumed[dir_idx] && target_destination
                                && move.from_pos == target_move.from_pos) begin
                                target_valid = 1'b1;
                                target_is_promotion = 1'b0;
                            end
                        end
                    end
                end
            end

            for (int knight_dir=0; knight_dir<8; knight_dir++) begin
                if (isKnightShiftOnBoard(DEST_POS, KnightDirection'(knight_dir))) begin
                    source = knight_tile_in[knight_dir];
                    if (source.piece_type == KNIGHT && source.piece_color == turn) begin
                        move.from_pos = shiftKnightPos(DEST_POS, KnightDirection'(knight_dir));
                        move.to_pos = DEST_POS;
                        move.promo_piece = PROMO_QUEEN;
                        tactical = tile_data.piece_type != NULL_PIECE
                            && tile_data.piece_color != turn;
                        if (!knight_consumed[knight_dir]
                            && (move_gen_op != MOVE_GEN_QSEARCH_OP || tactical)
                            && ordinary_best.score == INVALID_MOVE_SCORE) begin
                            ordinary_best.source_dir = Direction'(knight_dir);
                            ordinary_best.source_distance = KNIGHT_SOURCE_DISTANCE;
                            ordinary_best.promo_piece = PROMO_QUEEN;
                            ordinary_best.is_promotion = 1'b0;
                            ordinary_best.score = move_order_score(KNIGHT);
                        end
                        if (!knight_consumed[knight_dir] && target_destination
                            && move.from_pos == target_move.from_pos) begin
                            target_valid = 1'b1;
                            target_is_promotion = 1'b0;
                        end
                    end
                end
            end
        end

        // Fixed Q/N/R/B ordering needs only presence selection, not four
        // general score comparisons and full-proposal muxes per promotion ray.
        for (int promo_idx=3; promo_idx>=0; promo_idx--)
            if (promotion_found[promo_idx]) begin
                promotion_best.source_dir = promotion_dir[promo_idx];
                promotion_best.source_distance = promotion_distance[promo_idx];
                promotion_best.promo_piece = PromoType'(promo_idx);
                promotion_best.is_promotion = 1'b1;
                promotion_best.score = MoveScore'(5'd30 - promo_idx);
            end
        if (promotion_best.score == INVALID_MOVE_SCORE)
            proposal = ordinary_best;
        else
            proposal = promotion_best;
    end

endmodule : move_generator_tile_PE
