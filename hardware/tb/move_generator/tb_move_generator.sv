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
    logic noisy_cmd_ready;
    logic quiet_cmd_ready;
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
    logic quiet_resp_valid;
    ThreadID quiet_resp_thread;
    PlyIndex quiet_resp_ply;
    MoveBucketTops quiet_resp_bucket_tops;
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
    logic [11:0] history_update_failed0;
    logic [11:0] history_update_failed1;
    logic [11:0] history_update_failed2;
    logic [1:0] history_update_failed_count;
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
        .clk, .rst_n, .clear, .flush, .init_busy,
        .noisy_cmd_valid(cmd_valid && cmd != MOVE_GEN_GENERATE_QUIET),
        .noisy_cmd_ready, .noisy_cmd(cmd),
        .noisy_cmd_thread(cmd_thread), .noisy_cmd_ply(cmd_ply),
        .noisy_cmd_board(cmd_board),
        .noisy_cmd_suppress_valid(cmd_suppress_valid),
        .noisy_cmd_suppress_move(cmd_suppress_move),
        .noisy_cmd_bucket_tops(cmd_bucket_tops),
        .noisy_resp_valid(cmd_resp_valid), .noisy_resp_thread(cmd_resp_thread),
        .noisy_resp_ply(cmd_resp_ply),
        .noisy_resp_direct_valid(cmd_resp_direct_valid),
        .noisy_resp_direct_move(cmd_resp_direct_move),
        .noisy_resp_bucket_tops(cmd_resp_bucket_tops),
        .quiet_cmd_valid(cmd_valid && cmd == MOVE_GEN_GENERATE_QUIET),
        .quiet_cmd_ready,
        .quiet_cmd_thread(cmd_thread), .quiet_cmd_ply(cmd_ply),
        .quiet_cmd_board(cmd_board),
        .quiet_cmd_suppress_valid(cmd_suppress_valid),
        .quiet_cmd_suppress_move(cmd_suppress_move),
        .quiet_cmd_bucket_tops(cmd_bucket_tops),
        .quiet_resp_valid, .quiet_resp_thread, .quiet_resp_ply,
        .quiet_resp_bucket_tops,
        .pop_valid, .pop_ready, .pop_thread, .pop_ply, .pop_eligible,
        .pop_current_tops, .pop_lower_tops,
        .pop_resp_valid, .pop_resp_thread, .pop_resp_ply, .pop_resp_found,
        .pop_resp_move, .pop_resp_bucket, .pop_resp_new_top,
        .history_update_valid, .history_update_ready,
        .history_update_color, .history_update_from, .history_update_to,
        .history_update_depth,
        .history_update_failed0, .history_update_failed1, .history_update_failed2,
        .history_update_failed_count,
        .overflow_sticky, .overflow_thread, .overflow_bucket, .overflow_count,
        .stat_noisy_count, .stat_quiet_count, .stat_destination_count,
        .stat_candidate_count, .stat_history_lookup_count, .stat_generation_cycles,
        .stat_bucket_count, .stat_bucket_high_water
    );

    assign cmd_ready = cmd == MOVE_GEN_GENERATE_QUIET
        ? quiet_cmd_ready : noisy_cmd_ready;

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
        board.king_positions = KingPositions'(0);
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
        board.king_positions[WHITE] = Position'(4);
        board.king_positions[BLACK] = Position'(60);
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
        history_update_failed0 = 12'd0;
        history_update_failed1 = 12'd0;
        history_update_failed2 = 12'd0;
        history_update_failed_count = 2'd0;
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
        automatic FullBoard tracked_board = board;
        // Directed fixtures are assembled tile by tile; derive their cached
        // king squares before presenting a complete position to the DUT.
        for (int pos = 0; pos < 64; pos++) begin
            if (board.tiles[pos].piece_type == KING)
                tracked_board.king_positions[board.tiles[pos].piece_color] = Position'(pos);
        end
        while (!cmd_ready) tick();
        cmd = operation;
        cmd_board = tracked_board;
        cmd_suppress_valid = suppress_valid;
        cmd_suppress_move = suppress_move;
        cmd_bucket_tops = tops_in;
        cmd_valid = 1'b1;
        tick();
        cmd_valid = 1'b0;
        if (operation == MOVE_GEN_GENERATE_QUIET) begin
            while (!quiet_resp_valid) tick();
            direct_valid = 1'b0;
            direct_move = NULL_MOVE;
            tops_out = quiet_resp_bucket_tops;
        end else begin
            while (!cmd_resp_valid) tick();
            direct_valid = cmd_resp_direct_valid;
            direct_move = cmd_resp_direct_move;
            tops_out = cmd_resp_bucket_tops;
        end
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
        automatic bit duplicate_seen = 1'b0;
        count = 0;
        seen = '0;
        for (int iteration = 0; iteration < 512; iteration++) begin
            pop_one(eligible, tops, lower, found, move, bucket);
            if (!found) begin
                check(!duplicate_seen, "bucket collection returns each move once");
                return;
            end
            duplicate_seen |= seen[14'(move)];
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
        history_update_failed_count = 2'd0;
        history_update_valid = 1'b1;
        tick();
        history_update_valid = 1'b0;
        while (!history_update_ready) tick();
    endtask

    task automatic history_update_with_failures(
        input Move winner,
        input Move failed0,
        input Move failed1,
        input Move failed2,
        input logic [1:0] failed_count,
        input logic [5:0] depth
    );
        while (!history_update_ready) tick();
        history_update_color = WHITE;
        history_update_from = winner.from_pos;
        history_update_to = winner.to_pos;
        history_update_depth = depth;
        history_update_failed0 = {failed0.from_pos, failed0.to_pos};
        history_update_failed1 = {failed1.from_pos, failed1.to_pos};
        history_update_failed2 = {failed2.from_pos, failed2.to_pos};
        history_update_failed_count = failed_count;
        history_update_valid = 1'b1;
        tick();
        history_update_valid = 1'b0;
        while (!history_update_ready) tick();
    endtask

    task automatic launch_history_update_with_failures(
        input Move winner,
        input Move failed0,
        input Move failed1,
        input Move failed2,
        input logic [1:0] failed_count,
        input logic [5:0] depth
    );
        while (!history_update_ready) tick();
        history_update_color = WHITE;
        history_update_from = winner.from_pos;
        history_update_to = winner.to_pos;
        history_update_depth = depth;
        history_update_failed0 = {failed0.from_pos, failed0.to_pos};
        history_update_failed1 = {failed1.from_pos, failed1.to_pos};
        history_update_failed2 = {failed2.from_pos, failed2.to_pos};
        history_update_failed_count = failed_count;
        history_update_valid = 1'b1;
        tick();
        history_update_valid = 1'b0;
    endtask

    initial begin
        automatic FullBoard board;
        automatic MoveBucketTops tops;
        automatic MoveBucketTops adjacent_tops;
        automatic MoveBucketTops parent_tops;
        automatic MoveBucketTops child_tops;
        automatic logic [39:0] generation_cycles_before;
        automatic logic [39:0] baseline_quiet_generation_cycles;
        automatic logic [39:0] destination_count_before;
        automatic MoveBucketTops lower;
        automatic logic direct_valid;
        automatic Move direct_move;
        automatic int count;
        automatic logic [16383:0] seen;
        automatic Move target;
        automatic Move failed0;
        automatic Move failed1;
        automatic Move failed2;
        automatic logic found;
        automatic Move popped;
        automatic MoveBucketIndex popped_bucket;
        automatic logic concurrent_response_seen[0:1];

        clk = 1'b0;
        rst_n = 1'b0;
        pass_count = 0;
        fail_count = 0;
        idle_inputs();
        tick(2);
        rst_n = 1'b1;
        while (init_busy) tick();

        start_board(board);
        concurrent_response_seen[0] = 1'b0;
        concurrent_response_seen[1] = 1'b0;
        cmd = MOVE_GEN_GENERATE_NOISY;
        cmd_thread = ThreadID'(0);
        cmd_board = board;
        cmd_bucket_tops = '0;
        cmd_valid = 1'b1;
        check(cmd_ready, "noisy pipeline accepts first concurrent job");
        tick();
        cmd = MOVE_GEN_GENERATE_QUIET;
        cmd_thread = ThreadID'(1);
        check(quiet_cmd_ready, "quiet pipeline is available while noisy pipeline is busy");
        tick();
        cmd_valid = 1'b0;
        check(!noisy_cmd_ready && !quiet_cmd_ready, "both generation pipelines operate concurrently");
        while (!concurrent_response_seen[0] || !concurrent_response_seen[1]) begin
            if (cmd_resp_valid)
                concurrent_response_seen[int'(cmd_resp_thread)] = 1'b1;
            if (quiet_resp_valid)
                concurrent_response_seen[int'(quiet_resp_thread)] = 1'b1;
            tick();
        end
        check(concurrent_response_seen[0] && concurrent_response_seen[1],
            "both concurrent generation jobs complete");
        cmd_thread = ThreadID'(0);

        tops = '0;
        lower = '0;
        generation_cycles_before = stat_generation_cycles;
        run_command(MOVE_GEN_GENERATE_NOISY, board, 1'b0, NULL_MOVE,
            tops, direct_valid, direct_move, tops);
        $display("Start-position noisy generation cycles: %0d",
            stat_generation_cycles - generation_cycles_before);
        check(stat_generation_cycles - generation_cycles_before <= 40'd32,
            "noisy pipelined context generation stays within its cycle bound");
        collect(ALL_BUCKET_MASK, tops, lower, count, seen);
        check(count == 0, "start position has no noisy moves");

        // Static destination priority generates edge moves first, making the
        // central move the first same-bucket result returned by LIFO storage.
        empty_board(board);
        board.tiles[10] = WHITE_KNIGHT;
        board.tiles[0] = BLACK_PAWN;
        board.tiles[27] = BLACK_PAWN;
        board.tiles[63] = BLACK_KING;
        tops = '0;
        run_command(MOVE_GEN_GENERATE_NOISY, board, 1'b0, NULL_MOVE,
            tops, direct_valid, direct_move, tops);
        pop_one(GOOD_NOISY_BUCKET_MASK, tops, lower, found, popped, popped_bucket);
        check(found && same_move(popped, make_move(Position'(10), Position'(27))),
            "noisy LIFO returns central destination before edge destination");

        empty_board(board);
        board.tiles[10] = WHITE_KNIGHT;
        board.tiles[56] = WHITE_KING;
        board.tiles[63] = BLACK_KING;
        tops = '0;
        run_command(MOVE_GEN_GENERATE_QUIET, board, 1'b0, NULL_MOVE,
            tops, direct_valid, direct_move, tops);
        pop_one(QUIET_BUCKET_MASK, tops, lower, found, popped, popped_bucket);
        check(found && same_move(popped, make_move(Position'(10), Position'(27))),
            "quiet LIFO returns central destination before edge destination");

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
        baseline_quiet_generation_cycles = stat_generation_cycles - generation_cycles_before;
        $display("Start-position quiet generation cycles: %0d",
            baseline_quiet_generation_cycles);
        check(baseline_quiet_generation_cycles <= 40'd72,
            "quiet pipelined context generation stays within its cycle bound");
        collect(ALL_BUCKET_MASK, tops, lower, count, seen);
        check(count == 20, $sformatf("start position has 20 moves, found %0d", count));
        launch_history_update_with_failures(
            make_move(Position'(63), Position'(63)),
            make_move(Position'(62), Position'(62)),
            make_move(Position'(61), Position'(61)),
            make_move(Position'(60), Position'(60)),
            2'd3,
            6'd4
        );
        tops = '0;
        generation_cycles_before = stat_generation_cycles;
        run_command(MOVE_GEN_GENERATE_QUIET, board, 1'b0, NULL_MOVE,
            tops, direct_valid, direct_move, tops);
        check(stat_generation_cycles - generation_cycles_before == baseline_quiet_generation_cycles,
            "background history maintenance adds no quiet-generation cycles");
        while (!history_update_ready) tick();

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
        check($signed(dut.quiet_pipeline.gen_history[0].gen_ram.history_ram.mem[
                {target.from_pos, target.to_pos}])
                == 9'sd238,
            "history gravity reduces bonuses as history approaches its limit");
        failed0 = make_move(Position'(1), Position'(16));
        failed1 = make_move(Position'(1), Position'(11));
        failed2 = make_move(Position'(4), Position'(5));
        history_update_with_failures(target, failed0, failed1, failed2, 2'd3, 6'd4);
        check($signed(dut.quiet_pipeline.gen_history[0].gen_ram.history_ram.mem[
                {failed0.from_pos, failed0.to_pos}]) == -9'sd8,
            "failed quiet zero history receives half-strength malus");
        check($signed(dut.quiet_pipeline.gen_history[0].gen_ram.history_ram.mem[
                {failed1.from_pos, failed1.to_pos}]) == -9'sd8,
            "second failed quiet receives a malus");
        check($signed(dut.quiet_pipeline.gen_history[0].gen_ram.history_ram.mem[
                {failed2.from_pos, failed2.to_pos}]) == -9'sd8,
            "third failed quiet receives a malus");

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
