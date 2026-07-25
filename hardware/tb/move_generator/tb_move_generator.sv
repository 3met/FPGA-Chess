`timescale 1ns/1ns

import general_chess_defs::*;
import move_generator_defs::*;

module tb_move_generator;

    logic clk;
    logic rst_n;
    logic clear;
    logic flush;
    logic init_busy;
    logic cmd_valid;
    logic cmd_ready;
    MoveGenCommand cmd;
    ThreadID cmd_thread;
    PlyIndex cmd_ply;
    FullBoard cmd_board;
    logic cmd_suppress_valid;
    Move cmd_suppress_move;
    MoveBucketTops cmd_bucket_tops;
    logic cmd_resp_valid;
    ThreadID cmd_resp_thread;
    PlyIndex cmd_resp_ply;
    logic cmd_resp_direct_valid;
    Move cmd_resp_direct_move;
    MoveBucketTops cmd_resp_bucket_tops;
    logic pop_valid;
    logic pop_ready;
    ThreadID pop_thread;
    PlyIndex pop_ply;
    MoveBucketMask pop_eligible;
    MoveBucketTops pop_current_tops;
    MoveBucketTops pop_lower_tops;
    logic pop_resp_valid;
    ThreadID pop_resp_thread;
    PlyIndex pop_resp_ply;
    logic pop_resp_found;
    Move pop_resp_move;
    MoveBucketIndex pop_resp_bucket;
    MoveBucketTop pop_resp_new_top;
    logic history_update_valid;
    logic history_update_ready;
    Color history_update_color;
    Position history_update_from;
    Position history_update_to;
    logic [5:0] history_update_depth;
    logic overflow_sticky;
    ThreadID overflow_thread;
    MoveBucketIndex overflow_bucket;
    logic [15:0] overflow_count;
    logic [39:0] stat_noisy_count;
    logic [39:0] stat_quiet_count;
    logic [39:0] stat_destination_count;
    logic [39:0] stat_candidate_count;
    logic [39:0] stat_history_lookup_count;
    logic [39:0] stat_generation_cycles;
    logic [39:0] stat_bucket_count[MOVE_BUCKET_COUNT];
    MoveBucketTop stat_bucket_high_water[MOVE_BUCKET_COUNT];

    int pass_count;
    int fail_count;

    move_generator #(
        .THREAD_COUNT(2),
        .BUCKET_0_CAPACITY(32),
        .BUCKET_1_CAPACITY(32),
        .BUCKET_2_CAPACITY(32),
        .BUCKET_3_CAPACITY(32),
        .BUCKET_4_CAPACITY(32),
        .BUCKET_5_CAPACITY(32),
        .BUCKET_6_CAPACITY(32),
        .BUCKET_7_CAPACITY(32),
        .ASSERT_ON_OVERFLOW(1'b0),
        .ENABLE_STATS(1'b1)
    ) dut (
        .*
    );

    function automatic Move make_move(
        input Position from_pos,
        input Position to_pos,
        input PromoType promo = PROMO_QUEEN
    );
        automatic Move move;
        move.from_pos = from_pos;
        move.to_pos = to_pos;
        move.promo_piece = promo;
        return move;
    endfunction

    function automatic logic same_move(input Move left, input Move right);
        return left.from_pos == right.from_pos && left.to_pos == right.to_pos
            && left.promo_piece == right.promo_piece;
    endfunction

    task automatic tick(input int count = 1);
        repeat (count) begin
            clk = 1'b0; #5;
            clk = 1'b1; #5;
        end
    endtask

    task automatic check(input logic condition, input string label);
        if (condition) begin
            pass_count++;
        end else begin
            fail_count++;
            $error("FAIL: %s", label);
        end
    endtask

    task automatic empty_board(output FullBoard board, input Color turn = WHITE);
        board = FullBoard'('0);
        for (int pos = 0; pos < 64; pos++) board.tiles[pos] = EMPTY_TILE;
        board.turn = turn;
        board.castle_perms = CastlePerms'(0);
        board.has_ep = 1'b0;
        board.ep_file = BoardFile'(0);
        board.halfmove_clock = HalfmoveClock'(0);
    endtask

    task automatic start_board(output FullBoard board);
        empty_board(board);
        board.tiles[0] = WHITE_ROOK;
        board.tiles[1] = WHITE_KNIGHT;
        board.tiles[2] = WHITE_BISHOP;
        board.tiles[3] = WHITE_QUEEN;
        board.tiles[4] = WHITE_KING;
        board.tiles[5] = WHITE_BISHOP;
        board.tiles[6] = WHITE_KNIGHT;
        board.tiles[7] = WHITE_ROOK;
        for (int pos = 8; pos < 16; pos++) board.tiles[pos] = WHITE_PAWN;
        for (int pos = 48; pos < 56; pos++) board.tiles[pos] = BLACK_PAWN;
        board.tiles[56] = BLACK_ROOK;
        board.tiles[57] = BLACK_KNIGHT;
        board.tiles[58] = BLACK_BISHOP;
        board.tiles[59] = BLACK_QUEEN;
        board.tiles[60] = BLACK_KING;
        board.tiles[61] = BLACK_BISHOP;
        board.tiles[62] = BLACK_KNIGHT;
        board.tiles[63] = BLACK_ROOK;
        board.castle_perms = CastlePerms'('1);
    endtask

    task automatic idle_inputs();
        clear = 1'b0;
        flush = 1'b0;
        cmd_valid = 1'b0;
        cmd = MOVE_GEN_GENERATE_NOISY;
        cmd_thread = ThreadID'(0);
        cmd_ply = PlyIndex'(0);
        cmd_board = FullBoard'('0);
        cmd_suppress_valid = 1'b0;
        cmd_suppress_move = NULL_MOVE;
        cmd_bucket_tops = '0;
        pop_valid = 1'b0;
        pop_thread = ThreadID'(0);
        pop_ply = PlyIndex'(0);
        pop_eligible = '0;
        pop_current_tops = '0;
        pop_lower_tops = '0;
        history_update_valid = 1'b0;
        history_update_color = WHITE;
        history_update_from = Position'(0);
        history_update_to = Position'(0);
        history_update_depth = 6'd0;
    endtask

    task automatic run_command(
        input MoveGenCommand operation,
        input FullBoard board,
        input logic suppress_valid,
        input Move suppress_move,
        input MoveBucketTops tops_in,
        output logic direct_valid,
        output Move direct_move,
        output MoveBucketTops tops_out
    );
        while (!cmd_ready) tick();
        cmd = operation;
        cmd_board = board;
        cmd_suppress_valid = suppress_valid;
        cmd_suppress_move = suppress_move;
        cmd_bucket_tops = tops_in;
        cmd_valid = 1'b1;
        tick();
        cmd_valid = 1'b0;
        while (!cmd_resp_valid) tick();
        direct_valid = cmd_resp_direct_valid;
        direct_move = cmd_resp_direct_move;
        tops_out = cmd_resp_bucket_tops;
        tick();
    endtask

    task automatic pop_one(
        input MoveBucketMask eligible,
        inout MoveBucketTops tops,
        input MoveBucketTops lower,
        output logic found,
        output Move move,
        output MoveBucketIndex bucket
    );
        while (!pop_ready) tick();
        pop_eligible = eligible;
        pop_current_tops = tops;
        pop_lower_tops = lower;
        pop_valid = 1'b1;
        tick();
        pop_valid = 1'b0;
        check(pop_resp_valid, "pop response has synchronous valid");
        found = pop_resp_found;
        move = pop_resp_move;
        bucket = pop_resp_bucket;
        if (found) tops[bucket] = pop_resp_new_top;
        tick();
    endtask

    task automatic collect(
        input MoveBucketMask eligible,
        inout MoveBucketTops tops,
        input MoveBucketTops lower,
        output int count,
        output logic [16383:0] seen
    );
        automatic logic found;
        automatic Move move;
        automatic MoveBucketIndex bucket;
        count = 0;
        seen = '0;
        for (int iteration = 0; iteration < 512; iteration++) begin
            pop_one(eligible, tops, lower, found, move, bucket);
            if (!found) return;
            check(!seen[14'(move)], $sformatf("move %0d->%0d/%0d returned once",
                move.from_pos, move.to_pos, move.promo_piece));
            seen[14'(move)] = 1'b1;
            count++;
        end
        check(1'b0, "bucket collection terminated");
    endtask

    task automatic history_update(input Move move, input logic [5:0] depth);
        while (!history_update_ready) tick();
        history_update_color = WHITE;
        history_update_from = move.from_pos;
        history_update_to = move.to_pos;
        history_update_depth = depth;
        history_update_valid = 1'b1;
        tick();
        history_update_valid = 1'b0;
        while (!history_update_ready) tick();
    endtask

    initial begin
        automatic FullBoard board;
        automatic MoveBucketTops tops;
        automatic MoveBucketTops adjacent_tops;
        automatic MoveBucketTops parent_tops;
        automatic MoveBucketTops child_tops;
        automatic logic [39:0] generation_cycles_before;
        automatic logic [39:0] destination_count_before;
        automatic MoveBucketTops lower;
        automatic logic direct_valid;
        automatic Move direct_move;
        automatic int count;
        automatic logic [16383:0] seen;
        automatic Move target;
        automatic logic found;
        automatic Move popped;
        automatic MoveBucketIndex popped_bucket;

        clk = 1'b0;
        rst_n = 1'b0;
        pass_count = 0;
        fail_count = 0;
        idle_inputs();
        tick(2);
        rst_n = 1'b1;
        while (init_busy) tick();

        start_board(board);
        tops = '0;
        lower = '0;
        generation_cycles_before = stat_generation_cycles;
        run_command(MOVE_GEN_GENERATE_NOISY, board, 1'b0, NULL_MOVE,
            tops, direct_valid, direct_move, tops);
        $display("Start-position noisy generation cycles: %0d",
            stat_generation_cycles - generation_cycles_before);
        collect(ALL_BUCKET_MASK, tops, lower, count, seen);
        check(count == 0, "start position has no noisy moves");

        // An enemy king is not capturable, even when a friendly slider attacks it.
        empty_board(board);
        board.tiles[0] = WHITE_KING;
        board.tiles[4] = WHITE_ROOK;
        board.tiles[60] = BLACK_KING;
        tops = '0;
        run_command(MOVE_GEN_GENERATE_NOISY, board, 1'b0, NULL_MOVE,
            tops, direct_valid, direct_move, tops);
        collect(ALL_BUCKET_MASK, tops, lower, count, seen);
        check(count == 0, "noisy generation excludes enemy king destination");

        // Pawn-only noisy squares should not consume a destination cycle without a pawn source.
        empty_board(board);
        board.tiles[0] = WHITE_KING;
        board.tiles[63] = BLACK_KING;
        tops = '0;
        destination_count_before = stat_destination_count;
        run_command(MOVE_GEN_GENERATE_NOISY, board, 1'b0, NULL_MOVE,
            tops, direct_valid, direct_move, tops);
        check(stat_destination_count == destination_count_before,
            "empty promotion squares without a pawn are not selected");

        empty_board(board);
        board.tiles[0] = WHITE_KING;
        board.tiles[63] = BLACK_KING;
        board.has_ep = 1'b1;
        board.ep_file = BoardFile'(3);
        tops = '0;
        destination_count_before = stat_destination_count;
        run_command(MOVE_GEN_GENERATE_NOISY, board, 1'b0, NULL_MOVE,
            tops, direct_valid, direct_move, tops);
        check(stat_destination_count == destination_count_before,
            "en-passant square without a pawn is not selected");

        start_board(board);
        tops = '0;
        generation_cycles_before = stat_generation_cycles;
        run_command(MOVE_GEN_GENERATE_QUIET, board, 1'b0, NULL_MOVE,
            tops, direct_valid, direct_move, tops);
        $display("Start-position quiet generation cycles: %0d",
            stat_generation_cycles - generation_cycles_before);
        collect(ALL_BUCKET_MASK, tops, lower, count, seen);
        check(count == 20, $sformatf("start position has 20 moves, found %0d", count));

        empty_board(board);
        board.tiles[4] = WHITE_KING;
        board.tiles[48] = WHITE_PAWN;
        board.tiles[60] = BLACK_KING;
        tops = '0;
        run_command(MOVE_GEN_GENERATE_NOISY, board, 1'b0, NULL_MOVE,
            tops, direct_valid, direct_move, tops);
        collect(ALL_BUCKET_MASK, tops, lower, count, seen);
        check(count == 4, "all four promotion encodings generated");
        for (int promo = 0; promo < 4; promo++)
            check(seen[14'(make_move(Position'(48), Position'(56), PromoType'(promo)))],
                $sformatf("promotion %0d present", promo));

        empty_board(board);
        board.tiles[4] = WHITE_KING;
        board.tiles[37] = WHITE_PAWN;
        board.tiles[38] = BLACK_PAWN;
        board.tiles[60] = BLACK_KING;
        board.has_ep = 1'b1;
        board.ep_file = BoardFile'(6);
        target = make_move(Position'(37), Position'(46));
        tops = '0;
        run_command(MOVE_GEN_GENERATE_NOISY, board, 1'b0, NULL_MOVE,
            tops, direct_valid, direct_move, tops);
        collect(ALL_BUCKET_MASK, tops, lower, count, seen);
        check(seen[14'(target)], "en-passant move generated");

        empty_board(board);
        board.tiles[4] = WHITE_KING;
        board.tiles[7] = WHITE_ROOK;
        board.tiles[56] = BLACK_KING;
        board.castle_perms.white_kingside = 1'b1;
        target = make_move(Position'(4), Position'(6));
        tops = '0;
        run_command(MOVE_GEN_GENERATE_QUIET, board, 1'b0, NULL_MOVE,
            tops, direct_valid, direct_move, tops);
        collect(ALL_BUCKET_MASK, tops, lower, count, seen);
        check(seen[14'(target)], "safe castling generated");

        run_command(MOVE_GEN_VALIDATE_DIRECT, board, 1'b1, target,
            '0, direct_valid, direct_move, tops);
        check(direct_valid && same_move(direct_move, target), "direct castling validation");
        tops = '0;
        run_command(MOVE_GEN_GENERATE_QUIET, board, 1'b1, target,
            tops, direct_valid, direct_move, tops);
        collect(ALL_BUCKET_MASK, tops, lower, count, seen);
        check(!seen[14'(target)], "attempted direct move suppressed exactly");

        empty_board(board);
        board.tiles[4] = WHITE_KING;
        board.tiles[1] = WHITE_KNIGHT;
        board.tiles[60] = BLACK_KING;
        target = make_move(Position'(1), Position'(18));
        repeat (16) history_update(target, 6'd1);
        tops = '0;
        run_command(MOVE_GEN_GENERATE_QUIET, board, 1'b0, NULL_MOVE,
            tops, direct_valid, direct_move, tops);
        pop_one(MoveBucketMask'(8'b0011_0000), tops, lower, found, popped, popped_bucket);
        check(found && same_move(popped, target) && popped_bucket == QUIET_HIGH_BUCKET,
            "positive history update raises quiet move bucket");
        repeat (8) history_update(target, 6'd63);
        check($signed(dut.gen_history[0].history_ram.mem[{target.from_pos, target.to_pos}])
                == 9'sd238,
            "history gravity reduces bonuses as history approaches its limit");

        // Pins are deliberately left to board update: the sideways rook move
        // must remain in the pseudo-legal stream even though it exposes e1.
        empty_board(board);
        board.tiles[4] = WHITE_KING;
        board.tiles[12] = WHITE_ROOK;
        board.tiles[60] = BLACK_ROOK;
        board.tiles[56] = BLACK_KING;
        target = make_move(Position'(12), Position'(11));
        tops = '0;
        run_command(MOVE_GEN_GENERATE_QUIET, board, 1'b0, NULL_MOVE,
            tops, direct_valid, direct_move, tops);
        collect(ALL_BUCKET_MASK, tops, lower, count, seen);
        check(seen[14'(target)], "pinned rook move remains pseudo-legal");

        // Exercise the depth-first arena invariant independently of search.
        start_board(board);
        parent_tops = '0;
        run_command(MOVE_GEN_GENERATE_QUIET, board, 1'b0, NULL_MOVE,
            parent_tops, direct_valid, direct_move, parent_tops);
        pop_one(ALL_BUCKET_MASK, parent_tops, lower, found, popped, popped_bucket);
        check(found, "parent move popped before descent");
        child_tops = parent_tops;
        empty_board(board);
        board.tiles[0] = WHITE_KING;
        board.tiles[1] = WHITE_KNIGHT;
        board.tiles[63] = BLACK_KING;
        run_command(MOVE_GEN_GENERATE_QUIET, board, 1'b0, NULL_MOVE,
            child_tops, direct_valid, direct_move, child_tops);
        collect(ALL_BUCKET_MASK, child_tops, parent_tops, count, seen);
        check(count != 0, "child pushes and pops above inherited lower bounds");
        check(child_tops == parent_tops, "child exhaustion returns to inherited tops");
        tops = parent_tops;
        collect(ALL_BUCKET_MASK, tops, lower, count, seen);
        check(count == 19, "return preserves all unsearched parent moves");
        child_tops = parent_tops;
        run_command(MOVE_GEN_GENERATE_QUIET, board, 1'b0, NULL_MOVE,
            child_tops, direct_valid, direct_move, child_tops);
        collect(ALL_BUCKET_MASK, child_tops, parent_tops, count, seen);
        check(count != 0 && child_tops == parent_tops,
            "sibling reuses released descendant slots");

        check(!overflow_sticky, "normal tests do not overflow buckets");
        check(stat_candidate_count != 0 && stat_destination_count != 0
            && stat_history_lookup_count != 0, "generation instrumentation increments");

        // Preserve moves in thread region one while overflowing thread zero.
        empty_board(board);
        board.tiles[0] = WHITE_KING;
        board.tiles[1] = WHITE_KNIGHT;
        board.tiles[63] = BLACK_KING;
        cmd_thread = ThreadID'(1);
        pop_thread = ThreadID'(1);
        adjacent_tops = '0;
        run_command(MOVE_GEN_GENERATE_QUIET, board, 1'b0, NULL_MOVE,
            adjacent_tops, direct_valid, direct_move, adjacent_tops);
        check(adjacent_tops != MoveBucketTops'(0), "adjacent thread region receives moves");

        empty_board(board);
        board.tiles[0] = WHITE_KING;
        board.tiles[7] = WHITE_ROOK;
        board.tiles[27] = WHITE_QUEEN;
        board.tiles[63] = BLACK_KING;
        cmd_thread = ThreadID'(0);
        pop_thread = ThreadID'(0);
        tops = '0;
        run_command(MOVE_GEN_GENERATE_QUIET, board, 1'b0, NULL_MOVE,
            tops, direct_valid, direct_move, tops);
        check(overflow_sticky && overflow_thread == ThreadID'(0)
            && overflow_bucket == QUIET_LOW_BUCKET && overflow_count != 16'd0,
            "overflow identifies bucket and thread");
        check(tops[QUIET_LOW_BUCKET] == MoveBucketTop'(32),
            "overflow suppresses out-of-region top increment");
        check(stat_bucket_high_water[QUIET_LOW_BUCKET] == MoveBucketTop'(32),
            "high-water telemetry reaches the configured bucket capacity");

        pop_thread = ThreadID'(1);
        pop_one(ALL_BUCKET_MASK, adjacent_tops, lower, found, popped, popped_bucket);
        check(found, "overflow leaves adjacent thread region intact");

        $display("Bucket high-water tops: %0d %0d %0d %0d %0d %0d %0d %0d",
            stat_bucket_high_water[0], stat_bucket_high_water[1],
            stat_bucket_high_water[2], stat_bucket_high_water[3],
            stat_bucket_high_water[4], stat_bucket_high_water[5],
            stat_bucket_high_water[6], stat_bucket_high_water[7]);
        $display("Pass Count: %0d", pass_count);
        $display("Fail Count: %0d", fail_count);
        if (fail_count != 0) $fatal(1, "move generator tests failed");
        $finish;
    end

    initial begin
        #5_000_000;
        $fatal(1, "move generator test timed out");
    end

endmodule : tb_move_generator
