`timescale 1ns/1ns

import chess_defs::*;
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
    logic cmd_resp_valid;
    ThreadID cmd_resp_thread;
    PlyIndex cmd_resp_ply;
    logic cmd_resp_direct_valid;
    Move cmd_resp_direct_move;
    logic quiet_resp_valid;
    ThreadID quiet_resp_thread;
    PlyIndex quiet_resp_ply;
    logic pop_valid;
    logic pop_ready;
    logic bad_noisy_enable;
    logic node_init_valid;
    ThreadID pop_thread;
    PlyIndex pop_ply;
    logic pop_resp_valid;
    ThreadID pop_resp_thread;
    PlyIndex pop_resp_ply;
    logic pop_resp_found;
    Move pop_resp_move;
    MoveBucketIndex pop_resp_bucket;
    logic pop_valid_vec[2], pop_ready_vec[2], pop_resp_valid_vec[2], pop_resp_ready_vec[2];
    logic bad_noisy_enable_vec[2];
    logic node_init_valid_vec[2];
    logic node_init_ready_vec[2];
    PlyIndex node_init_ply_vec[2];
    PlyIndex pop_ply_vec[2], pop_resp_ply_vec[2];
    logic pop_resp_found_vec[2]; Move pop_resp_move_vec[2];
    MoveBucketIndex pop_resp_bucket_vec[2];
    logic history_update_valid;
    logic history_update_ready;
    ThreadID history_update_thread;
    Color history_update_color;
    Position history_update_from;
    Position history_update_to;
    logic [5:0] history_update_depth;
    logic [11:0] history_update_failed0;
    logic [11:0] history_update_failed1;
    logic [11:0] history_update_failed2;
    logic [1:0] history_update_failed_count;
    logic overflow_sticky;
    logic [39:0] stat_noisy_count;
    logic [39:0] stat_quiet_count;
    logic [39:0] stat_destination_count;
    logic [39:0] stat_candidate_count;
    logic [39:0] stat_history_lookup_count;
    logic [39:0] stat_generation_cycles;
    logic [39:0] stat_bucket_count[MOVE_BUCKET_COUNT];
    MoveBucketTop stat_bucket_high_water[MOVE_BUCKET_COUNT];
    logic monitor_promotion_writes;
    int promotion_write_count;
    PromoType promotion_write_order[4];

    int pass_count;
    int fail_count;

    move_generator #(
        .THREAD_COUNT(2),
        .MOVE_MEMORY_ENTRIES(512),
        .ENABLE_STATS(1'b1)
    ) dut (
        .clk, .rst_n, .clear, .flush, .init_busy,
        .noisy_cmd_valid(cmd_valid && cmd != MOVE_GEN_GENERATE_QUIET),
        .noisy_cmd_ready, .noisy_cmd(cmd),
        .noisy_cmd_thread(cmd_thread), .noisy_cmd_ply(cmd_ply),
        .noisy_cmd_board(cmd_board),
        .noisy_cmd_suppress_valid(cmd_suppress_valid),
        .noisy_cmd_suppress_move(cmd_suppress_move),
        .noisy_resp_valid(cmd_resp_valid), .noisy_resp_thread(cmd_resp_thread),
        .noisy_resp_ply(cmd_resp_ply),
        .noisy_resp_direct_valid(cmd_resp_direct_valid),
        .noisy_resp_direct_move(cmd_resp_direct_move),
        .quiet_cmd_valid(cmd_valid && cmd == MOVE_GEN_GENERATE_QUIET),
        .quiet_cmd_ready,
        .quiet_cmd_thread(cmd_thread), .quiet_cmd_ply(cmd_ply),
        .quiet_cmd_board(cmd_board),
        .quiet_cmd_suppress_valid(cmd_suppress_valid),
        .quiet_cmd_suppress_move(cmd_suppress_move),
        .quiet_resp_valid, .quiet_resp_thread, .quiet_resp_ply,
        .pop_valid(pop_valid_vec), .pop_ready(pop_ready_vec), .pop_ply(pop_ply_vec),
        .node_init_valid(node_init_valid_vec), .node_init_ready(node_init_ready_vec),
        .node_init_ply(node_init_ply_vec),
        .bad_noisy_enable(bad_noisy_enable_vec),
        .pop_resp_valid(pop_resp_valid_vec),
        .pop_resp_ready(pop_resp_ready_vec), .pop_resp_ply(pop_resp_ply_vec),
        .pop_resp_found(pop_resp_found_vec),
        .pop_resp_move(pop_resp_move_vec), .pop_resp_bucket(pop_resp_bucket_vec),
        .history_update_valid, .history_update_ready,
        .history_update_thread,
        .history_update_color, .history_update_from, .history_update_to,
        .history_update_depth,
        .history_update_failed0, .history_update_failed1, .history_update_failed2,
        .history_update_failed_count,
        .overflow_sticky,
        .stat_noisy_count, .stat_quiet_count, .stat_destination_count,
        .stat_candidate_count, .stat_history_lookup_count, .stat_generation_cycles,
        .stat_bucket_count, .stat_bucket_high_water
    );

    // Capture the noisy lane's actual store order independently of readback.
    always @(posedge clk) begin
        if (monitor_promotion_writes && dut.write_valid[0]
                && dut.write_move[0].from_pos == Position'(48)
                && dut.write_move[0].to_pos == Position'(56)) begin
            if (promotion_write_count < 4)
                promotion_write_order[promotion_write_count] =
                    dut.write_move[0].promo_piece;
            promotion_write_count = promotion_write_count + 1;
        end
    end

    always_comb begin
        for (int tid = 0; tid < 2; tid++) begin
            pop_valid_vec[tid] = pop_valid && pop_thread == ThreadID'(tid);
            pop_ply_vec[tid] = pop_ply;
            bad_noisy_enable_vec[tid]
                = bad_noisy_enable && pop_thread == ThreadID'(tid);
            node_init_valid_vec[tid]
                = node_init_valid && cmd_thread == ThreadID'(tid);
            node_init_ply_vec[tid] = cmd_ply;
            pop_resp_ready_vec[tid] = 1'b1;
        end
        pop_ready = pop_ready_vec[pop_thread];
        pop_resp_valid = pop_resp_valid_vec[pop_thread];
        pop_resp_thread = pop_thread;
        pop_resp_ply = pop_resp_ply_vec[pop_thread];
        pop_resp_found = pop_resp_found_vec[pop_thread];
        pop_resp_move = pop_resp_move_vec[pop_thread];
        pop_resp_bucket = pop_resp_bucket_vec[pop_thread];
    end

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
        board.castling_rights = CastlingRights'(0);
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
        board.castling_rights = CastlingRights'('1);
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
        pop_valid = 1'b0;
        bad_noisy_enable = 1'b0;
        node_init_valid = 1'b0;
        pop_thread = ThreadID'(0);
        pop_ply = PlyIndex'(0);
        history_update_valid = 1'b0;
        history_update_thread = ThreadID'(0);
        history_update_color = WHITE;
        history_update_from = Position'(0);
        history_update_to = Position'(0);
        history_update_depth = 6'd0;
        history_update_failed0 = 12'd0;
        history_update_failed1 = 12'd0;
        history_update_failed2 = 12'd0;
        history_update_failed_count = 2'd0;
    endtask

    // Establish the legal quiet-generation phase without adding any moves.
    task automatic prepare_quiet_phase();
        automatic ThreadID saved_pop_thread = pop_thread;
        automatic PlyIndex saved_pop_ply = pop_ply;
        node_init_valid = 1'b1;
        while (!node_init_ready_vec[cmd_thread]) tick();
        tick();
        node_init_valid = 1'b0;
        cmd = MOVE_GEN_GENERATE_NOISY;
        cmd_board = FullBoard'('0);
        while (!cmd_ready) tick();
        cmd_valid = 1'b1;
        tick();
        cmd_valid = 1'b0;
        while (!cmd_resp_valid) tick();
        tick();
        pop_thread = cmd_thread;
        pop_ply = cmd_ply;
        while (!pop_ready) tick();
        pop_valid = 1'b1;
        tick();
        pop_valid = 1'b0;
        while (!pop_resp_valid) tick();
        check(!pop_resp_found, "empty noisy generation reaches quiet phase");
        tick();
        pop_thread = saved_pop_thread;
        pop_ply = saved_pop_ply;
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
        if (operation == MOVE_GEN_GENERATE_QUIET
                && !(dut.reader.cache_valid[cmd_thread]
                    && dut.reader.cache_ply[cmd_thread] == cmd_ply
                    && dut.reader.cache_state[cmd_thread].phase
                        == MOVE_MEMORY_WAIT_QUIET))
            prepare_quiet_phase();
        cmd = operation;
        while (!cmd_ready) tick();
        cmd_board = tracked_board;
        cmd_suppress_valid = suppress_valid;
        cmd_suppress_move = suppress_move;
        cmd_valid = 1'b1;
        tick();
        cmd_valid = 1'b0;
        if (operation == MOVE_GEN_GENERATE_QUIET) begin
            while (!quiet_resp_valid) tick();
            direct_valid = 1'b0;
            direct_move = NULL_MOVE;
            tops_out = tops_in;
            tops_out[0] = MoveBucketTop'(1);
        end else begin
            while (!cmd_resp_valid) tick();
            direct_valid = cmd_resp_direct_valid;
            direct_move = cmd_resp_direct_move;
            tops_out = tops_in;
            if (operation == MOVE_GEN_GENERATE_NOISY)
                tops_out[0] = MoveBucketTop'(1);
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
        pop_valid = 1'b1;
        tick();
        pop_valid = 1'b0;
        check(!pop_resp_valid, "pop selection precedes the RAM response");
        tick();
        while (!pop_resp_valid) tick();
        check(pop_resp_valid, "pop response follows synchronous pointer and move reads");
        found = pop_resp_found;
        move = pop_resp_move;
        bucket = pop_resp_bucket;
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
                if ((eligible & BAD_NOISY_BUCKET_MASK) != MoveBucketMask'(0)
                        && dut.reader.cache_state[pop_thread].phase
                            == MOVE_MEMORY_WAIT_QUIET) begin
                    bad_noisy_enable = 1'b1;
                    tick();
                    bad_noisy_enable = 1'b0;
                    continue;
                end
                if ((eligible & BAD_NOISY_BUCKET_MASK) != MoveBucketMask'(0)
                        && dut.reader.cache_state[pop_thread].phase
                            == MOVE_MEMORY_BAD_NOISY)
                    continue;
                check(!duplicate_seen, "bucket collection returns each move once");
                return;
            end
            duplicate_seen |= seen[14'(move)];
            seen[14'(move)] = 1'b1;
            count++;
        end
        check(1'b0, "bucket collection terminated");
    endtask

    // Drain the internally owned FIFO state after both generation classes.
    task automatic collect_streaming(inout MoveBucketTops tops,
        output logic [16383:0] seen);
        automatic int count;
        collect(ALL_BUCKET_MASK, tops, MoveBucketTops'(0), count, seen);
    endtask

    // Compare early destructive reads with a completed-generation reference set.
    task automatic collect_while_generating(input MoveGenCommand operation,
        input FullBoard board, input logic [16383:0] expected_seen);
        automatic logic [16383:0] seen = '0;
        automatic bit generation_done = 0;
        automatic bit outstanding = 0;
        automatic bit duplicate = 0;
        automatic bit early_response = 0;
        if (operation == MOVE_GEN_GENERATE_QUIET)
            prepare_quiet_phase();
        cmd = operation;
        cmd_board = board;
        while (!cmd_ready) tick();
        cmd_valid = 1;
        tick();
        cmd_valid = 0;
        for (int cycle = 0; cycle < 5000; cycle++) begin
            pop_valid = !outstanding;
            #1;
            if (pop_valid && pop_ready) outstanding = 1;
            tick();
            if (pop_resp_valid) begin
                outstanding = 0;
                if (pop_resp_found) begin
                    duplicate |= seen[14'(pop_resp_move)];
                    seen[14'(pop_resp_move)] = 1;
                    early_response |= !generation_done && !cmd_resp_valid && !quiet_resp_valid;
                end else begin
                    pop_valid = 0;
                    check(generation_done, "early reader reports exhaustion only after completion");
                    if (dut.reader.cache_state[pop_thread].phase
                            == MOVE_MEMORY_WAIT_QUIET) begin
                        bad_noisy_enable = 1'b1;
                        tick();
                        bad_noisy_enable = 1'b0;
                        continue;
                    end
                    if (dut.reader.cache_state[pop_thread].phase
                            == MOVE_MEMORY_BAD_NOISY)
                        continue;
                    check(!duplicate && seen === expected_seen,
                        "early reads and generation writeback preserve every move exactly once");
                    if (operation == MOVE_GEN_GENERATE_NOISY)
                        check(early_response, "generator serves a top-bucket move before completion");
                    tick();
                    return;
                end
            end
            // Completion is authoritative over older pop pointer snapshots.
            if (cmd_resp_valid || quiet_resp_valid) begin
                generation_done = 1;
            end
        end
        $fatal(1, "early generation collection timeout");
    endtask

    // Independent source-centric oracle: walk board coordinates rather than
    // reusing the DUT's destination rays, masks, or shift helpers.
    function automatic logic reference_move(input FullBoard board, input int src, input int dst);
        automatic Tile piece = board.tiles[src];
        automatic Tile victim = board.tiles[dst];
        automatic int dr = dst / 8 - src / 8;
        automatic int df = dst % 8 - src % 8;
        automatic int ar = dr < 0 ? -dr : dr;
        automatic int af = df < 0 ? -df : df;
        automatic int forward_rank = board.turn == WHITE ? 1 : -1;
        automatic int step_rank = dr == 0 ? 0 : dr > 0 ? 1 : -1;
        automatic int step_file = df == 0 ? 0 : df > 0 ? 1 : -1;
        automatic int distance = ar > af ? ar : af;
        automatic bit geometry;
        if (src == dst || piece.piece_type == NULL_PIECE
                || piece.piece_color != board.turn || victim.piece_type == KING
                || (victim.piece_type != NULL_PIECE && victim.piece_color == board.turn))
            return 1'b0;
        case (piece.piece_type)
            PAWN: begin
                if (df == 0 && victim.piece_type == NULL_PIECE)
                    return dr == forward_rank
                        || (dr == 2 * forward_rank
                            && src / 8 == (board.turn == WHITE ? 1 : 6)
                            && board.tiles[src + 8 * forward_rank].piece_type == NULL_PIECE);
                return ar == 1 && af == 1 && dr == forward_rank
                    && (victim.piece_type != NULL_PIECE
                        || (board.has_ep && dst % 8 == int'(board.ep_file)
                            && dst / 8 == (board.turn == WHITE ? 5 : 2)));
            end
            KNIGHT: return (ar == 1 && af == 2) || (ar == 2 && af == 1);
            KING: return ar <= 1 && af <= 1;
            BISHOP: geometry = ar == af;
            ROOK: geometry = ar == 0 || af == 0;
            QUEEN: geometry = ar == af || ar == 0 || af == 0;
            default: return 1'b0;
        endcase
        if (!geometry) return 1'b0;
        for (int step = 1; step < distance; step++)
            if (board.tiles[(src / 8 + step * step_rank) * 8
                    + src % 8 + step * step_file].piece_type != NULL_PIECE)
                return 1'b0;
        return 1'b1;
    endfunction

    // Compare complete move sets, including all promotion encodings and class
    // separation. These fixtures have no castling rights (tested separately).
    task automatic check_reference_sets(input FullBoard board);
        automatic MoveBucketTops tops;
        automatic logic direct_valid;
        automatic Move direct_move;
        automatic logic [16383:0] expected;
        automatic logic [16383:0] seen;
        automatic int count;
        for (int phase = 0; phase < 2; phase++) begin
            expected = '0;
            for (int src = 0; src < 64; src++) begin
                for (int dst = 0; dst < 64; dst++) begin
                    if (reference_move(board, src, dst)) begin
                        automatic bit promotion = board.tiles[src].piece_type == PAWN
                            && (dst / 8 == 0 || dst / 8 == 7);
                        automatic bit capture = board.tiles[dst].piece_type != NULL_PIECE
                            || (board.tiles[src].piece_type == PAWN && src % 8 != dst % 8);
                        if ((phase == 0) == (promotion || capture))
                            for (int promo = 0; promo < (promotion ? 4 : 1); promo++)
                                expected[14'(make_move(Position'(src), Position'(dst), PromoType'(promo)))] = 1'b1;
                    end
                end
            end
            tops = '0;
            run_command(phase == 0 ? MOVE_GEN_GENERATE_NOISY : MOVE_GEN_GENERATE_QUIET,
                board, 1'b0, NULL_MOVE, tops, direct_valid, direct_move, tops);
            collect(ALL_BUCKET_MASK, tops, MoveBucketTops'(0), count, seen);
            check(seen === expected, $sformatf("reference move set color=%0d phase=%0d", board.turn, phase));
        end
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
        while (dut.quiet_history.state != 0) tick();
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
        while (dut.quiet_history.state != 0) tick();
    endtask

    task automatic launch_history_update_with_failures(
        input Move winner,
        input Move failed0,
        input Move failed1,
        input Move failed2,
        input logic [1:0] failed_count,
        input logic [5:0] depth
    );
        while (dut.quiet_history.state != 0) tick();
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
        monitor_promotion_writes = 1'b0;
        promotion_write_count = 0;
        idle_inputs();
        tick(2);
        rst_n = 1'b1;
        while (init_busy) tick();

        start_board(board);
        cmd_thread = ThreadID'(1);
        prepare_quiet_phase();
        cmd_thread = ThreadID'(0);
        concurrent_response_seen[0] = 1'b0;
        concurrent_response_seen[1] = 1'b0;
        cmd = MOVE_GEN_GENERATE_NOISY;
        cmd_thread = ThreadID'(0);
        cmd_board = board;
        cmd_valid = 1'b1;
        check(cmd_ready, "noisy pipeline accepts first concurrent job");
        tick();
        cmd = MOVE_GEN_GENERATE_QUIET;
        #1;
        check(!quiet_cmd_ready, "same-thread generation waits for its reserved write port");
        cmd_thread = ThreadID'(1);
        #1;
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
        clear = 1'b1;
        tick();
        clear = 1'b0;
        tick();
        cmd_thread = ThreadID'(0);

        tops = '0;
        lower = '0;
        generation_cycles_before = stat_generation_cycles;
        run_command(MOVE_GEN_GENERATE_NOISY, board, 1'b0, NULL_MOVE,
            tops, direct_valid, direct_move, tops);
        $display("Start-position noisy generation cycles: %0d",
            stat_generation_cycles - generation_cycles_before);
        collect(ALL_BUCKET_MASK, tops, lower, count, seen);
        check(count == 0, "start position has no noisy moves");

        // Center-out destination priority and FIFO storage return central
        // moves before later edge destinations in both generator lanes.
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
            "noisy FIFO returns central destination before edge destination");

        empty_board(board);
        board.tiles[10] = WHITE_KNIGHT;
        board.tiles[56] = WHITE_KING;
        board.tiles[63] = BLACK_KING;
        tops = '0;
        run_command(MOVE_GEN_GENERATE_QUIET, board, 1'b0, NULL_MOVE,
            tops, direct_valid, direct_move, tops);
        pop_one(QUIET_BUCKET_MASK, tops, lower, found, popped, popped_bucket);
        check(found && same_move(popped, make_move(Position'(10), Position'(27))),
            "quiet FIFO returns central destination before edge destination");

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
        promotion_write_count = 0;
        monitor_promotion_writes = 1'b1;
        run_command(MOVE_GEN_GENERATE_NOISY, board, 1'b0, NULL_MOVE,
            tops, direct_valid, direct_move, tops);
        monitor_promotion_writes = 1'b0;
        check(promotion_write_count == 4, "four promotion writes observed");
        check(promotion_write_order[0] == PROMO_QUEEN,
            "queen promotion generated first");
        check(promotion_write_order[1] == PROMO_KNIGHT,
            "knight promotion generated second");
        check(promotion_write_order[2] == PROMO_ROOK,
            "rook promotion generated third");
        check(promotion_write_order[3] == PROMO_BISHOP,
            "bishop promotion generated fourth");
        pop_one(ALL_BUCKET_MASK, tops, lower, found, popped, popped_bucket);
        check(found && popped.promo_piece == PROMO_QUEEN,
            "promotion FIFO reads queen first");
        pop_one(ALL_BUCKET_MASK, tops, lower, found, popped, popped_bucket);
        check(found && popped.promo_piece == PROMO_KNIGHT,
            "promotion FIFO reads knight second");
        pop_one(ALL_BUCKET_MASK, tops, lower, found, popped, popped_bucket);
        check(found && popped.promo_piece == PROMO_ROOK,
            "promotion FIFO reads rook third");
        pop_one(ALL_BUCKET_MASK, tops, lower, found, popped, popped_bucket);
        check(found && popped.promo_piece == PROMO_BISHOP,
            "promotion FIFO reads bishop fourth");

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
        board.castling_rights.white_kingside = 1'b1;
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
        check($signed(dut.quiet_history.history_table.history_ram.mem[
                dut.quiet_history.history_hash(ThreadID'(0), WHITE,
                    target.from_pos, target.to_pos)]) == 8'sd119,
            "history gravity reduces bonuses as history approaches its limit");
        failed0 = make_move(Position'(1), Position'(16));
        failed1 = make_move(Position'(1), Position'(11));
        failed2 = make_move(Position'(4), Position'(5));
        history_update_with_failures(target, failed0, failed1, failed2, 2'd3, 6'd4);
        check($signed(dut.quiet_history.history_table.history_ram.mem[
                dut.quiet_history.history_hash(ThreadID'(0), WHITE,
                    failed0.from_pos, failed0.to_pos)]) == -8'sd4,
            "failed quiet zero history receives half-strength malus");
        check($signed(dut.quiet_history.history_table.history_ram.mem[
                dut.quiet_history.history_hash(ThreadID'(0), WHITE,
                    failed1.from_pos, failed1.to_pos)]) == -8'sd4,
            "second failed quiet receives a malus");
        check($signed(dut.quiet_history.history_table.history_ram.mem[
                dut.quiet_history.history_hash(ThreadID'(0), WHITE,
                    failed2.from_pos, failed2.to_pos)]) == -8'sd4,
            "third failed quiet receives a malus");

        history_update_thread = ThreadID'(1);
        history_update(target, 6'd1);
        check($signed(dut.quiet_history.history_table.history_ram.mem[
                dut.quiet_history.history_hash(ThreadID'(1), WHITE,
                    target.from_pos, target.to_pos)]) == 8'sd2,
            "thread participates in the combined history hash");
        check($signed(dut.quiet_history.history_table.history_ram.mem[
                dut.quiet_history.history_hash(ThreadID'(0), WHITE,
                    target.from_pos, target.to_pos)]) == 8'sd120,
            "thread-local update leaves the other hashed entry unchanged");

        // A second update presented while the private update pipeline is busy
        // is acknowledged and dropped rather than backpressuring search.
        history_update_thread = ThreadID'(0);
        launch_history_update_with_failures(
            make_move(Position'(2), Position'(10)),
            NULL_MOVE, NULL_MOVE, NULL_MOVE, 2'd0, 6'd1
        );
        history_update_from = Position'(3);
        history_update_to = Position'(11);
        history_update_valid = 1'b1;
        tick();
        history_update_valid = 1'b0;
        while (dut.quiet_history.state != 0) tick();
        check($signed(dut.quiet_history.history_table.history_ram.mem[
                dut.quiet_history.history_hash(ThreadID'(0), WHITE,
                    Position'(3), Position'(11))]) == 8'sd0,
            "busy history pipeline drops a new update without backpressure");

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
        cmd_ply = PlyIndex'(0);
        pop_ply = PlyIndex'(0);
        run_command(MOVE_GEN_GENERATE_NOISY, board, 1'b0, NULL_MOVE,
            parent_tops, direct_valid, direct_move, parent_tops);
        run_command(MOVE_GEN_GENERATE_QUIET, board, 1'b0, NULL_MOVE,
            parent_tops, direct_valid, direct_move, parent_tops);
        pop_one(ALL_BUCKET_MASK, parent_tops, lower, found, popped, popped_bucket);
        check(found, "parent move popped before descent");
        child_tops = parent_tops;
        empty_board(board);
        board.tiles[0] = WHITE_KING;
        board.tiles[1] = WHITE_KNIGHT;
        board.tiles[63] = BLACK_KING;
        cmd_ply = PlyIndex'(1);
        pop_ply = PlyIndex'(1);
        run_command(MOVE_GEN_GENERATE_NOISY, board, 1'b0, NULL_MOVE,
            child_tops, direct_valid, direct_move, child_tops);
        run_command(MOVE_GEN_GENERATE_QUIET, board, 1'b0, NULL_MOVE,
            child_tops, direct_valid, direct_move, child_tops);
        collect(ALL_BUCKET_MASK, child_tops, parent_tops, count, seen);
        check(count != 0, "child pushes and pops above inherited lower bounds");
        tops = parent_tops;
        pop_ply = PlyIndex'(0);
        collect(ALL_BUCKET_MASK, tops, lower, count, seen);
        check(count == 19, "return preserves all unsearched parent moves");
        child_tops = parent_tops;
        cmd_ply = PlyIndex'(1);
        pop_ply = PlyIndex'(1);
        run_command(MOVE_GEN_GENERATE_NOISY, board, 1'b0, NULL_MOVE,
            child_tops, direct_valid, direct_move, child_tops);
        run_command(MOVE_GEN_GENERATE_QUIET, board, 1'b0, NULL_MOVE,
            child_tops, direct_valid, direct_move, child_tops);
        collect(ALL_BUCKET_MASK, child_tops, parent_tops, count, seen);
        check(count != 0, "sibling allocates and drains its own descendant range");
        cmd_ply = PlyIndex'(0);
        pop_ply = PlyIndex'(0);

        // Exercise blocked and open rays, board edges, knight wraparound,
        // double pushes, en passant, and capture/quiet promotions in both colors.
        for (int fixture = 0; fixture < 3; fixture++) begin
            if (fixture == 0) begin
                start_board(board);
                board.castling_rights = CastlingRights'(0);
            end else begin
                empty_board(board);
                board.tiles[4] = WHITE_KING;
                board.tiles[60] = BLACK_KING;
                board.tiles[0] = WHITE_ROOK;
                board.tiles[7] = WHITE_KNIGHT;
                board.tiles[18] = WHITE_BISHOP;
                board.tiles[27] = WHITE_QUEEN;
                board.tiles[12] = WHITE_PAWN;
                board.tiles[20] = BLACK_PAWN;
                board.tiles[35] = BLACK_BISHOP;
                board.tiles[39] = BLACK_ROOK;
                board.tiles[50] = BLACK_KNIGHT;
                if (fixture == 2) begin
                    board.tiles[48] = WHITE_PAWN;
                    board.tiles[57] = BLACK_ROOK;
                    board.tiles[37] = WHITE_PAWN;
                    board.tiles[38] = BLACK_PAWN;
                    board.has_ep = 1'b1;
                    board.ep_file = BoardFile'(6);
                end
            end
            check_reference_sets(board);
            begin
                automatic FullBoard mirrored = board;
                for (int pos = 0; pos < 64; pos++) begin
                    mirrored.tiles[pos ^ 56] = board.tiles[pos];
                    if (board.tiles[pos].piece_type != NULL_PIECE)
                        mirrored.tiles[pos ^ 56].piece_color = Color'(!board.tiles[pos].piece_color);
                end
                mirrored.turn = BLACK;
                check_reference_sets(mirrored);
            end
        end

        // Mix both lanes, then compare a continuous pop stream with ordinary
        // single-request draining of the same generated candidates.
        empty_board(board);
        board.tiles[4] = WHITE_KING;
        board.tiles[60] = BLACK_KING;
        board.tiles[10] = WHITE_KNIGHT;
        board.tiles[27] = BLACK_PAWN;
        board.tiles[0] = BLACK_PAWN;
        tops = '0;
        run_command(MOVE_GEN_GENERATE_NOISY, board, 1'b0, NULL_MOVE,
            tops, direct_valid, direct_move, tops);
        run_command(MOVE_GEN_GENERATE_QUIET, board, 1'b0, NULL_MOVE,
            tops, direct_valid, direct_move, tops);
        collect(ALL_BUCKET_MASK, tops, lower, count, seen);
        begin
            automatic logic [16383:0] streaming_seen;
            run_command(MOVE_GEN_GENERATE_NOISY, board, 1'b0, NULL_MOVE,
                tops, direct_valid, direct_move, tops);
            run_command(MOVE_GEN_GENERATE_QUIET, board, 1'b0, NULL_MOVE,
                tops, direct_valid, direct_move, tops);
            collect_streaming(tops, streaming_seen);
            check(streaming_seen === seen,
                "continuous cross-lane pops preserve the complete move set");
        end
        // Promotions populate the highest bucket early; lower captures and
        // quiets exercise the generation-completion barrier with real lanes.
        empty_board(board);
        board.tiles[4] = WHITE_KING;
        board.tiles[60] = BLACK_KING;
        board.tiles[48] = WHITE_PAWN;
        board.tiles[57] = BLACK_ROOK;
        board.tiles[27] = WHITE_QUEEN;
        board.tiles[35] = BLACK_PAWN;
        for (int lane = 0; lane < 2; lane++) begin
            tops = '0;
            run_command(lane == 0 ? MOVE_GEN_GENERATE_NOISY : MOVE_GEN_GENERATE_QUIET,
                board, 1'b0, NULL_MOVE, tops, direct_valid, direct_move, tops);
            collect(ALL_BUCKET_MASK, tops, lower, count, seen);
            collect_while_generating(lane == 0 ? MOVE_GEN_GENERATE_NOISY : MOVE_GEN_GENERATE_QUIET,
                board, seen);
        end
        // Cancel an accepted request between selection and the RAM access.
        pop_valid = 1'b1;
        tick();
        pop_valid = 1'b0;
        check(!pop_resp_valid, "accepted pop is still in selection stage");
        flush = 1'b1;
        #1;
        check(!pop_ready, "flush prevents accepting a discarded pop");
        tick();
        check(!pop_resp_valid, "flush cancels the pending RAM access");
        flush = 1'b0;
        tick();
        check(!pop_resp_valid, "flushed pop produces no late response");

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
        for (int fill = 0; fill < 16 && !overflow_sticky; fill++) begin
            cmd_ply = PlyIndex'(fill);
            run_command(MOVE_GEN_GENERATE_QUIET, board, 1'b0, NULL_MOVE,
                tops, direct_valid, direct_move, tops);
        end
        check(overflow_sticky, "overflow sets the sticky error bit");
        check(dut.reader.cache_state[0].tops[QUIET_LOW_BUCKET]
                > MoveBucketTop'(192),
            "overflow does not clamp the move-memory tail");
        check(stat_bucket_high_water[QUIET_LOW_BUCKET] > MoveBucketTop'(192),
            "high-water telemetry includes overflowing writes");
        cmd_ply = PlyIndex'(0);

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
