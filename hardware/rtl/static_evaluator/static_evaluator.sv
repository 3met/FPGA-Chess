import general_chess_defs::*;
import chess_helper_funcs::*;
import static_evaluator_defs::*;

module static_evaluator (
    input wire clk,
    input var Tile board_tiles[64],
    input EvalScore base_eval,
    output EvalScore static_eval
);

    Tile board_pipe[0:STATIC_EVAL_PIPELINE_STAGE_CNT-1][0:63];
    EvalScore base_eval_pipe[0:STATIC_EVAL_PIPELINE_STAGE_CNT-1];
    DirectionScan scan_pipe[0:STATIC_EVAL_PIPELINE_STAGE_CNT-1][0:63][0:7];
    EvalScore eval_pipe[0:STATIC_EVAL_PIPELINE_STAGE_CNT-1];

    Tile next_board_pipe[0:STATIC_EVAL_PIPELINE_STAGE_CNT-1][0:63];
    EvalScore next_base_eval_pipe[0:STATIC_EVAL_PIPELINE_STAGE_CNT-1];
    DirectionScan next_scan_pipe[0:STATIC_EVAL_PIPELINE_STAGE_CNT-1][0:63][0:7];
    EvalScore next_eval_pipe[0:STATIC_EVAL_PIPELINE_STAGE_CNT-1];

    assign static_eval = eval_pipe[STATIC_EVAL_PIPELINE_STAGE_CNT-1];

    function automatic Tile normalize_tile(input Tile tile);
        if (tile.piece_type == NULL_PIECE) begin
            return EMPTY_TILE;
        end

        return tile;
    endfunction : normalize_tile

    function automatic logic same_piece(input Tile tile, input Color color, input PieceType piece);
        automatic Tile normalized = normalize_tile(tile);
        return (normalized.piece_type == piece && normalized.piece_color == color);
    endfunction : same_piece

    function automatic PositionalScore color_signed(input Color color, input PositionalScore magnitude);
        return (color == WHITE) ? magnitude : -magnitude;
    endfunction : color_signed

    function automatic PositionalScore mobility_signed(input Color color, input logic [2:0] mobility);
        return color_signed(color, PositionalScore'(mobility));
    endfunction : mobility_signed

    function automatic logic is_legal_pawn_rank(input Position pos);
        automatic BoardRank rank = getRank(pos);
        return (rank != BoardRank'('d0) && rank != BoardRank'('d7));
    endfunction : is_legal_pawn_rank

    function automatic logic can_have_north_doubled_pawn(input Position pos);
        automatic BoardRank rank = getRank(pos);
        return (rank != BoardRank'('d0) && rank != BoardRank'('d6) && rank != BoardRank'('d7));
    endfunction : can_have_north_doubled_pawn

    function automatic DirectionScan initial_scan();
        automatic DirectionScan scan;
        scan.piece = EMPTY_TILE;
        scan.empty_count = 3'd0;
        return scan;
    endfunction : initial_scan

    always_ff @(posedge clk) begin
        board_pipe <= next_board_pipe;
        base_eval_pipe <= next_base_eval_pipe;
        scan_pipe <= next_scan_pipe;
        eval_pipe <= next_eval_pipe;
    end

    always_comb begin
        automatic PositionalScore positional_delta;

        for (int stage = 0; stage < STATIC_EVAL_PIPELINE_STAGE_CNT; stage++) begin
            next_base_eval_pipe[stage] = base_eval_pipe[stage];
            next_eval_pipe[stage] = eval_pipe[stage];

            for (int pos = 0; pos < 64; pos++) begin
                next_board_pipe[stage][pos] = board_pipe[stage][pos];

                for (int dir = 0; dir < 8; dir++) begin
                    next_scan_pipe[stage][pos][dir] = scan_pipe[stage][pos][dir];
                end
            end
        end

        next_base_eval_pipe[0] = base_eval;
        next_eval_pipe[0] = UNKNOWN_EVAL_SCORE;

        for (int pos = 0; pos < 64; pos++) begin
            next_board_pipe[0][pos] = normalize_tile(board_tiles[pos]);

            for (int dir = 0; dir < 8; dir++) begin
                next_scan_pipe[0][pos][dir] = initial_scan();
            end
        end

        for (int stage = 1; stage < STATIC_EVAL_PIPELINE_STAGE_CNT; stage++) begin
            next_base_eval_pipe[stage] = base_eval_pipe[stage-1];
            next_eval_pipe[stage] = UNKNOWN_EVAL_SCORE;

            for (int pos = 0; pos < 64; pos++) begin
                next_board_pipe[stage][pos] = board_pipe[stage-1][pos];

                for (int dir = 0; dir < 8; dir++) begin
                    automatic DirectionScan prev_scan = scan_pipe[stage-1][pos][dir];

                    next_scan_pipe[stage][pos][dir] = prev_scan;

                    if (isShiftOnBoard(Position'(pos), Direction'(dir), RayDistance'(stage))
                            && prev_scan.piece.piece_type == NULL_PIECE) begin
                        automatic Tile ray_tile = normalize_tile(board_pipe[stage-1][shiftPos(Position'(pos), Direction'(dir), RayDistance'(stage))]);

                        if (ray_tile.piece_type == NULL_PIECE) begin
                            next_scan_pipe[stage][pos][dir].piece = EMPTY_TILE;
                            next_scan_pipe[stage][pos][dir].empty_count = prev_scan.empty_count + 3'd1;
                        end else begin
                            next_scan_pipe[stage][pos][dir].piece = ray_tile;
                            next_scan_pipe[stage][pos][dir].empty_count = prev_scan.empty_count;
                        end
                    end
                end
            end
        end

        positional_delta = PositionalScore'(0);

        for (int pos = 0; pos < 64; pos++) begin
            automatic Tile occupant = next_board_pipe[STATIC_EVAL_PIPELINE_STAGE_CNT-1][pos];

`ifndef SYNTHESIS
            if (!is_legal_pawn_rank(Position'(pos)) && occupant.piece_type == PAWN) begin
                $fatal(1, "static_evaluator received pawn on first or eighth rank at position %0d", pos);
            end

            if (occupant.piece_type == SPARE_PIECE) begin
                $fatal(1, "static_evaluator received SPARE_PIECE at position %0d", pos);
            end
`endif

            if (occupant.piece_type != NULL_PIECE) begin
                if (occupant.piece_type == KING) begin
                    for (int dir = 0; dir < 8; dir++) begin
                        automatic DirectionScan scan = next_scan_pipe[STATIC_EVAL_PIPELINE_STAGE_CNT-1][pos][dir];

`ifndef SYNTHESIS
                        if (scan.piece.piece_type == KING && scan.empty_count == 3'd0) begin
                            $fatal(1, "static_evaluator received adjacent kings near position %0d", pos);
                        end
`endif

                        if (same_piece(scan.piece, occupant.piece_color, PAWN) && scan.empty_count < 3'd2) begin
                            positional_delta += color_signed(occupant.piece_color, PAWN_SHIELD_BONUS);
                        end
                    end
                end

                if (occupant.piece_type == BISHOP) begin
                    if (next_scan_pipe[STATIC_EVAL_PIPELINE_STAGE_CNT-1][pos][NORTH_EAST].empty_count == 3'd0
                            && next_scan_pipe[STATIC_EVAL_PIPELINE_STAGE_CNT-1][pos][SOUTH_EAST].empty_count == 3'd0
                            && next_scan_pipe[STATIC_EVAL_PIPELINE_STAGE_CNT-1][pos][SOUTH_WEST].empty_count == 3'd0
                            && next_scan_pipe[STATIC_EVAL_PIPELINE_STAGE_CNT-1][pos][NORTH_WEST].empty_count == 3'd0) begin
                        positional_delta += color_signed(occupant.piece_color, -TRAPPED_BISHOP_PENALTY);
                    end
                end

                if (occupant.piece_type == ROOK
                        && next_scan_pipe[STATIC_EVAL_PIPELINE_STAGE_CNT-1][pos][NORTH].piece.piece_type == NULL_PIECE
                        && next_scan_pipe[STATIC_EVAL_PIPELINE_STAGE_CNT-1][pos][SOUTH].piece.piece_type == NULL_PIECE) begin
                    positional_delta += color_signed(occupant.piece_color, OPEN_ROOK_FILE_BONUS);
                end

                if (occupant.piece_type == PAWN
                        && can_have_north_doubled_pawn(Position'(pos))
                        && same_piece(next_scan_pipe[STATIC_EVAL_PIPELINE_STAGE_CNT-1][pos][NORTH].piece, occupant.piece_color, PAWN)) begin
                    positional_delta += color_signed(occupant.piece_color, -DOUBLED_PAWN_PENALTY);
                end

                if (occupant.piece_type == ROOK || occupant.piece_type == QUEEN) begin
                    for (int dir = 0; dir < 4; dir++) begin
                        positional_delta += mobility_signed(occupant.piece_color, next_scan_pipe[STATIC_EVAL_PIPELINE_STAGE_CNT-1][pos][CARDINAL_DIR[dir]].empty_count);
                    end
                end

                if (occupant.piece_type == BISHOP || occupant.piece_type == QUEEN) begin
                    for (int dir = 0; dir < 4; dir++) begin
                        positional_delta += mobility_signed(occupant.piece_color, next_scan_pipe[STATIC_EVAL_PIPELINE_STAGE_CNT-1][pos][DIAG_DIR[dir]].empty_count);
                    end
                end
            end
        end

        next_eval_pipe[STATIC_EVAL_PIPELINE_STAGE_CNT-1] =
            next_base_eval_pipe[STATIC_EVAL_PIPELINE_STAGE_CNT-1] + EvalScore'(positional_delta);
    end

endmodule : static_evaluator
