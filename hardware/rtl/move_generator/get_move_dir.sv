
// By Emet Behrendt

// A module that take a move as input and outputs the direction of the move.
// Assumes the move is non-NULL and pseudo-legal.

import general_chess_defs::*;
import chess_helper_funcs::*;

module get_move_dir(input Move m, output logic is_knight_move, output Direction dir);

    BoardRank start_rank, end_rank;
    BoardFile start_file, end_file;

    always_comb begin
        is_knight_move = 1'bx;
        dir = Direction'('bx);

        start_rank = getRank(m.from_pos);
        start_file = getFile(m.from_pos);
        end_rank = getRank(m.to_pos);
        end_file = getFile(m.to_pos);

        // North-South Moves
        if (start_file == end_file) begin
            if (start_rank < end_rank) begin
                is_knight_move = 1'b0;
                dir = NORTH;
            end else if (start_rank > end_rank) begin
                is_knight_move = 1'b0;
                dir = SOUTH;
            end

        // East-West Moves
        end else if (start_rank == end_rank) begin
            if (start_file < end_file) begin
                is_knight_move = 1'b0;
                dir = EAST;
            end else if (start_file > end_file) begin
                is_knight_move = 1'b0;
                dir = WEST;
            end

        // Positive Diagonal Moves
        end else if (start_rank - end_rank == start_file - end_file) begin
            if (start_rank < end_rank) begin
                is_knight_move = 1'b0;
                dir = NORTH_EAST;
            end else if (start_rank > end_rank) begin
                is_knight_move = 1'b0;
                dir = SOUTH_WEST;
            end

        // Negative Diagonal Moves
        end else if (start_rank + start_file == end_rank + end_file) begin
            if (start_rank < end_rank) begin
                is_knight_move = 1'b0;
                dir = NORTH_WEST;
            end else if (start_rank > end_rank) begin
                is_knight_move = 1'b0;
                dir = SOUTH_EAST;
            end

        end else if (end_rank == start_rank + 3'd2 && end_file == start_file + 3'd1) begin
            is_knight_move = 1'b1;
            dir = Direction'(NNE);

        end else if (end_rank == start_rank - 3'd2 && end_file == start_file - 3'd1) begin
            is_knight_move = 1'b1;
            dir = Direction'(SSW);

        end else if (end_rank == start_rank + 3'd1 && end_file == start_file + 3'd2) begin
            is_knight_move = 1'b1;
            dir = Direction'(NEE);

        end else if (end_rank == start_rank - 3'd1 && end_file == start_file - 3'd2) begin
            is_knight_move = 1'b1;
            dir = Direction'(SWW);

        end else if (end_rank == start_rank - 3'd1 && end_file == start_file + 3'd2) begin
            is_knight_move = 1'b1;
            dir = Direction'(SEE);

        end else if (end_rank == start_rank + 3'd1 && end_file == start_file - 3'd2) begin
            is_knight_move = 1'b1;
            dir = Direction'(NWW);

        end else if (end_rank == start_rank - 3'd2 && end_file == start_file + 3'd1) begin
            is_knight_move = 1'b1;
            dir = Direction'(SSE);

        end else if (end_rank == start_rank + 3'd2 && end_file == start_file - 3'd1) begin
            is_knight_move = 1'b1;
            dir = Direction'(NNW);

        end
    end

endmodule : get_move_dir
