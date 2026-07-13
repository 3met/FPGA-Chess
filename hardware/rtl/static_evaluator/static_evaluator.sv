import general_chess_defs::*;
import chess_helper_funcs::*;
import static_evaluator_defs::*;

module static_evaluator (
    input wire clk,
    input var Tile board_tiles[64],
    input EvalScore base_eval,
    output EvalScore static_eval
);

    // Three propagation stages inspect up to three statically selected squares
    // per ray; the following evaluation register supplies the fourth stage.
    Tile board_pipe[0:STATIC_EVAL_PROP_STAGE_CNT-1][0:63];
    EvalScore base_eval_pipe[0:STATIC_EVAL_PROP_STAGE_CNT-1];
    DirectionScan scan_pipe[0:STATIC_EVAL_PROP_STAGE_CNT-1][0:63][0:7];
    EvalScore static_eval_reg;

    Tile next_board_pipe[0:STATIC_EVAL_PROP_STAGE_CNT-1][0:63];
    EvalScore next_base_eval_pipe[0:STATIC_EVAL_PROP_STAGE_CNT-1];
    DirectionScan next_scan_pipe[0:STATIC_EVAL_PROP_STAGE_CNT-1][0:63][0:7];
    EvalScore next_static_eval;

    assign static_eval = static_eval_reg;

    function automatic logic same_piece(input Tile tile, input Color color, input PieceType piece);
        return (tile.piece_type == piece && tile.piece_color == color);
    endfunction : same_piece

    function automatic TilePositionalScore color_signed(input Color color, input TilePositionalScore magnitude);
        return (color == WHITE) ? magnitude : -magnitude;
    endfunction : color_signed

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

    function automatic DirectionScan scan_next_square(
        input DirectionScan prev_scan,
        input Tile ray_tile
    );
        automatic DirectionScan scan = prev_scan;
        automatic Tile tile = ray_tile;

        if (prev_scan.piece.piece_type == NULL_PIECE) begin
            if (tile.piece_type == NULL_PIECE) begin
                scan.piece = EMPTY_TILE;
                scan.empty_count = prev_scan.empty_count + 3'd1;
            end else begin
                scan.piece = tile;
            end
        end

        return scan;
    endfunction : scan_next_square

    always_ff @(posedge clk) begin
        board_pipe <= next_board_pipe;
        base_eval_pipe <= next_base_eval_pipe;
        scan_pipe <= next_scan_pipe;
        static_eval_reg <= next_static_eval;
    end

    always_comb begin
        automatic PositionalScore positional_delta;
        automatic TilePositionalScore tile_positional_delta[64];

        for (int stage = 0; stage < STATIC_EVAL_PROP_STAGE_CNT; stage++) begin
            next_base_eval_pipe[stage] = base_eval_pipe[stage];

            for (int pos = 0; pos < 64; pos++) begin
                next_board_pipe[stage][pos] = board_pipe[stage][pos];

                for (int dir = 0; dir < 8; dir++) begin
                    next_scan_pipe[stage][pos][dir] = scan_pipe[stage][pos][dir];
                end
            end
        end

        next_base_eval_pipe[0] = base_eval;

        for (int pos = 0; pos < 64; pos++) begin
            next_board_pipe[0][pos] = board_tiles[pos];

            for (int dir_idx = 0; dir_idx < 8; dir_idx++) begin
                automatic Direction dir = Direction'(dir_idx);
                automatic int max_distance = ray_max_distance(Position'(pos), dir);
                automatic int active_stage_count = (max_distance + 2) / 3;
                automatic int start_stage = STATIC_EVAL_PROP_STAGE_CNT - active_stage_count;

                if (start_stage == 0) begin
                    automatic int scan_end = max_distance - 3 * (STATIC_EVAL_PROP_STAGE_CNT - 1);
                    automatic int scan_start = (scan_end > 2) ? scan_end - 2 : 1;
                    automatic Position first_pos = shiftPos(
                        Position'(pos), dir, RayDistance'(scan_start));
                    automatic DirectionScan scan = scan_next_square(initial_scan(), board_tiles[first_pos]);
                    if (scan_start + 1 <= scan_end) begin
                        automatic Position second_pos = shiftPos(
                            Position'(pos), dir, RayDistance'(scan_start + 1));
                        scan = scan_next_square(scan, board_tiles[second_pos]);
                    end
                    if (scan_start + 2 <= scan_end) begin
                        automatic Position third_pos = shiftPos(
                            Position'(pos), dir, RayDistance'(scan_start + 2));
                        scan = scan_next_square(scan, board_tiles[third_pos]);
                    end
                    next_scan_pipe[0][pos][dir_idx] = scan;
                end else begin
                    next_scan_pipe[0][pos][dir_idx] = initial_scan();
                end
            end
        end

        for (int stage = 1; stage < STATIC_EVAL_PROP_STAGE_CNT; stage++) begin
            next_base_eval_pipe[stage] = base_eval_pipe[stage-1];

            for (int pos = 0; pos < 64; pos++) begin
                next_board_pipe[stage][pos] = board_pipe[stage-1][pos];

                for (int dir_idx = 0; dir_idx < 8; dir_idx++) begin
                    automatic Direction dir = Direction'(dir_idx);
                    automatic int max_distance = ray_max_distance(Position'(pos), dir);
                    automatic int active_stage_count = (max_distance + 2) / 3;
                    automatic int start_stage = STATIC_EVAL_PROP_STAGE_CNT - active_stage_count;

                    if (stage < start_stage) begin
                        next_scan_pipe[stage][pos][dir_idx] = initial_scan();
                    end else begin
                        automatic int scan_end = max_distance
                            - 3 * (STATIC_EVAL_PROP_STAGE_CNT - 1 - stage);
                        automatic int scan_start = (scan_end > 2) ? scan_end - 2 : 1;
                        automatic Position first_pos = shiftPos(
                            Position'(pos), dir, RayDistance'(scan_start));
                        automatic DirectionScan scan = (stage == start_stage)
                            ? initial_scan() : scan_pipe[stage-1][pos][dir_idx];
                        scan = scan_next_square(scan, board_pipe[stage-1][first_pos]);
                        if (scan_start + 1 <= scan_end) begin
                            automatic Position second_pos = shiftPos(
                                Position'(pos), dir, RayDistance'(scan_start + 1));
                            scan = scan_next_square(scan, board_pipe[stage-1][second_pos]);
                        end
                        if (scan_start + 2 <= scan_end) begin
                            automatic Position third_pos = shiftPos(
                                Position'(pos), dir, RayDistance'(scan_start + 2));
                            scan = scan_next_square(scan, board_pipe[stage-1][third_pos]);
                        end
                        next_scan_pipe[stage][pos][dir_idx] = scan;
                    end
                end
            end
        end

        positional_delta = PositionalScore'(0);

        // Compute each square locally in ten bits, then widen only at the
        // board-level reduction. The final accumulator remains twelve bits.
        for (int pos = 0; pos < 64; pos++) begin
            tile_positional_delta[pos] = TilePositionalScore'(0);
        end

        for (int pos = 0; pos < 64; pos++) begin
            automatic Tile occupant = board_pipe[STATIC_EVAL_PROP_STAGE_CNT-1][pos];
            automatic logic [3:0] pawn_shield_count = 4'd0;
            automatic logic [4:0] mobility_count = 5'd0;
            automatic TilePositionalScore magnitude = TilePositionalScore'(0);

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
                        automatic DirectionScan scan = scan_pipe[STATIC_EVAL_PROP_STAGE_CNT-1][pos][dir];

`ifndef SYNTHESIS
                        if (scan.piece.piece_type == KING && scan.empty_count == 3'd0) begin
                            $fatal(1, "static_evaluator received adjacent kings near position %0d", pos);
                        end
`endif

                        if (same_piece(scan.piece, occupant.piece_color, PAWN) && scan.empty_count < 3'd2)
                            pawn_shield_count += 4'd1;
                    end
                    magnitude += TilePositionalScore'(pawn_shield_count) <<< 2;
                end

                if (occupant.piece_type == BISHOP) begin
                    if (scan_pipe[STATIC_EVAL_PROP_STAGE_CNT-1][pos][NORTH_EAST].empty_count == 3'd0
                            && scan_pipe[STATIC_EVAL_PROP_STAGE_CNT-1][pos][SOUTH_EAST].empty_count == 3'd0
                            && scan_pipe[STATIC_EVAL_PROP_STAGE_CNT-1][pos][SOUTH_WEST].empty_count == 3'd0
                            && scan_pipe[STATIC_EVAL_PROP_STAGE_CNT-1][pos][NORTH_WEST].empty_count == 3'd0) begin
                        magnitude -= TilePositionalScore'(TRAPPED_BISHOP_PENALTY);
                    end
                end

                if (occupant.piece_type == ROOK
                        && scan_pipe[STATIC_EVAL_PROP_STAGE_CNT-1][pos][NORTH].piece.piece_type == NULL_PIECE
                        && scan_pipe[STATIC_EVAL_PROP_STAGE_CNT-1][pos][SOUTH].piece.piece_type == NULL_PIECE) begin
                    magnitude += TilePositionalScore'(OPEN_ROOK_FILE_BONUS);
                end

                if (occupant.piece_type == PAWN
                        && can_have_north_doubled_pawn(Position'(pos))
                        && same_piece(scan_pipe[STATIC_EVAL_PROP_STAGE_CNT-1][pos][NORTH].piece, occupant.piece_color, PAWN)) begin
                    magnitude -= TilePositionalScore'(DOUBLED_PAWN_PENALTY);
                end

                if (occupant.piece_type == ROOK || occupant.piece_type == QUEEN) begin
                    for (int dir = 0; dir < 4; dir++)
                        mobility_count += 5'(scan_pipe[STATIC_EVAL_PROP_STAGE_CNT-1][pos][CARDINAL_DIR[dir]].empty_count);
                end

                if (occupant.piece_type == BISHOP || occupant.piece_type == QUEEN) begin
                    for (int dir = 0; dir < 4; dir++)
                        mobility_count += 5'(scan_pipe[STATIC_EVAL_PROP_STAGE_CNT-1][pos][DIAG_DIR[dir]].empty_count);
                end

                magnitude += TilePositionalScore'(mobility_count);
                tile_positional_delta[pos] = color_signed(occupant.piece_color, magnitude);
            end

            positional_delta += PositionalScore'(tile_positional_delta[pos]);
        end

        // This is the existing stage-7 register boundary; no further board or
        // scan state is required once the reduction has been computed.
        next_static_eval = base_eval_pipe[STATIC_EVAL_PROP_STAGE_CNT-1] + EvalScore'(positional_delta);
    end

endmodule : static_evaluator
