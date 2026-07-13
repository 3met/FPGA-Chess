// By Emet Behrendt

import general_chess_defs::*;
import chess_helper_funcs::*;
import move_generator_defs::*;

module move_generator_tile_PE #(
    parameter int POS = 0,
    parameter int DIST_BITS = 3
) (
    input Tile tile_data,
    input RayRecord ray_in[8],
    input RayRecord king_vacated_ray_in[8],
    input Tile knight_tile_in[8],
    input Color turn,
    input MoveGenOp move_gen_op,
    input Move target_move,
    input logic has_ep,
    input BoardFile ep_file,
    input logic ray_consumed[8],
    input logic knight_consumed[8],
    input logic promotion_consumed[8][4],
    output CandidateProposal proposal,
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

    // Compact MVV/LVA-like ordering. This deliberately avoids a static-exchange
    // calculation in every destination PE; ordering does not affect correctness.
    function automatic MoveScore move_order_score(input PieceType source_piece);
        if (source_piece == SPARE_PIECE || tile_data.piece_type == SPARE_PIECE)
            return MoveScore'('x);
        if (tile_data.piece_type != NULL_PIECE)
            return MoveScore'(5'd20 + MoveScore'(tile_data.piece_type)
                - MoveScore'(source_piece));
        return MoveScore'(5'd7 - MoveScore'(source_piece));
    endfunction

    task automatic consider(
        input Move move,
        input logic is_ep,
        input logic is_promotion,
        input PromoType promo,
        input logic consumed,
        input MoveScore base_score,
        input logic target_destination,
        input logic candidate_king_safe,
        inout CandidateProposal best
    );
        automatic Move candidate;
        automatic MoveScore score;
        automatic logic tactical;

        candidate = move;
        candidate.promo_piece = promo;
        if (consumed) return;

        tactical = is_promotion || is_ep
            || (tile_data.piece_type != NULL_PIECE && tile_data.piece_color != turn);
        if (move_gen_op == MOVE_GEN_QSEARCH_OP && !tactical) return;

        score = base_score;
        if (is_promotion) score = MoveScore'(5'd30 - MoveScore'(promo));
        if (target_destination
            && candidate.from_pos == target_move.from_pos
            && (!is_promotion || candidate.promo_piece == target_move.promo_piece))
            score = MoveScore'(5'd31);

        if (!best.valid || score > best.score) begin
            best.valid = 1'b1;
            best.move = candidate;
            best.score = score;
            best.king_safe = candidate_king_safe;
        end
    endtask

    always_comb begin
        automatic CandidateProposal best;
        automatic Move move;
        automatic Tile source;
        automatic logic ep_move;
        automatic logic target_destination;

        best = NULL_PROPOSAL;
        enemy_attacked = 1'b0;
        king_move_attacked = 1'b0;

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

        target_destination = move_gen_op == MOVE_GEN_TARGETED_OP && target_move.to_pos == DEST_POS;

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
                            for (int promo_idx=0; promo_idx<4; promo_idx++)
                                consider(move, ep_move, 1'b1, PromoType'(promo_idx),
                                    promotion_consumed[dir_idx][promo_idx],
                                    MoveScore'(0), target_destination, 1'bx, best);
                        end else begin
                            consider(move, ep_move, 1'b0, PROMO_QUEEN,
                                ray_consumed[dir_idx],
                                move_order_score(source.piece_type), target_destination,
                                (source.piece_type == KING) ? !king_move_attacked : 1'bx, best);
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
                        consider(move, 1'b0, 1'b0, PROMO_QUEEN,
                            knight_consumed[knight_dir],
                            move_order_score(KNIGHT), target_destination, 1'bx, best);
                    end
                end
            end
        end

        proposal = best;
    end

endmodule : move_generator_tile_PE
