// Run in Questa/ModelSim from the repository root after compiling RTL and this file:
// vsim -t ns work.tb_static_evaluator
// run -all

`timescale 1ns/1ns

import general_chess_defs::*;
import chess_helper_funcs::*;
import static_evaluator_defs::*;

module tb_static_evaluator;

    logic clk;
    Tile board_tiles[64];
    EvalScore base_eval;
    EvalScore static_eval;

    Tile test_board[64];
    Tile board_a[64];
    Tile board_b[64];
    Tile board_c[64];

    int pass_count = 0;
    int error_count = 0;

    static_evaluator dut (
        .clk(clk),
        .board_tiles(board_tiles),
        .base_eval(base_eval),
        .static_eval(static_eval)
    );

    task automatic do_clock(input int cnt = 1);
        for (int i = 0; i < cnt; i++) begin
            clk = 1'b0; #5;
            clk = 1'b1; #5;
        end
    endtask

    function automatic Tile norm_tile(input Tile tile);
        if (tile.piece_type == NULL_PIECE) begin
            return EMPTY_TILE;
        end

        return tile;
    endfunction

    function automatic logic same_piece(input Tile tile, input Color color, input PieceType piece);
        automatic Tile normalized = norm_tile(tile);
        return (normalized.piece_type == piece && normalized.piece_color == color);
    endfunction

    function automatic EvalScore color_signed(input Color color, input EvalScore magnitude);
        return (color == WHITE) ? magnitude : -magnitude;
    endfunction

    function automatic DirectionScan ref_scan(input Tile board[64], input Position pos, input Direction dir);
        automatic DirectionScan scan;

        scan.piece = EMPTY_TILE;
        scan.empty_count = 3'd0;

        for (int distance = 1; distance < 8; distance++) begin
            if (isShiftOnBoard(pos, dir, RayDistance'(distance))) begin
                automatic Tile occupant = norm_tile(board[shiftPos(pos, dir, RayDistance'(distance))]);

                if (occupant.piece_type == NULL_PIECE) begin
                    scan.empty_count += 3'd1;
                end else begin
                    scan.piece = occupant;
                    return scan;
                end
            end else begin
                return scan;
            end
        end

        return scan;
    endfunction

    function automatic EvalScore ref_eval(input Tile board[64], input EvalScore base);
        automatic EvalScore total = base;

        for (int pos = 0; pos < 64; pos++) begin
            automatic Tile occupant = norm_tile(board[pos]);

            if (occupant.piece_type != NULL_PIECE) begin
                if (occupant.piece_type == KING) begin
                    for (int dir = 0; dir < 8; dir++) begin
                        automatic DirectionScan scan = ref_scan(board, Position'(pos), Direction'(dir));

                        if (same_piece(scan.piece, occupant.piece_color, PAWN) && scan.empty_count < 3'd2) begin
                            total += color_signed(occupant.piece_color, PAWN_SHIELD_BONUS);
                        end
                    end
                end

                if (occupant.piece_type == BISHOP) begin
                    if (ref_scan(board, Position'(pos), NORTH_EAST).empty_count == 3'd0
                            && ref_scan(board, Position'(pos), SOUTH_EAST).empty_count == 3'd0
                            && ref_scan(board, Position'(pos), SOUTH_WEST).empty_count == 3'd0
                            && ref_scan(board, Position'(pos), NORTH_WEST).empty_count == 3'd0) begin
                        total += color_signed(occupant.piece_color, -TRAPPED_BISHOP_PENALTY);
                    end
                end

                if (occupant.piece_type == ROOK
                        && ref_scan(board, Position'(pos), NORTH).piece.piece_type == NULL_PIECE
                        && ref_scan(board, Position'(pos), SOUTH).piece.piece_type == NULL_PIECE) begin
                    total += color_signed(occupant.piece_color, OPEN_ROOK_FILE_BONUS);
                end

                if (occupant.piece_type == PAWN
                        && getRank(Position'(pos)) != BoardRank'('d6)
                        && same_piece(ref_scan(board, Position'(pos), NORTH).piece, occupant.piece_color, PAWN)) begin
                    total += color_signed(occupant.piece_color, -DOUBLED_PAWN_PENALTY);
                end

                if (occupant.piece_type == ROOK || occupant.piece_type == QUEEN) begin
                    for (int dir = 0; dir < 4; dir++) begin
                        total += color_signed(occupant.piece_color, EvalScore'(ref_scan(board, Position'(pos), CARDINAL_DIR[dir]).empty_count));
                    end
                end

                if (occupant.piece_type == BISHOP || occupant.piece_type == QUEEN) begin
                    for (int dir = 0; dir < 4; dir++) begin
                        total += color_signed(occupant.piece_color, EvalScore'(ref_scan(board, Position'(pos), DIAG_DIR[dir]).empty_count));
                    end
                end
            end
        end

        return total;
    endfunction

    task automatic init_empty(output Tile board[64]);
        for (int pos = 0; pos < 64; pos++) begin
            board[pos] = EMPTY_TILE;
        end
    endtask

    task automatic drive_board(input Tile board[64], input EvalScore base);
        for (int pos = 0; pos < 64; pos++) begin
            board_tiles[pos] = board[pos];
        end

        base_eval = base;
    endtask

    task automatic record_pass();
        pass_count += 1;
    endtask

    task automatic record_fail(input string message);
        error_count += 1;
        $error("[%6t] %s", $time, message);
    endtask

    task automatic expect_equal(input bit condition, input string message);
        if (condition) begin
            record_pass();
        end else begin
            record_fail(message);
        end
    endtask

    task automatic expect_score(input EvalScore expected, input string test_name);
        expect_equal(static_eval === expected,
            $sformatf("%s expected=%0d found=%0d", test_name, expected, static_eval));
    endtask

    task automatic run_case(input string test_name, input EvalScore base, input EvalScore expected);
        drive_board(test_board, base);
        do_clock(1);
        do_clock(STATIC_EVAL_PIPELINE_STAGE_CNT - 1);
        expect_score(expected, test_name);
    endtask

    task automatic test_base_passthrough();
        init_empty(test_board);
        run_case("empty base zero", EvalScore'(0), EvalScore'(0));
        run_case("empty base positive", EvalScore'(1234), EvalScore'(1234));
        run_case("empty base negative", EvalScore'(-567), EvalScore'(-567));
    endtask

    task automatic test_pawn_shield();
        init_empty(test_board);
        test_board[Position'(4)] = WHITE_KING;
        test_board[Position'(11)] = WHITE_PAWN;
        test_board[Position'(12)] = WHITE_PAWN;
        test_board[Position'(13)] = WHITE_PAWN;
        run_case("white pawn shield", EvalScore'(0), EvalScore'(12));

        init_empty(test_board);
        test_board[Position'(60)] = BLACK_KING;
        test_board[Position'(51)] = BLACK_PAWN;
        test_board[Position'(52)] = BLACK_PAWN;
        test_board[Position'(53)] = BLACK_PAWN;
        run_case("black pawn shield", EvalScore'(0), EvalScore'(-12));
    endtask

    task automatic test_trapped_bishop();
        init_empty(test_board);
        test_board[Position'(27)] = WHITE_BISHOP;
        test_board[Position'(18)] = WHITE_KNIGHT;
        test_board[Position'(20)] = WHITE_KNIGHT;
        test_board[Position'(34)] = BLACK_KNIGHT;
        test_board[Position'(36)] = BLACK_KNIGHT;
        run_case("white trapped bishop", EvalScore'(0), EvalScore'(-4));
    endtask

    task automatic test_open_rook_file();
        init_empty(test_board);
        test_board[Position'(0)] = WHITE_ROOK;
        run_case("white rook open file and mobility", EvalScore'(0), EvalScore'(20));

        init_empty(test_board);
        test_board[Position'(56)] = BLACK_ROOK;
        run_case("black rook open file and mobility", EvalScore'(0), EvalScore'(-20));
    endtask

    task automatic test_doubled_pawns();
        init_empty(test_board);
        test_board[Position'(8)] = WHITE_PAWN;
        test_board[Position'(24)] = WHITE_PAWN;
        run_case("white doubled pawns", EvalScore'(0), EvalScore'(-6));

        init_empty(test_board);
        test_board[Position'(40)] = BLACK_PAWN;
        test_board[Position'(48)] = BLACK_PAWN;
        run_case("black doubled pawns", EvalScore'(0), EvalScore'(6));
    endtask

    task automatic test_slider_mobility();
        init_empty(test_board);
        test_board[Position'(27)] = WHITE_QUEEN;
        run_case("white queen mobility", EvalScore'(0), EvalScore'(27));

        init_empty(test_board);
        test_board[Position'(36)] = BLACK_QUEEN;
        run_case("black queen mobility", EvalScore'(0), EvalScore'(-27));
    endtask

    task automatic mirror_and_swap(input Tile src[64], output Tile dst[64]);
        for (int pos = 0; pos < 64; pos++) begin
            automatic Tile src_tile = norm_tile(src[mirrorPos(Position'(pos))]);

            if (src_tile.piece_type == NULL_PIECE) begin
                dst[pos] = EMPTY_TILE;
            end else begin
                dst[pos] = Tile'({Color'(~src_tile.piece_color), src_tile.piece_type});
            end
        end
    endtask

    task automatic test_symmetry();
        automatic EvalScore white_expected;
        automatic EvalScore black_expected;

        init_empty(board_a);
        board_a[Position'(4)] = WHITE_KING;
        board_a[Position'(11)] = WHITE_PAWN;
        board_a[Position'(12)] = WHITE_PAWN;
        board_a[Position'(27)] = WHITE_QUEEN;
        board_a[Position'(32)] = WHITE_ROOK;
        board_a[Position'(35)] = BLACK_BISHOP;

        mirror_and_swap(board_a, board_b);
        white_expected = ref_eval(board_a, EvalScore'(200));
        black_expected = ref_eval(board_b, EvalScore'(-200));

        expect_equal(black_expected === -white_expected,
            $sformatf("mirror expected negation white=%0d black=%0d", white_expected, black_expected));

        for (int pos = 0; pos < 64; pos++) begin
            test_board[pos] = board_a[pos];
        end
        run_case("white asymmetric position", EvalScore'(200), white_expected);

        for (int pos = 0; pos < 64; pos++) begin
            test_board[pos] = board_b[pos];
        end
        run_case("mirrored black asymmetric position", EvalScore'(-200), black_expected);
    endtask

    task automatic test_combined_terms();
        automatic EvalScore expected;

        init_empty(test_board);
        test_board[Position'(4)] = WHITE_KING;
        test_board[Position'(11)] = WHITE_PAWN;
        test_board[Position'(12)] = WHITE_PAWN;
        test_board[Position'(24)] = WHITE_PAWN;
        test_board[Position'(27)] = WHITE_QUEEN;
        test_board[Position'(56)] = BLACK_ROOK;
        expected = ref_eval(test_board, EvalScore'(1000));
        run_case("combined base and positional terms", EvalScore'(1000), expected);
    endtask

    task automatic test_back_to_back_requests();
        automatic EvalScore expected_a;
        automatic EvalScore expected_b;
        automatic EvalScore expected_c;

        init_empty(board_a);
        board_a[Position'(0)] = WHITE_ROOK;
        expected_a = ref_eval(board_a, EvalScore'(10));

        init_empty(board_b);
        board_b[Position'(60)] = BLACK_KING;
        board_b[Position'(51)] = BLACK_PAWN;
        board_b[Position'(52)] = BLACK_PAWN;
        expected_b = ref_eval(board_b, EvalScore'(-20));

        init_empty(board_c);
        board_c[Position'(27)] = WHITE_QUEEN;
        board_c[Position'(36)] = BLACK_QUEEN;
        expected_c = ref_eval(board_c, EvalScore'(30));

        drive_board(board_a, EvalScore'(10));
        do_clock(1);
        drive_board(board_b, EvalScore'(-20));
        do_clock(1);
        drive_board(board_c, EvalScore'(30));
        do_clock(1);
        init_empty(test_board);
        drive_board(test_board, EvalScore'(0));
        do_clock(STATIC_EVAL_PIPELINE_STAGE_CNT - 3);
        expect_score(expected_a, "back-to-back request A");
        do_clock(1);
        expect_score(expected_b, "back-to-back request B");
        do_clock(1);
        expect_score(expected_c, "back-to-back request C");
    endtask

    initial begin
        clk = 1'b0;
        init_empty(test_board);
        drive_board(test_board, EvalScore'(0));
        do_clock(STATIC_EVAL_PIPELINE_STAGE_CNT);

        $display("=== Static evaluator testbench ===");
        test_base_passthrough();
        test_pawn_shield();
        test_trapped_bishop();
        test_open_rook_file();
        test_doubled_pawns();
        test_slider_mobility();
        test_symmetry();
        test_combined_terms();
        test_back_to_back_requests();

        $display("Testbench run complete.");
        $display("Pass Count: %0d", pass_count);
        $display("Fail Count: %0d", error_count);

        if (error_count != 0) $fatal(1, "static_evaluator testbench failed");
        $finish;
    end

    // Bound all event waits so a broken pipeline fails promptly in CI.
    initial begin
        #1_000_000;
        $fatal(1, "static_evaluator testbench timed out");
    end

endmodule : tb_static_evaluator
