
// Run in modelsim with:
// vsim -L altera_mf_ver -L lpm -L 220model work.tb_board_controller
// restart -f; run -all

`timescale 1ns/1ps
module tb_board_controller;
  // Import definitions from the packages
  import general_chess_defs::*;
  import board_controller_defs::*;

  // Testbench signals
  logic clk;
  // Inputs to DUT
  FullBoard board_in;
  BoardHash board_hash_in;
  EvalScore pst_eval_in;
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
  FullBoard board_initial;
  EvalScore pst_initial;
  FullBoard board_after_push;
  EvalScore pst_after_push;
  FullBoard board_after_reverse;
  EvalScore pst_after_reverse;

  // Instantiate the board_controller module
  board_controller dut (
    .clk(clk),
    .board_op(board_op),
    .board_in(board_in),
    .board_hash_in(board_hash_in),
    .pst_eval_in(pst_eval_in),
    .move_in(move_in),
    .set_data(set_data),
    .thread_id(thread_id),
    .search_depth(search_depth),
    .board_out(board_out),
    .board_hash_out(board_hash_out),
    .pst_eval_out(pst_eval_out)
  );

  // Clock generation (10ns period)
  initial begin
    clk = 0;
    forever #5 clk = ~clk;
  end

  initial begin
    // Initialize inputs
    board_hash_in = 32'h0;
    pst_eval_in   = 16'd0;
    thread_id     = '0;
    search_depth  = '0;
    set_data      = 4'd0;
    // Initialize full board to empty
    for (int i = 0; i < 64; i++) begin
      board_in.tiles[i] = EMPTY_TILE;
    end
    board_in.turn         = WHITE;
    board_in.castle_perms = '{1'b0, 1'b0, 1'b0, 1'b0}; // No castling rights
    board_in.has_ep       = 1'b0;
    board_in.ep_file      = '0;
    board_in.halfmove_clk = 7'd0;

    // Place a White pawn at e2 (rank=1, file=4 => pos = 1*8+4 = 12)
    board_in.tiles[12] = WHITE_PAWN;

    // Save initial state for later comparison
    board_initial = board_in;
    pst_initial   = pst_eval_in;

    board_op = BOARD_IDLE_OP;  // Idle by default

    $display(toFen(board_in));

    // Wait a couple of cycles for stability
    repeat (2) @(posedge clk);

    // --- Test 1: PUSH Move --- //
    // Move the pawn from e2 (12) to e3 (20)
    move_in.start_pos   = Position'(12);
    move_in.end_pos     = Position'(20);
    move_in.promo_piece = PROMO_QUEEN; // Not used for a normal pawn move
    board_op = BOARD_PUSH_MOVE_OP;

    // Capture the push operation for one clock cycle
    @(posedge clk);
    board_op = BOARD_IDLE_OP;

    // Wait for pipeline to propagate (7 pipeline stages)
    repeat (7) @(posedge clk);

    // After PUSH, capture the updated board and PST eval
    board_after_push = board_out;
    pst_after_push   = pst_eval_out;
    $display("Board after PUSH move:   %s", general_chess_defs::toFen(board_after_push));
    $display("PST eval after PUSH move: %0d", pst_after_push);

    // --- Test 2: REVERSE Move --- //
    // Feed the updated board state into the DUT to reverse the last move
    board_in      = board_after_push;
    pst_eval_in   = pst_after_push;
    board_op      = BOARD_REVERSE_MOVE_OP;

    @(posedge clk);
    board_op = BOARD_IDLE_OP;

    // Wait for pipeline to propagate the reverse
    repeat (7) @(posedge clk);

    // After REVERSE, capture the board and PST eval
    board_after_reverse = board_out;
    pst_after_reverse   = pst_eval_out;
    $display("Board after REVERSE move:   %s", general_chess_defs::toFen(board_after_reverse));
    $display("PST eval after REVERSE move: %0d", pst_after_reverse);

    // Check that the board and PST match the initial state
    if (board_after_reverse != board_initial) begin
      $error("Board state after reverse does not match initial state!");
    end
    if (pst_after_reverse != pst_initial) begin
      $error("PST eval after reverse does not match initial value!");
    end

    $display("Test finished running.");
    $stop;
  end
endmodule
