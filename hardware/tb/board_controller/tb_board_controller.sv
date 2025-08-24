
// Run in modelsim with:
// vsim -L altera_mf_ver -L lpm -L 220model work.tb_board_controller
// restart -f; run -all

`timescale 1ns/1ns

// Import definitions from the packages
import general_chess_defs::*;
import chess_helper_funcs::*;
import board_controller_defs::*;

module tb_board_controller;

  // Testbench signals
  logic clk;
  // Inputs to DUT
  FullBoard board_in;
  BoardHash board_hash_in;
  Move move_in;
  logic [3:0] set_data;
  ThreadID thread_id;
  DepthType search_depth;
  BoardOp board_op;
  // Outputs from DUT
  FullBoard board_out;
  BoardHash board_hash_out;
  EvalScore pst_eval_out;

  // Variables to store states for comparison
  FullBoard test_board, target_board;
  EvalScore test_pst, target_pst;

  // Instantiate the board_controller module
  board_controller dut (
    .clk(clk),
    .board_op(board_op),
    .board_in(board_in),
    .board_hash_in(board_hash_in),
    .pst_eval_in(test_pst),
    .move_in(move_in),
    .set_data(set_data),
    .thread_id(thread_id),
    .search_depth(search_depth),
    .board_out(board_out),
    .board_hash_out(board_hash_out),
    .pst_eval_out(pst_eval_out)
  );

  // Clock generation (10ns period)
  task do_clock(int cnt=1);
    for (int i=0; i<cnt; i++) begin
        clk = 1'b0; #5;
        clk = 1'b1; #5;
    end
  endtask

  // Places a tile on the board
  task placeTile(Tile t, Position pos, bit waitToFinish=1);
    board_in = test_board;
    set_data = t;
    move_in.end_pos = pos;
    board_op = BOARD_SET_TILE_OP;

    do_clock(BOARD_CTRL_STAGE_CNT);
    test_board = board_out;
    test_pst = pst_eval_out;
    $display("[%8t] PST mid-task : %0d", $time, test_pst);

  endtask

  initial begin
    // Initialize inputs
    board_hash_in = 32'h0;
    test_pst   = 16'd0;
    thread_id     = '0;
    search_depth  = '0;
    set_data      = 4'd0;
    // Initialize full board to empty
    for (int i = 0; i < 64; i++) begin
      test_board.tiles[i] = EMPTY_TILE;
    end
    test_board.turn         = WHITE;
    test_board.castle_perms = '{1'b0, 1'b0, 1'b0, 1'b0}; // No castling rights
    test_board.has_ep       = 1'b0;
    test_board.ep_file      = '0;
    test_board.halfmove_clk = 7'd0;
    

    board_op = BOARD_IDLE_OP;  // Idle by default

    $display(toFen(test_board));

    // Wait a couple of cycles for stability
    do_clock(2);

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

    $display("[%8t] Board after setup: %s", $time, toFen(test_board));
    $display("[%8t] PST   after setup: %0d", $time, test_pst);

    assert(test_pst === 0);

    // Save initial state for later comparison
    target_board = test_board;
    target_pst   = test_pst;

    // --- Test 1: PUSH Move --- //
    // Move the pawn from e2 (12) to e3 (20)
    move_in.start_pos   = Position'(12);
    move_in.end_pos     = Position'(20);
    move_in.promo_piece = PROMO_QUEEN; // Not used for a normal pawn move
    board_op = BOARD_PUSH_MOVE_OP;

    // Capture the push operation for one clock cycle
    @(posedge clk);
    board_op = BOARD_IDLE_OP;

    // Wait for pipeline to propagate
    do_clock(BOARD_CTRL_STAGE_CNT);

    // After PUSH, capture the updated board and PST eval
    $display("Board after PUSH move:   %s", toFen(test_board));
    $display("PST eval after PUSH move: %0d", test_pst);

    // --- Test 2: REVERSE Move --- //
    // Feed the updated board state into the DUT to reverse the last move
    board_op      = BOARD_REVERSE_MOVE_OP;

    @(posedge clk);
    board_op = BOARD_IDLE_OP;

    // Wait for pipeline to propagate the reverse
    repeat (BOARD_CTRL_STAGE_CNT) @(posedge clk);

    // After REVERSE, capture the board and PST eval
    // board_after_reverse = board_out;
    // pst_after_reverse   = pst_eval_out;
    $display("Board after REVERSE move:   %s", toFen(target_board));
    $display("PST eval after REVERSE move: %0d", test_board);

    // Check that the board and PST match the initial state
    if (target_board != test_board) begin
      $error("Board state after reverse does not match initial state!");
    end
    if (target_pst != test_pst) begin
      $error("PST eval after reverse does not match initial value!");
    end

    $display("Test finished running.");
    $stop;
  end
endmodule
