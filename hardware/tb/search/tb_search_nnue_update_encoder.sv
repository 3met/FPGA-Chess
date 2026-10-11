`timescale 1ns/1ps

import chess_defs::*;
import nnue_defs::*;
import search_defs::*;

module tb_search_nnue_update_encoder;
    ThreadID thread_id;
    SearchNnuePlan plan;
    logic [2:0] step;
    logic draining, first;
    Position replay_pos;
    Tile replay_tile;
    logic req_valid;
    NnueUpdateRequest req;
    int pass_count = 0;
    int fail_count = 0;

    search_nnue_update_encoder dut (.*);

    // Summarize each invariant once instead of reporting every feature separately.
    task automatic check(input logic condition, input string description);
        if (condition) pass_count++;
        else begin
            fail_count++;
            $display("FAIL: %s", description);
        end
    endtask

    // Compare physical requests against the feature difference between two boards.
    // This checks chess semantics without depending on the encoder's request order.
    task automatic check_move(input Color color, input int scenario);
        FullBoard before_board, after_board;
        int expected[NNUE_SIDE_COUNT][NNUE_FEATURE_COUNT];
        int observed[NNUE_SIDE_COUNT][NNUE_FEATURE_COUNT];
        int request_count;
        logic protocol_ok, features_ok;
        Position rank_flip;
        Position rook_from, rook_to;
        string label;

        label = $sformatf("color=%0d scenario=%0d", color, scenario);
        rank_flip = color == WHITE ? Position'(0) : Position'(56);
        before_board = FullBoard'('0);
        before_board.tiles[4] = WHITE_KING;
        before_board.tiles[60] = BLACK_KING;
        plan = SearchNnuePlan'('0);
        plan.kind = NNUE_PLAN_DELTA;
        plan.child_ply = PlyIndex'(3);
        plan.real_move = 1'b1;
        plan.from_pos = Position'(1) ^ rank_flip;
        plan.to_pos = Position'(18) ^ rank_flip;
        plan.mover = Tile'({color, KNIGHT});
        plan.placed = plan.mover;
        plan.capture = Tile'({Color'(!color), BISHOP});
        request_count = 2;

        // Fixtures cover quiet moves, captures, en passant, promotions, and both castles.
        case (scenario)
            1: begin
                plan.capture_valid = 1'b1;
                request_count = 3;
            end
            2: begin
                plan.from_pos = Position'(36) ^ rank_flip;
                plan.to_pos = Position'(43) ^ rank_flip;
                plan.capture_pos = Position'(35) ^ rank_flip;
                plan.mover = Tile'({color, PAWN});
                plan.placed = plan.mover;
                plan.capture = Tile'({Color'(!color), PAWN});
                plan.capture_valid = 1'b1;
                request_count = 3;
            end
            3, 4: begin
                plan.from_pos = Position'(48) ^ rank_flip;
                plan.to_pos = Position'(scenario == 3 ? 56 : 57) ^ rank_flip;
                plan.mover = Tile'({color, PAWN});
                plan.placed = Tile'({color, QUEEN});
                plan.capture = Tile'({Color'(!color), ROOK});
                plan.capture_valid = scenario == 4;
                request_count = scenario == 4 ? 3 : 2;
            end
            5, 6: begin
                plan.from_pos = Position'(4) ^ rank_flip;
                plan.to_pos = Position'(scenario == 5 ? 2 : 6) ^ rank_flip;
                plan.mover = Tile'({color, KING});
                plan.placed = plan.mover;
                rook_from = Position'(scenario == 5 ? 0 : 7) ^ rank_flip;
                rook_to = Position'(scenario == 5 ? 3 : 5) ^ rank_flip;
                before_board.tiles[rook_from] = Tile'({color, ROOK});
                request_count = 4;
            end
            default: begin end
        endcase
        if (scenario != 2) plan.capture_pos = plan.to_pos;
        before_board.tiles[plan.from_pos] = plan.mover;
        if (plan.capture_valid) before_board.tiles[plan.capture_pos] = plan.capture;
        after_board = before_board;
        after_board.tiles[plan.from_pos] = EMPTY_TILE;
        if (plan.capture_valid) after_board.tiles[plan.capture_pos] = EMPTY_TILE;
        after_board.tiles[plan.to_pos] = plan.placed;
        if (scenario >= 5) begin
            after_board.tiles[rook_from] = EMPTY_TILE;
            after_board.tiles[rook_to] = Tile'({color, ROOK});
        end
        foreach (expected[side, feature]) begin
            expected[side][feature] = 0;
            observed[side][feature] = 0;
        end
        for (int side = 0; side < NNUE_SIDE_COUNT; side++) begin
            for (int square = 0; square < 64; square++) begin
                if (before_board.tiles[square].piece_type != NULL_PIECE)
                    expected[side][nnue_feature_index(Position'(square),
                        before_board.tiles[square], Color'(side))]--;
                if (after_board.tiles[square].piece_type != NULL_PIECE)
                    expected[side][nnue_feature_index(Position'(square),
                        after_board.tiles[square], Color'(side))]++;
            end
        end
        protocol_ok = 1'b1;
        for (int undo = 0; undo < 2; undo++) begin
            plan.reverse = 1'(undo);
            for (int index = 0; index < request_count; index++) begin
                step = 3'(index);
                #1;
                protocol_ok &= req_valid && req.apply && !req.clear
                    && req.complete == (index == request_count - 1)
                    && req.thread_id == thread_id && req.ply == plan.child_ply;
                observed[WHITE][req.white_feature] += req.add ? 1 : -1;
                observed[BLACK][req.black_feature] += req.add ? 1 : -1;
            end
            features_ok = 1'b1;
            foreach (expected[side, feature])
                features_ok &= observed[side][feature] == (undo ? 0 : expected[side][feature]);
            check(features_ok, {label, undo ? " inverse restores parent" : " child feature delta"});
        end
        check(protocol_ok, {label, " request tags and completion"});

        // Rebuild adds the whole board, clears on its first piece, then emits a marker.
        plan.kind = NNUE_PLAN_REBUILD;
        first = 1'b1;
        protocol_ok = 1'b1;
        for (int square = 0; square < 64; square++) begin
            replay_pos = Position'(square);
            replay_tile = after_board.tiles[square];
            #1;
            if (replay_tile.piece_type == NULL_PIECE) protocol_ok &= !req_valid;
            else begin
                protocol_ok &= req_valid && req.apply && req.add && !req.complete
                    && req.clear == first && req.thread_id == thread_id
                    && req.ply == plan.child_ply
                    && req.white_feature == nnue_feature_index(replay_pos, replay_tile, WHITE)
                    && req.black_feature == nnue_feature_index(replay_pos, replay_tile, BLACK);
                first = 1'b0;
            end
        end
        draining = 1'b1;
        #1;
        protocol_ok &= req_valid && !req.apply && req.complete && !req.clear
            && req.thread_id == thread_id && req.ply == plan.child_ply;
        check(protocol_ok, {label, " rebuild and ordered marker"});
        draining = 1'b0;
    endtask

    initial begin
        thread_id = ThreadID'(THREAD_COUNT - 1);
        step = '0;
        draining = 1'b0;
        first = 1'b0;
        replay_pos = '0;
        replay_tile = EMPTY_TILE;
        for (int color = 0; color < NNUE_SIDE_COUNT; color++)
            for (int scenario = 0; scenario < 7; scenario++)
                check_move(Color'(color), scenario);
        $display("Pass Count: %0d", pass_count);
        $display("Fail Count: %0d", fail_count);
        $finish;
    end

    // Bound every directed scenario so simulator failures cannot hang the runner.
    initial begin
        #10000;
        $fatal(1, "NNUE update encoder test timed out");
    end
endmodule
