
// Run in modelsim with:
// vsim -L altera_mf_ver -L lpm -L 220model -t ns work.tb_board_update_pipeline
// restart -f; run -all

`timescale 1ns/1ns

// Import definitions from the packages
import general_chess_defs::*;
import chess_helper_funcs::*;
import board_update_pipeline_defs::*;

module tb_board_update_pipeline;

    // Testbench signals
    logic clk;
    // Inputs to DUT
    FullBoard board_in;
    ZobristKey zobrist_key_in;
    Move move_in;
    logic [3:0] set_data;
    ThreadID thread_id;
    PlyIndex search_ply;
    BoardOp board_op;
    // Outputs from DUT
    FullBoard board_out;
    ZobristKey zobrist_key_out;
    EvalScore pst_eval_out;

    // Variables to store states for comparison
    FullBoard test_board;
    EvalScore test_pst;

    // Instantiate the board_update_pipeline module
    board_update_pipeline dut (
        .clk(clk),
        .board_op(board_op),
        .board_in(board_in),
        .zobrist_key_in(zobrist_key_in),
        .pst_eval_in(test_pst),
        .move_in(move_in),
        .set_data(set_data),
        .thread_id(thread_id),
        .search_ply(search_ply),
        .board_out(board_out),
        .zobrist_key_out(zobrist_key_out),
        .pst_eval_out(pst_eval_out)
    );

    // Clock generation (10ns period)
    task do_clock(int cnt=1);
        for (int i=0; i<cnt; i++) begin
                clk = 1'b0; #5;
                clk = 1'b1; #5;
        end
    endtask

    // Scoring Variables
	int passCount = 0;
	int errorCount = 0;

    // Asserts that two board FENs are equal
    function void assert_equal(string target, string found, string test_name="");
        assert (target == found) begin
            passCount += 1;
            if (test_name != "") $display("[%6t] Passed: %s", $time, test_name);
        end else begin
            errorCount += 1;
            $error("[%6t] ASSERT FAILED: %s\nTARGET=%p\nFOUND =%p", $time, test_name, target, found);
        end
    endfunction

    // Places a tile on the board
    task placeTile(Tile t, Position pos);
        automatic EvalScore oldPST = test_pst;

        board_in = test_board;
        set_data = t;
        move_in.to_pos = pos;
        board_op = BOARD_SET_TILE_OP;

        do_clock(1);
        board_in = 'dx;
        set_data = 'dx;
        move_in = 'dx;
        board_op = BOARD_IDLE_OP;
        do_clock(BOARD_UPDATE_PIPELINE_STAGE_CNT-1);
        test_board = board_out;
        test_pst = pst_eval_out;
    endtask

    // Completes a move on the board
    task pushMove(Move m);
        board_in = test_board;
        move_in = m;
        board_op = BOARD_PUSH_MOVE_OP;

        do_clock(1);
        board_in = 'dx;
        set_data = 'dx;
        move_in = 'dx;
        board_op = BOARD_IDLE_OP;
        do_clock(BOARD_UPDATE_PIPELINE_STAGE_CNT-1);

        test_board = board_out;
        test_pst = pst_eval_out;
        search_ply += 1;
    endtask

    // Completes a move on the board
    task reverseMove();
        board_in = test_board;
        board_op = BOARD_REVERSE_MOVE_OP;

        do_clock(1);
        board_in = 'dx;
        set_data = 'dx;
        move_in = 'dx;
        board_op = BOARD_IDLE_OP;
        do_clock(BOARD_UPDATE_PIPELINE_STAGE_CNT-1);

        test_board = board_out;
        test_pst = pst_eval_out;
        search_ply -= 1;
    endtask

    // Sets the turn
    task setTurn(Color c);
        board_in = test_board;
        set_data = {3'bxxx, c};
        board_op = BOARD_SET_TURN_OP;
        do_clock(BOARD_UPDATE_PIPELINE_STAGE_CNT);
        test_board = board_out;
        test_pst = pst_eval_out;
    endtask

    // Sets the castle perms
    task setCastlePerms(CastlePerms cp);
        board_in = test_board;
        set_data = cp;
        board_op = BOARD_SET_CASTLE_PERMS_OP;
        do_clock(BOARD_UPDATE_PIPELINE_STAGE_CNT);
        test_board = board_out;
        test_pst = pst_eval_out;
    endtask

    // Sets en passant status
    task setEnPassant(logic has_ep, logic [2:0] ep_file);
        board_in = test_board;
        set_data = {ep_file, has_ep};
        board_op = BOARD_SET_EN_PASSANT_OP;
        do_clock(BOARD_UPDATE_PIPELINE_STAGE_CNT);
        test_board = board_out;
        test_pst = pst_eval_out;
    endtask


    initial begin
        // Initialize inputs
        zobrist_key_in = 32'h0;
        test_pst   = 16'd0;
        thread_id     = '0;
        search_ply  = '0;
        set_data      = 4'd0;
        // Initialize full board to empty
        for (int i = 0; i < 64; i++) begin
            test_board.tiles[i] = EMPTY_TILE;
        end
        test_board.turn         = WHITE;
        test_board.castle_perms = '{1'b0, 1'b0, 1'b0, 1'b0}; // No castling rights
        test_board.has_ep       = 1'b0;
        test_board.ep_file      = '0;
        test_board.halfmove_clock = 7'd0;
        

        board_op = BOARD_IDLE_OP;  // Idle by default

        // Wait a couple of cycles for stability
        do_clock(2);

        $display("=== Begin Setting Up Board ===");
        placeTile(WHITE_ROOK,   0);
        placeTile(WHITE_KNIGHT, 1);
        placeTile(WHITE_BISHOP, 2);
        placeTile(WHITE_QUEEN,  3);
        placeTile(WHITE_KING,   4);
        placeTile(WHITE_BISHOP, 5);
        placeTile(WHITE_KNIGHT, 6);
        placeTile(WHITE_ROOK,   7);
        for (int pos=8; pos<16; pos++) placeTile(WHITE_PAWN,  pos);
        for (int pos=16; pos<48; pos++) placeTile(EMPTY_TILE,  pos);
        for (int pos=48; pos<56; pos++) placeTile(BLACK_PAWN,  pos);
        placeTile(BLACK_ROOK,   56);
        placeTile(BLACK_KNIGHT, 57);
        placeTile(BLACK_BISHOP, 58);
        placeTile(BLACK_QUEEN,  59);
        placeTile(BLACK_KING,   60);
        placeTile(BLACK_BISHOP, 61);
        placeTile(BLACK_KNIGHT, 62);
        placeTile(BLACK_ROOK,   63);
        // #1; $display("[%6t] Board after placing tiles: %s", $time, toFen(test_board));
        setTurn(WHITE);
        // #1; $display("[%6t] Board after setting turn: %s", $time, toFen(test_board));
        setCastlePerms(4'b1111);
        // #1; $display("[%6t] Board after setting castle: %s", $time, toFen(test_board));
        setEnPassant(1'b0, 3'bxxx);
        
        assert_equal("rnbqkbnr/pppppppp/8/8/8/8/PPPPPPPP/RNBQKBNR w KQkq - 0", toFen(test_board), "Board Setup");
        assert(test_pst === 0);


        // --- Test 1: PUSH Move ---
        $display("=== Begin Pushing Moves ===");
        pushMove(Move'({6'd12, 6'd28, PROMO_UNKNOWN})); // Move 1, e2e4
        assert_equal("rnbqkbnr/pppppppp/8/8/4P3/8/PPPP1PPP/RNBQKBNR b KQkq - 0", toFen(test_board), "Initial Move");
        pushMove(Move'({6'd53, 6'd37, PROMO_UNKNOWN})); // Move 2: f7f5
        assert_equal("rnbqkbnr/ppppp1pp/8/5p2/4P3/8/PPPP1PPP/RNBQKBNR w KQkq - 0", toFen(test_board));
        pushMove(Move'({6'd28, 6'd37, PROMO_UNKNOWN})); // Move 3: e4f5
        assert_equal("rnbqkbnr/ppppp1pp/8/5P2/8/8/PPPP1PPP/RNBQKBNR b KQkq - 0", toFen(test_board), "First Capture");
        pushMove(Move'({6'd52, 6'd36, PROMO_UNKNOWN})); // Move 4: e7e5
        assert_equal("rnbqkbnr/pppp2pp/8/4pP2/8/8/PPPP1PPP/RNBQKBNR w KQkq e6 0", toFen(test_board), "Create possible EP");
        pushMove(Move'({6'd37, 6'd44, PROMO_UNKNOWN})); // Move 5: f5e6
        assert_equal("rnbqkbnr/pppp2pp/4P3/8/8/8/PPPP1PPP/RNBQKBNR b KQkq - 0", toFen(test_board), "EP Kill");
        pushMove(Move'({6'd62, 6'd45, PROMO_UNKNOWN})); // Move 6: g8f6
        assert_equal("rnbqkb1r/pppp2pp/4Pn2/8/8/8/PPPP1PPP/RNBQKBNR w KQkq - 1", toFen(test_board));
        pushMove(Move'({6'd44, 6'd51, PROMO_UNKNOWN})); // Move 7: e6d7
        assert_equal("rnbqkb1r/pppP2pp/5n2/8/8/8/PPPP1PPP/RNBQKBNR b KQkq - 0", toFen(test_board), "First check");
        pushMove(Move'({6'd60, 6'd53, PROMO_UNKNOWN})); // Move 8: e8f7
        assert_equal("rnbq1b1r/pppP1kpp/5n2/8/8/8/PPPP1PPP/RNBQKBNR w KQ - 1", toFen(test_board), "Lose Black castle perms");
        pushMove(Move'({6'd51, 6'd58, PROMO_QUEEN  })); // Move 9: d7c8q
        assert_equal("rnQq1b1r/ppp2kpp/5n2/8/8/8/PPPP1PPP/RNBQKBNR b KQ - 0", toFen(test_board), "First promotion");
        pushMove(Move'({6'd48, 6'd32, PROMO_UNKNOWN})); // Move 10: a7a5
        assert_equal("rnQq1b1r/1pp2kpp/5n2/p7/8/8/PPPP1PPP/RNBQKBNR w KQ - 0", toFen(test_board));
        pushMove(Move'({6'd5,  6'd12 , PROMO_UNKNOWN})); // Move 11: f1e2
        assert_equal("rnQq1b1r/1pp2kpp/5n2/p7/8/8/PPPPBPPP/RNBQK1NR b KQ - 1", toFen(test_board));
        pushMove(Move'({6'd56, 6'd40, PROMO_UNKNOWN})); // Move 12: a8a6
        assert_equal("1nQq1b1r/1pp2kpp/r4n2/p7/8/8/PPPPBPPP/RNBQK1NR w KQ - 2", toFen(test_board));
        pushMove(Move'({6'd6 , 6'd21, PROMO_UNKNOWN})); // Move 13: g1f3
        assert_equal("1nQq1b1r/1pp2kpp/r4n2/p7/8/5N2/PPPPBPPP/RNBQK2R b KQ - 3", toFen(test_board));
        pushMove(Move'({6'd59, 6'd60, PROMO_UNKNOWN})); // Move 14: d8e8
        assert_equal("1nQ1qb1r/1pp2kpp/r4n2/p7/8/5N2/PPPPBPPP/RNBQK2R w KQ - 4", toFen(test_board));
        pushMove(Move'({6'd4 , 6'd6 , PROMO_UNKNOWN})); // Move 15: e1g1
        assert_equal("1nQ1qb1r/1pp2kpp/r4n2/p7/8/5N2/PPPPBPPP/RNBQ1RK1 b - - 5", toFen(test_board), "First Castle");
        pushMove(Move'({6'd53, 6'd62, PROMO_UNKNOWN})); // Move 16: f7g8
        assert_equal("1nQ1qbkr/1pp3pp/r4n2/p7/8/5N2/PPPPBPPP/RNBQ1RK1 w - - 6", toFen(test_board));


        // --- Test 2: Reverse Move ---
        $display("=== Begin Reversing Moves ===");
        reverseMove(); // Move 16: f7g8
        assert_equal("1nQ1qb1r/1pp2kpp/r4n2/p7/8/5N2/PPPPBPPP/RNBQ1RK1 b - - 5", toFen(test_board), "First reverse move");
        reverseMove(); // Move 15: e1g1
        assert_equal("1nQ1qb1r/1pp2kpp/r4n2/p7/8/5N2/PPPPBPPP/RNBQK2R w KQ - 4", toFen(test_board), "Reverse First Castle");
        reverseMove(); // Move 14: d8e8
        assert_equal("1nQq1b1r/1pp2kpp/r4n2/p7/8/5N2/PPPPBPPP/RNBQK2R b KQ - 3", toFen(test_board));
        reverseMove(); // Move 13: g1f3
        assert_equal("1nQq1b1r/1pp2kpp/r4n2/p7/8/8/PPPPBPPP/RNBQK1NR w KQ - 2", toFen(test_board));
        reverseMove(); // Move 12: a8a6
        assert_equal("rnQq1b1r/1pp2kpp/5n2/p7/8/8/PPPPBPPP/RNBQK1NR b KQ - 1", toFen(test_board));
        reverseMove(); // Move 11: f1e2
        assert_equal("rnQq1b1r/1pp2kpp/5n2/p7/8/8/PPPP1PPP/RNBQKBNR w KQ - 0", toFen(test_board));
        reverseMove(); // Move 10: a7a5
        assert_equal("rnQq1b1r/ppp2kpp/5n2/8/8/8/PPPP1PPP/RNBQKBNR b KQ - 0", toFen(test_board));
        reverseMove(); // Move 9: d7c8q
        assert_equal("rnbq1b1r/pppP1kpp/5n2/8/8/8/PPPP1PPP/RNBQKBNR w KQ - 1", toFen(test_board), "Reverse First promotion");
        reverseMove(); // Move 8: e8f7
        assert_equal("rnbqkb1r/pppP2pp/5n2/8/8/8/PPPP1PPP/RNBQKBNR b KQkq - 0", toFen(test_board), "Reverse Lose Black castle perms");
        reverseMove(); // Move 7: e6d7
        assert_equal("rnbqkb1r/pppp2pp/4Pn2/8/8/8/PPPP1PPP/RNBQKBNR w KQkq - 1", toFen(test_board), "Reverse First check");
        reverseMove(); // Move 6: g8f6
        assert_equal("rnbqkbnr/pppp2pp/4P3/8/8/8/PPPP1PPP/RNBQKBNR b KQkq - 0", toFen(test_board));
        reverseMove(); // Move 5: f5e6
        assert_equal("rnbqkbnr/pppp2pp/8/4pP2/8/8/PPPP1PPP/RNBQKBNR w KQkq e6 0", toFen(test_board), "Reverse EP Kill");
        reverseMove(); // Move 4: e7e5
        assert_equal("rnbqkbnr/ppppp1pp/8/5P2/8/8/PPPP1PPP/RNBQKBNR b KQkq - 0", toFen(test_board), "Reverse Create possible EP");
        reverseMove(); // Move 3: e4f5
        assert_equal("rnbqkbnr/ppppp1pp/8/5p2/4P3/8/PPPP1PPP/RNBQKBNR w KQkq - 0", toFen(test_board), "Reverse First Capture");
        reverseMove(); // Move 2: f7f5
        assert_equal("rnbqkbnr/pppppppp/8/8/4P3/8/PPPP1PPP/RNBQKBNR b KQkq - 0", toFen(test_board));
        reverseMove(); // Move 1, e2e4
        assert_equal("rnbqkbnr/pppppppp/8/8/8/8/PPPPPPPP/RNBQKBNR w KQkq - 0", toFen(test_board), "Reverse Initial Move");

        // Assert that PST is equal in the starting position
        assert(test_pst === 'd0) begin
            passCount += 1;
        end else begin
            errorCount += 1;
            $error("[%6t] PST Eval was not reset: expected=0, found=%0d", $time, test_pst);
        end;

        // --- Test 3: Overwriting ---
        // Overwrite piece to ensure board and PST updates are correct.
        placeTile(BLACK_ROOK, 0);
        assert(test_pst < DRAW_EVAL_SCORE) begin
            passCount += 1;
        end else begin
            errorCount += 1;
            $error("[%6t] PST Eval did not update correctly: expected: x>0, found: x=%0d", $time, test_pst);
        end;
        assert_equal("rnbqkbnr/pppppppp/8/8/8/8/PPPPPPPP/rNBQKBNR w KQkq - 0", toFen(test_board));

        placeTile(WHITE_ROOK, 0);
        assert(test_pst === DRAW_EVAL_SCORE) begin
            passCount += 1;
        end else begin
            errorCount += 1;
            $error("[%6t] PST Eval did not update correctly: expected: x=0, found: x=%0d", $time, test_pst);
        end;
        assert_equal("rnbqkbnr/pppppppp/8/8/8/8/PPPPPPPP/RNBQKBNR w KQkq - 0", toFen(test_board));

        placeTile(WHITE_ROOK, 0);
        assert(test_pst === DRAW_EVAL_SCORE) begin
            passCount += 1;
        end else begin
            errorCount += 1;
            $error("[%6t] PST Eval did not update correctly: expected: x=0, found: x=%0d", $time, test_pst);
        end;
        assert_equal("rnbqkbnr/pppppppp/8/8/8/8/PPPPPPPP/RNBQKBNR w KQkq - 0", toFen(test_board));

        // Ensure that adding white pieces only increases the score
        for (int piece=PAWN; piece<=QUEEN; piece+=1) begin
            placeTile(Tile'({WHITE, piece}), 24);

            assert(test_pst > DRAW_EVAL_SCORE) begin
                passCount += 1;
            end else begin
                errorCount += 1;
                $error("[%6t] PST Eval did not update correctly: expected: x=0, found: x=%0d", $time, test_pst);
            end;

            placeTile(EMPTY_TILE, 24);

            assert(test_pst === DRAW_EVAL_SCORE) begin
                passCount += 1;
            end else begin
                errorCount += 1;
                $error("[%6t] PST Eval did not update correctly: expected: x=0, found: x=%0d", $time, test_pst);
            end;
            assert_equal("rnbqkbnr/pppppppp/8/8/8/8/PPPPPPPP/RNBQKBNR w KQkq - 0", toFen(test_board));
        end



        $display("Testbench run complete.");
        $display("Pass Count: %0d", passCount);
		$display("Fail Count: %0d", errorCount);
		$display("Pass Rate : %0.2f%%", 100.0 * passCount / (passCount + errorCount));
        $stop;
    end
endmodule
