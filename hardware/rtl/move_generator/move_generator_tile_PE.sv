// By Emet Behrendt

import general_chess_defs::*;
import chess_helper_funcs::*;
import move_generator_defs::*;

module move_generator_tile_PE #(parameter int POS = 0) (
    input Tile tile_data,
    input RayRecord ray_in[8],
    input Tile knight_tile_in[8],
    input Color turn,
    input MoveGenOp move_gen_op,
    input Move target_move,
    input logic has_ep,
    input BoardFile ep_file,
    input logic ray_consumed[8],
    input logic knight_consumed[8],
    input logic promotion_consumed[8][4],
    input MoveMaskIndex ray_mask_index[8],
    input MoveMaskIndex knight_mask_index[8],
    input MoveMaskIndex promotion_mask_index[8][4],
    output CandidateProposal proposal
);

    localparam Position DEST_POS = Position'(POS);
    localparam BoardRank DEST_RANK = BoardRank'(POS / 8);
    localparam BoardFile DEST_FILE = BoardFile'(POS % 8);

    function automatic Position ray_source(input Direction dir, input logic [2:0] distance);
        return shiftPos(DEST_POS, dir, distance);
    endfunction

    function automatic logic is_ep_candidate(input Tile source, input Move move);
        if (!has_ep || source.piece_type != PAWN || tile_data.piece_type != NULL_PIECE) return 1'b0;
        if (DEST_FILE != ep_file) return 1'b0;
        if (turn == WHITE) return getRank(move.from_pos) == 3'd4 && DEST_RANK == 3'd5;
        return getRank(move.from_pos) == 3'd3 && DEST_RANK == 3'd2;
    endfunction

    function automatic logic ray_can_move(
        input Tile source,
        input Direction dir,
        input logic [2:0] distance,
        input logic ep_move
    );
        case (source.piece_type)
            PAWN: begin
                if (turn == WHITE) begin
                    if (dir == SOUTH && tile_data.piece_type == NULL_PIECE)
                        return distance == 1 || (distance == 2 && DEST_RANK == 3);
                    return distance == 1 && (dir == SOUTH_WEST || dir == SOUTH_EAST)
                        && ((tile_data.piece_type != NULL_PIECE && tile_data.piece_color == BLACK) || ep_move);
                end
                if (dir == NORTH && tile_data.piece_type == NULL_PIECE)
                    return distance == 1 || (distance == 2 && DEST_RANK == 4);
                return distance == 1 && (dir == NORTH_WEST || dir == NORTH_EAST)
                    && ((tile_data.piece_type != NULL_PIECE && tile_data.piece_color == WHITE) || ep_move);
            end
            BISHOP: return isDirDiag(dir);
            ROOK: return isDirCardinal(dir);
            QUEEN: return 1'b1;
            KING: return distance == 1;
            default: return 1'b0;
        endcase
    endfunction

    function automatic MoveScore exchange_score(
        input PieceType source_piece,
        input logic [2:0] attacker_count,
        input logic [2:0] defender_count,
        input PieceType weakest_defender
    );
        automatic logic signed [6:0] score;

        score = 7'sd32;
        if (tile_data.piece_type != NULL_PIECE) begin
            if (PIECE_VALS_1[tile_data.piece_type] > PIECE_VALS_1[source_piece]) score += 7'sd8;
            else if (PIECE_VALS_1[tile_data.piece_type] == PIECE_VALS_1[source_piece]
                && attacker_count > defender_count) score += 7'sd4;
            else if (attacker_count > defender_count) begin
                if (defender_count == 0) score += 7'sd3;
                else if (PIECE_VALS_1[weakest_defender] + PIECE_VALS_1[tile_data.piece_type]
                    < PIECE_VALS_1[source_piece]) score -= 7'sd2;
            end else score -= 7'sd6;
        end

        // Preserve the old preference for the weakest usable attacker.
        score += 7'sd7 - $signed({1'b0, source_piece});
        if (score < 1) return MoveScore'(1);
        return MoveScore'(score);
    endfunction

    task automatic consider(
        input Move move,
        input logic is_ep,
        input logic is_promotion,
        input PromoType promo,
        input logic consumed,
        input MoveMaskIndex index,
        input MoveScore base_score,
        input logic target_destination,
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
        if (is_promotion) score = MoveScore'(8'd220 + (3 - int'(promo)));
        if (target_destination
            && candidate.from_pos == target_move.from_pos
            && (!is_promotion || candidate.promo_piece == target_move.promo_piece))
            score = MoveScore'(8'hff);

        if (!best.valid || score > best.score) begin
            best.valid = 1'b1;
            best.move = candidate;
            best.mask_index = index;
            best.score = score;
        end
    endtask

    always_comb begin
        automatic CandidateProposal best;
        automatic logic [2:0] attacker_count;
        automatic logic [2:0] defender_count;
        automatic PieceType weakest_defender;
        automatic MoveScore piece_score[7];
        automatic Move move;
        automatic Tile source;
        automatic logic ep_move;
        automatic logic target_destination;
        automatic logic control_sensitivity;

        best = NULL_PROPOSAL;
        // Keep older synthesis/simulation tools sensitive to controls read by helper tasks.
        control_sensitivity = ^{turn, move_gen_op, target_move, has_ep, ep_file, tile_data};
        for (int sensitivity_idx=0; sensitivity_idx<8; sensitivity_idx++) begin
            control_sensitivity ^= ray_consumed[sensitivity_idx];
            control_sensitivity ^= knight_consumed[sensitivity_idx];
            for (int promo_idx=0; promo_idx<4; promo_idx++)
                control_sensitivity ^= promotion_consumed[sensitivity_idx][promo_idx];
        end
        attacker_count = 0;
        defender_count = 0;
        weakest_defender = KING;

        for (int dir_idx=0; dir_idx<8; dir_idx++) begin
            if (isShiftOnBoard(DEST_POS, Direction'(dir_idx), 3'd1)) begin
                source = ray_in[dir_idx].tile;
                if (source.piece_type != NULL_PIECE) begin
                    if (source.piece_color == turn) attacker_count++;
                    else begin
                        defender_count++;
                        if (source.piece_type < weakest_defender) weakest_defender = source.piece_type;
                    end
                end
            end
            if (isKnightShiftOnBoard(DEST_POS, KnightDirection'(dir_idx))) begin
                source = knight_tile_in[dir_idx];
                if (source.piece_type == KNIGHT) begin
                    if (source.piece_color == turn) attacker_count++;
                    else begin
                        defender_count++;
                        if (KNIGHT < weakest_defender) weakest_defender = KNIGHT;
                    end
                end
            end
        end

        // Exchange context is destination-local, so compute it once per source piece class.
        piece_score[NULL_PIECE] = MoveScore'(0);
        piece_score[PAWN] = exchange_score(PAWN, attacker_count, defender_count, weakest_defender);
        piece_score[KNIGHT] = exchange_score(KNIGHT, attacker_count, defender_count, weakest_defender);
        piece_score[BISHOP] = exchange_score(BISHOP, attacker_count, defender_count, weakest_defender);
        piece_score[ROOK] = exchange_score(ROOK, attacker_count, defender_count, weakest_defender);
        piece_score[QUEEN] = exchange_score(QUEEN, attacker_count, defender_count, weakest_defender);
        piece_score[KING] = exchange_score(KING, attacker_count, defender_count, weakest_defender);
        target_destination = move_gen_op == MOVE_GEN_TARGETED_OP && target_move.to_pos == DEST_POS;

        if (move_gen_op != MOVE_GEN_IDLE_OP
            && !(tile_data.piece_type != NULL_PIECE && tile_data.piece_color == turn)) begin
            for (int dir_idx=0; dir_idx<8; dir_idx++) begin
                if (isShiftOnBoard(DEST_POS, Direction'(dir_idx), 3'd1)) begin
                    source = ray_in[dir_idx].tile;
                    move.from_pos = ray_source(Direction'(dir_idx), ray_in[dir_idx].distance);
                    move.to_pos = DEST_POS;
                    move.promo_piece = PROMO_QUEEN;
                    ep_move = is_ep_candidate(source, move);
                    if (source.piece_type != NULL_PIECE && source.piece_color == turn
                        && ray_can_move(source, Direction'(dir_idx), ray_in[dir_idx].distance, ep_move)) begin
                        if (source.piece_type == PAWN && (DEST_RANK == 0 || DEST_RANK == 7)) begin
                            for (int promo_idx=0; promo_idx<4; promo_idx++)
                                consider(move, ep_move, 1'b1, PromoType'(promo_idx),
                                    promotion_consumed[dir_idx][promo_idx],
                                    promotion_mask_index[dir_idx][promo_idx],
                                    MoveScore'(0), target_destination, best);
                        end else begin
                            consider(move, ep_move, 1'b0, PROMO_QUEEN,
                                ray_consumed[dir_idx],
                                ray_mask_index[dir_idx],
                                piece_score[source.piece_type], target_destination, best);
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
                            knight_mask_index[knight_dir],
                            piece_score[KNIGHT], target_destination, best);
                    end
                end
            end
        end

        proposal = control_sensitivity ? best : best;
    end

endmodule : move_generator_tile_PE
