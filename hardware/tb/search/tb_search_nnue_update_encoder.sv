`timescale 1ns/1ps

import chess_defs::*;
import nnue_defs::*;
import search_defs::*;

module tb_search_nnue_update_encoder;
    ThreadID thread_id;
    SearchNnuePlan plan;
    logic [2:0] step;
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
    task automatic check_move(
        input Color color, input int scenario,
        input PromoType promotion, input PieceType promoted_piece
    );
        FullBoard before_board, after_board;
        SearchNnueUndo undo_record;
        Move entering_move;
        PlyIndex parent_ply;
        int expected[NNUE_SIDE_COUNT][NNUE_FEATURE_COUNT];
        int observed[NNUE_SIDE_COUNT][NNUE_FEATURE_COUNT];
        int request_count;
        int bank_reads[2][3];
        logic protocol_ok, features_ok;
        Position rank_flip;
        Position rook_from, rook_to;
        string label;

        label = $sformatf("color=%0d scenario=%0d promotion=%0d", color, scenario, promotion);
        rank_flip = color == WHITE ? Position'(0) : Position'(56);
        before_board = FullBoard'('0);
        before_board.tiles[4] = WHITE_KING;
        before_board.tiles[60] = BLACK_KING;
        plan = SearchNnuePlan'('0);
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
                plan.placed = Tile'({color, promoted_piece});
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
        entering_move = Move'({plan.from_pos, plan.to_pos, promotion});
        parent_ply = plan.child_ply;
        undo_record.mover = plan.mover.piece_type;
        undo_record.capture_kind = scenario == 2 ? NNUE_CAPTURE_EP
            : plan.capture_valid ? plan.capture.piece_type : NULL_PIECE;
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
            // Undo uses only the compact record; expected features still come
            // from independently constructed before/after boards above.
            if (undo)
                plan = nnue_undo_plan(entering_move, undo_record, color, parent_ply);
            foreach (bank_reads[side, bank]) bank_reads[side][bank] = 0;
            for (int index = 0; index < request_count; index++) begin
                step = 3'(index);
                #1;
                protocol_ok &= req_valid && req.apply && req.combine
                    && req.complete == (index == request_count - 1)
                    && req.thread_id == thread_id && req.ply == plan.child_ply;
                bank_reads[WHITE][nnue_feature_bank(req.white_feature)]++;
                bank_reads[BLACK][nnue_feature_bank(req.black_feature)]++;
                observed[WHITE][req.white_feature] += req.add ? 1 : -1;
                observed[BLACK][req.black_feature] += req.add ? 1 : -1;
            end
            foreach (bank_reads[side, bank])
                check(bank_reads[side][bank] <= 2, "move/undo fits two read ports per bank");
            features_ok = 1'b1;
            foreach (expected[side, feature])
                features_ok &= observed[side][feature] == (undo ? 0 : expected[side][feature]);
            check(features_ok, {label, undo ? " inverse restores parent" : " child feature delta"});
        end
        check(protocol_ok, {label, " request tags and completion"});

        // Null moves preserve both perspectives while assigning a child slot.
        plan = '0;
        plan.child_ply = parent_ply;
        plan.copy = 1'b1;
        #1;
        check(req_valid && req.apply && req.copy && req.complete && !req.combine
            && req.thread_id == thread_id && req.ply == parent_ply,
            {label, " null move requests a complete zero-delta copy"});
    endtask

    // Prove every reachable feature has a unique stored address and every
    // unreachable pawn row selects the reserved zero vector.
    task automatic check_bank_layout();
        bit seen[3][NNUE_FEATURE_BANK_ROW_COUNT];
        bit unique_rows = 1, zero_rows = 1, captures_fit = 1;
        foreach (seen[bank,row]) seen[bank][row] = 0;
        for (int feature = 0; feature < NNUE_FEATURE_COUNT; feature++) begin
            automatic int bank = nnue_feature_bank(NnueFeatureIndex'(feature));
            automatic int row = nnue_feature_bank_row(NnueFeatureIndex'(feature));
            automatic bit unused = (feature/64 == 0 || feature/64 == 6)
                && (feature%64 < 8 || feature%64 >= 56);
            if (unused) zero_rows &= row == NNUE_ZERO_FEATURE_ROW;
            else begin
                unique_rows &= row != NNUE_ZERO_FEATURE_ROW && !seen[bank][row];
                seen[bank][row] = 1;
            end
        end
        // The bank depends only on square and color, so one piece type covers
        // every capture, including promotions and king steps, without geometry assumptions.
        for (int side = 0; side < 2; side++)
            for (int color = 0; color < 2; color++)
                for (int source = 0; source < 64; source++)
                    for (int target = 0; target < 64; target++) begin
                        automatic int a = nnue_feature_bank(nnue_feature_index(Position'(source), Tile'({Color'(color), KNIGHT}), Color'(side)));
                        automatic int b = nnue_feature_bank(nnue_feature_index(Position'(target), Tile'({Color'(color), KNIGHT}), Color'(side)));
                        automatic int c = nnue_feature_bank(nnue_feature_index(Position'(target), Tile'({Color'(!color), ROOK}), Color'(side)));
                        captures_fit &= !(a == b && b == c);
                    end
        for (int side = 0; side < 2; side++)
            for (int color = 0; color < 2; color++)
                for (int file_index = 0; file_index < 8; file_index++)
                    for (int direction = -1; direction <= 1; direction += 2)
                        if (file_index + direction >= 0 && file_index + direction < 8) begin
                            automatic int rank_index = color == int'(WHITE) ? 4 : 3;
                            automatic Position source = Position'(rank_index*8 + file_index);
                            automatic Position target = Position'((rank_index + (color == int'(WHITE) ? 1 : -1))*8 + file_index + direction);
                            automatic Position victim = Position'(rank_index*8 + file_index + direction);
                            automatic int a = nnue_feature_bank(nnue_feature_index(source, Tile'({Color'(color), PAWN}), Color'(side)));
                            automatic int b = nnue_feature_bank(nnue_feature_index(target, Tile'({Color'(color), PAWN}), Color'(side)));
                            automatic int c = nnue_feature_bank(nnue_feature_index(victim, Tile'({Color'(!color), PAWN}), Color'(side)));
                            captures_fit &= !(a == b && b == c);
                        end
        check(unique_rows, "reachable features have distinct nonzero bank rows");
        check(zero_rows, "unused pawn rows select the reserved zero vector");
        check(captures_fit, "all capture square pairs fit the bank ports");
    endtask

    initial begin
        PieceType promotion_pieces[4] = '{QUEEN, KNIGHT, ROOK, BISHOP};
        check_bank_layout();
        thread_id = ThreadID'(THREAD_COUNT - 1);
        step = '0;
        for (int color = 0; color < NNUE_SIDE_COUNT; color++)
            for (int scenario = 0; scenario < 7; scenario++)
                for (int promotion = 0; promotion < 4; promotion++)
                    if (promotion == 0 || scenario == 3 || scenario == 4)
                        check_move(Color'(color), scenario,
                            PromoType'(promotion), promotion_pieces[promotion]);
        $display("Pass Count: %0d", pass_count);
        $display("Fail Count: %0d", fail_count);
        if (fail_count != 0) $fatal(1, "NNUE update encoder failed");
        $finish;
    end

    // Bound every directed scenario so simulator failures cannot hang the runner.
    initial begin
        #10000;
        $fatal(1, "NNUE update encoder test timed out");
    end
endmodule
