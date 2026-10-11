// Format one physical NNUE request without changing controller sequencing or latency.
import chess_defs::*;
import nnue_defs::*;
import search_defs::*;

module search_nnue_update_encoder (
    input ThreadID thread_id,
    input SearchNnuePlan plan,
    input logic [2:0] step,
    input logic draining,
    input logic first,
    input Position replay_pos,
    input Tile replay_tile,
    output logic req_valid,
    output NnueUpdateRequest req
);
    // Standard chess castling needs king and rook deltas; captures also restore
    // the captured feature on undo, including en passant's separate capture square.
    always_comb begin
        automatic logic delta_kind = plan.kind;
        automatic logic delta_reverse = plan.reverse;
        // Standard castling always moves the rook from a/h to d/f on the
        // king's rank, so it needs two additional incremental rows.
        automatic logic delta_is_castle = plan.mover.piece_type == KING
            && plan.from_pos[2:0] == BoardFile'(4)
            && (plan.to_pos[2:0] == BoardFile'(2)
                || plan.to_pos[2:0] == BoardFile'(6));
        automatic Position castle_rook_from = {
            plan.from_pos[5:3],
            plan.to_pos[2:0] == BoardFile'(2)
                ? BoardFile'(0) : BoardFile'(7)
        };
        automatic Position castle_rook_to = {
            plan.from_pos[5:3],
            plan.to_pos[2:0] == BoardFile'(2)
                ? BoardFile'(3) : BoardFile'(5)
        };
        automatic Tile castle_rook = plan.mover.piece_color == WHITE
            ? WHITE_ROOK : BLACK_ROOK;
        automatic Tile feature_tile = EMPTY_TILE;
        automatic Position feature_pos = Position'(0);
        automatic logic feature_add = 1'b0;
        req = NnueUpdateRequest'('0);
        req_valid = 1'b1;
        req.thread_id = thread_id;
        req.ply = plan.child_ply;
        req.apply = 1'b1;
        if (draining) begin
            // An ordered no-op completion marker removes the rebuild's
            // dependence on global FIFO/pipeline idle.
            req.apply = 1'b0;
            req.complete = 1'b1;
        end else if (delta_kind == NNUE_PLAN_REBUILD) begin
            feature_tile = replay_tile;
            req_valid = feature_tile.piece_type != NULL_PIECE;
            feature_pos = replay_pos;
            feature_add = 1'b1;
            req.apply = 1'b1;
            req.clear = first;
        end else if (!delta_reverse) begin
            case (step)
                3'd0: begin
                    feature_tile = plan.mover;
                    feature_pos = plan.from_pos;
                end
                3'd1: begin
                    if (plan.capture_valid) begin
                        feature_tile = plan.capture;
                        feature_pos = plan.capture_pos;
                    end else begin
                        feature_tile = plan.placed;
                        feature_pos = plan.to_pos;
                        feature_add = 1'b1;
                    end
                end
                3'd2: begin
                    if (plan.capture_valid) begin
                        feature_tile = plan.placed;
                        feature_pos = plan.to_pos;
                        feature_add = 1'b1;
                    end else begin
                        feature_tile = castle_rook;
                        feature_pos = castle_rook_from;
                    end
                end
                default: begin
                    feature_tile = castle_rook;
                    feature_pos = castle_rook_to;
                    feature_add = 1'b1;
                end
            endcase
            req.apply = 1'b1;
        end else begin
            // Undo exactly the same physical rows in reverse order so a
            // thread's single live accumulator returns to its parent.
            case (step)
                3'd0: begin
                    feature_tile = plan.placed;
                    feature_pos = plan.to_pos;
                end
                3'd1: begin
                    if (delta_is_castle) begin
                        feature_tile = castle_rook;
                        feature_pos = castle_rook_to;
                    end else if (plan.capture_valid) begin
                        feature_tile = plan.capture;
                        feature_pos = plan.capture_pos;
                        feature_add = 1'b1;
                    end else begin
                        feature_tile = plan.mover;
                        feature_pos = plan.from_pos;
                        feature_add = 1'b1;
                    end
                end
                3'd2: begin
                    if (delta_is_castle) begin
                        feature_tile = castle_rook;
                        feature_pos = castle_rook_from;
                        feature_add = 1'b1;
                    end else begin
                        feature_tile = plan.mover;
                        feature_pos = plan.from_pos;
                        feature_add = 1'b1;
                    end
                end
                default: begin
                    feature_tile = plan.mover;
                    feature_pos = plan.from_pos;
                    feature_add = 1'b1;
                end
            endcase
        end
        if (!draining && req_valid) begin
            req.white_feature = nnue_feature_index(
                feature_pos, feature_tile, WHITE);
            req.black_feature = nnue_feature_index(
                feature_pos, feature_tile, BLACK);
            req.add = feature_add;
        end
        if (!draining && delta_kind == NNUE_PLAN_DELTA)
            req.complete =
                delta_is_castle ? step == 3'd3
                : (step == 3'd1
                    && !plan.capture_valid)
                || step == 3'd2;
    end
endmodule : search_nnue_update_encoder
