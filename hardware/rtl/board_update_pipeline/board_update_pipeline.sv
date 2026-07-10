// By Emet Behrendt

import general_chess_defs::*;
import chess_helper_funcs::*;
import board_update_pipeline_defs::*;
import zobrist_defs::*;

module board_update_pipeline #(
    parameter int MOVE_RECORD_THREAD_COUNT = THREAD_COUNT,
    parameter int MOVE_RECORD_PLY_COUNT = MAX_PLY_COUNT,
    parameter bit ENABLE_ZOBRIST = 1'b1,
    parameter bit ENABLE_PST = 1'b1
) (
    input wire clk,
    input BoardOp board_op,
    input FullBoard board_in,
    input ZobristKey zobrist_key_in,
    input EvalScore pst_eval_in,
    input Move move_in,
    input logic [6:0] set_data,
    input ThreadID thread_id,
    input PlyIndex search_ply,

    output FullBoard board_out,
    output ZobristKey zobrist_key_out,
    output EvalScore pst_eval_out
);

    typedef logic [8:0] PstAddr;
    typedef logic [2:0] PstPieceIndex;
    localparam int PST_ENTRY_COUNT = 6 * 64;
    localparam PST_MEM_INIT_FILE = "hardware/data/pst_values/pst_values.hex";
    localparam int PST_READ_PORTS = 4;
    localparam int ZOBRIST_READ_PORTS = 8;

    typedef struct packed {
        logic [PST_READ_PORTS-1:0] enable;
        PstAddr [PST_READ_PORTS-1:0] address;
    } PstReadPlan;

    typedef struct packed {
        logic [ZOBRIST_READ_PORTS-1:0] enable;
        ZobristAddr [ZOBRIST_READ_PORTS-1:0] address;
    } ZobristReadPlan;

    localparam MOVE_RECORD_COUNT = MOVE_RECORD_THREAD_COUNT * MOVE_RECORD_PLY_COUNT;
    localparam MOVE_RECORD_ADDR_BITS = (MOVE_RECORD_COUNT <= 1) ? 1 : $clog2(MOVE_RECORD_COUNT);
    typedef logic [MOVE_RECORD_ADDR_BITS-1:0] MoveRecordAddr;

    BoardUpdatePipelineCtx ctx_pipe[7];
    BoardUpdatePipelineCtx next_ctx_pipe[7];

    MoveRecord move_record_in, move_record_out;
    MoveRecordAddr move_record_rd_addr, move_record_wr_addr;
    logic move_record_rd_en, move_record_wr_en;

    simple_dual_port_ram #(
        .NUM_WORDS(MOVE_RECORD_COUNT),
        .WORD_SIZE($bits(MoveRecord))
    ) move_hist_mem (
        .clock(clk),
        .data(move_record_in),
        .rdaddress(move_record_rd_addr),
        .rden(move_record_rd_en),
        .wraddress(move_record_wr_addr),
        .wren(move_record_wr_en),
        .q(move_record_out)
    );

    PstReadPlan pst_read_plan;
    logic [PST_READ_PORTS-1:0] pst_read_enable_q;
    EvalScore pst_read_data[PST_READ_PORTS];
    EvalScore pst_start_out, pst_end_out, pst_killed_out, pst_castle_out;
    ZobristReadPlan zobrist_read_plan;
    logic [ZOBRIST_READ_PORTS-1:0] zobrist_read_enable_q;
    ZobristKey zobrist_read_data[ZOBRIST_READ_PORTS];

    genvar port_pair;
    genvar port_idx;
    generate
        if (ENABLE_ZOBRIST) begin : gen_zobrist_roms
            for (port_pair = 0; port_pair < ZOBRIST_READ_PORTS / 2; port_pair = port_pair + 1) begin : gen_zobrist_rom
                synchronous_dual_port_rom #(
                    .NUM_WORDS(ZOBRIST_ENTRY_CNT),
                    .WORD_SIZE($bits(ZobristKey)),
                    .MEM_INIT_FILE(ZOBRIST_MEM_INIT_FILE)
                ) zobrist_rom (
                    .clock(clk),
                    .address_a(zobrist_read_plan.address[port_pair * 2]),
                    .address_b(zobrist_read_plan.address[port_pair * 2 + 1]),
                    .rden_a(zobrist_read_plan.enable[port_pair * 2]),
                    .rden_b(zobrist_read_plan.enable[port_pair * 2 + 1]),
                    .q_a(zobrist_read_data[port_pair * 2]),
                    .q_b(zobrist_read_data[port_pair * 2 + 1])
                );
            end
        end else begin : gen_no_zobrist_roms
            for (port_idx = 0; port_idx < ZOBRIST_READ_PORTS; port_idx = port_idx + 1) begin : gen_zero_zobrist
                assign zobrist_read_data[port_idx] = ZobristKey'(0);
            end
        end
    endgenerate

    generate
        if (ENABLE_PST) begin : gen_pst
            for (port_pair = 0; port_pair < PST_READ_PORTS / 2; port_pair = port_pair + 1) begin : gen_pst_rom
                synchronous_dual_port_rom #(
                    .NUM_WORDS(PST_ENTRY_COUNT),
                    .WORD_SIZE($bits(EvalScore)),
                    .MEM_INIT_FILE(PST_MEM_INIT_FILE)
                ) pst_rom (
                    .clock(clk),
                    .address_a(pst_read_plan.address[port_pair * 2]),
                    .address_b(pst_read_plan.address[port_pair * 2 + 1]),
                    .rden_a(pst_read_plan.enable[port_pair * 2]),
                    .rden_b(pst_read_plan.enable[port_pair * 2 + 1]),
                    .q_a(pst_read_data[port_pair * 2]),
                    .q_b(pst_read_data[port_pair * 2 + 1])
                );
            end
            assign pst_start_out = pst_read_enable_q[0] ? pst_read_data[0] : EvalScore'(0);
            assign pst_end_out = pst_read_enable_q[1] ? pst_read_data[1] : EvalScore'(0);
            assign pst_killed_out = pst_read_enable_q[2] ? pst_read_data[2] : EvalScore'(0);
            assign pst_castle_out = pst_read_enable_q[3] ? pst_read_data[3] : EvalScore'(0);
        end else begin : gen_no_pst
            assign pst_start_out = EvalScore'(0);
            assign pst_end_out = EvalScore'(0);
            assign pst_killed_out = EvalScore'(0);
            assign pst_castle_out = EvalScore'(0);
        end
    endgenerate

    assign board_out = ctx_pipe[6].board;
    assign zobrist_key_out = ctx_pipe[6].zobrist_key;
    assign pst_eval_out = ctx_pipe[6].pst_eval;

    function automatic MoveRecordAddr move_hist_addr(input ThreadID tid, input PlyIndex ply);
        return MoveRecordAddr'((int'(tid) * MOVE_RECORD_PLY_COUNT) + int'(ply));
    endfunction : move_hist_addr

    function automatic Position oriented_pos(input Tile tile, input Position pos);
        return (tile.piece_color == BLACK) ? mirrorPos(pos) : pos;
    endfunction : oriented_pos

    function automatic PstAddr pst_addr(input PieceType piece, input Position pos);
        if (piece == NULL_PIECE) begin
            return PstAddr'(0);
        end

        return {PstPieceIndex'(piece) - PstPieceIndex'(1), pos};
    endfunction : pst_addr

    function automatic PieceType promo_to_piece(input PromoType promo);
        case (promo)
            PROMO_QUEEN:  return QUEEN;
            PROMO_KNIGHT: return KNIGHT;
            PROMO_ROOK:   return ROOK;
            PROMO_BISHOP: return BISHOP;
            default:      return PieceType'('x);
        endcase
    endfunction : promo_to_piece

    function automatic Position castle_rook_from(input Position king_to);
        case (king_to)
            Position'('d2):  return Position'('d0);
            Position'('d6):  return Position'('d7);
            Position'('d58): return Position'('d56);
            Position'('d62): return Position'('d63);
            default:         return Position'('dx);
        endcase
    endfunction : castle_rook_from

    function automatic Position castle_rook_to(input Position king_to);
        case (king_to)
            Position'('d2):  return Position'('d3);
            Position'('d6):  return Position'('d5);
            Position'('d58): return Position'('d59);
            Position'('d62): return Position'('d61);
            default:         return Position'('dx);
        endcase
    endfunction : castle_rook_to

    function automatic logic castle_perm_by_key_index(
        input CastlePerms perms,
        input int castle_idx
    );
        case (castle_idx)
            0: return perms.white_kingside;
            1: return perms.white_queenside;
            2: return perms.black_kingside;
            3: return perms.black_queenside;
            default: return 1'b0;
        endcase
    endfunction : castle_perm_by_key_index

    function automatic EvalScore signed_piece_score(input Tile tile, input EvalScore pst_value);
        automatic EvalScore score;

        if (tile.piece_type == NULL_PIECE) begin
            return EvalScore'(0);
        end

        score = PIECE_VALS_128[tile.piece_type] + pst_value;
        return (tile.piece_color == WHITE) ? score : -score;
    endfunction : signed_piece_score

    function automatic ZobristReadPlan append_zobrist_addr(
        input ZobristReadPlan plan_in,
        input ZobristAddr address
    );
        automatic ZobristReadPlan plan = plan_in;
        automatic logic appended = 1'b0;

        for (int idx = 0; idx < ZOBRIST_READ_PORTS; idx++) begin
            if (!appended && !plan.enable[idx]) begin
                plan.enable[idx] = 1'b1;
                plan.address[idx] = address;
                appended = 1'b1;
            end
        end
        return plan;
    endfunction : append_zobrist_addr

    function automatic ZobristReadPlan append_tile_delta(
        input ZobristReadPlan plan_in,
        input Tile tile,
        input Position pos
    );
        automatic ZobristReadPlan plan = plan_in;
        if (tile.piece_type != NULL_PIECE) begin
            plan = append_zobrist_addr(plan, zobrist_tile_addr(tile, pos));
        end
        return plan;
    endfunction : append_tile_delta

    function automatic ZobristReadPlan append_side_delta(
        input ZobristReadPlan plan_in,
        input FullBoard old_board,
        input Color new_turn,
        input CastlePerms new_castle,
        input logic new_has_ep,
        input BoardFile new_ep_file
    );
        automatic ZobristReadPlan plan = plan_in;

        if (old_board.turn != new_turn)
            plan = append_zobrist_addr(plan, ZobristAddr'(ZOBRIST_TURN_BLACK_ADDR));
        for (int castle_idx = 0; castle_idx < 4; castle_idx++) begin
            if (castle_perm_by_key_index(old_board.castle_perms, castle_idx)
                != castle_perm_by_key_index(new_castle, castle_idx))
                plan = append_zobrist_addr(plan, zobrist_castle_addr(castle_idx));
        end
        if (old_board.has_ep)
            plan = append_zobrist_addr(plan, zobrist_ep_addr(old_board.ep_file));
        if (new_has_ep)
            plan = append_zobrist_addr(plan, zobrist_ep_addr(new_ep_file));
        return plan;
    endfunction : append_side_delta

    task automatic replace_tile(
        inout FullBoard board,
        inout EvalScore pst_eval,
        input Position pos,
        input Tile new_tile,
        input EvalScore old_pst,
        input EvalScore new_pst
    );
        automatic Tile old_tile = board.tiles[pos];
        automatic Tile placed_tile = new_tile;

        pst_eval += signed_piece_score(placed_tile, new_pst) - signed_piece_score(old_tile, old_pst);
        board.tiles[pos] = placed_tile;
    endtask : replace_tile

    task automatic replace_side_data(
        inout FullBoard board,
        input Color turn,
        input CastlePerms castle_perms,
        input logic has_ep,
        input BoardFile ep_file,
        input HalfmoveClock halfmove_clock
    );
        board.turn = turn;
        board.castle_perms = castle_perms;
        board.has_ep = has_ep;
        board.ep_file = ep_file;
        board.halfmove_clock = halfmove_clock;
    endtask : replace_side_data

    always_ff @(posedge clk) begin
        ctx_pipe <= next_ctx_pipe;
        zobrist_read_enable_q <= zobrist_read_plan.enable;
        pst_read_enable_q <= pst_read_plan.enable;
    end

    always_comb begin
        next_ctx_pipe[0].board_op    = board_op;
        next_ctx_pipe[0].board       = board_in;
        next_ctx_pipe[0].zobrist_key = zobrist_key_in;
        next_ctx_pipe[0].pst_eval    = pst_eval_in;
        next_ctx_pipe[0].move        = move_in;
        next_ctx_pipe[0].set_data    = set_data;
        next_ctx_pipe[0].thread_id   = thread_id;
        next_ctx_pipe[0].search_ply  = search_ply;
        next_ctx_pipe[0].move_record = move_record_out;
        next_ctx_pipe[0].is_castle   = 1'b0;
        next_ctx_pipe[0].is_ep       = 1'b0;
        next_ctx_pipe[0].is_pawn_move = 1'b0;
        next_ctx_pipe[0].overwritten_color_has_turn = 1'b0;

        move_record_rd_addr = move_hist_addr(thread_id, search_ply - PlyIndex'('d1));
        move_record_rd_en = (board_op == BOARD_REVERSE_MOVE_OP);
    end

    always_comb begin
        next_ctx_pipe[1] = ctx_pipe[0];
    end

    always_comb begin
        next_ctx_pipe[2] = ctx_pipe[1];
    end

    // Form the incremental hash delta one stage before board mutation. The
    // synchronous ROM outputs then align with the same request in ctx_pipe[2].
    always_comb begin
        automatic BoardUpdatePipelineCtx in = ctx_pipe[1];
        automatic ZobristReadPlan plan = ZobristReadPlan'(0);

        case (in.board_op)
            BOARD_PUSH_MOVE_OP, BOARD_COMMIT_MOVE_OP: begin
                automatic Position from_pos = in.move.from_pos;
                automatic Position to_pos = in.move.to_pos;
                automatic Tile start_tile = in.board.tiles[from_pos];
                automatic Tile end_tile = in.board.tiles[to_pos];
                automatic Color moved_color = start_tile.piece_color;
                automatic Color captured_color = Color'(~moved_color);
                automatic logic is_promo = (start_tile.piece_type == PAWN && (getRank(to_pos) == BoardRank'('d0) || getRank(to_pos) == BoardRank'('d7)));
                automatic logic is_castle = (start_tile.piece_type == KING && getFile(from_pos) == BoardFile'('d4) && (getFile(to_pos) == BoardFile'('d2) || getFile(to_pos) == BoardFile'('d6)));
                automatic logic is_ep = (start_tile.piece_type == PAWN && in.board.has_ep && in.board.ep_file == getFile(to_pos) && end_tile.piece_type == NULL_PIECE && ((moved_color == WHITE && getRank(to_pos) == BoardRank'('d5)) || (moved_color == BLACK && getRank(to_pos) == BoardRank'('d2))));
                automatic PieceType placed_piece = is_promo ? promo_to_piece(in.move.promo_piece) : start_tile.piece_type;
                automatic Tile placed_tile = Tile'({moved_color, placed_piece});
                automatic Position ep_capture_pos = getPosition(getRank(from_pos), getFile(to_pos));
                automatic Position rook_from = castle_rook_from(to_pos);
                automatic Position rook_to = castle_rook_to(to_pos);
                automatic Tile captured_tile = is_ep ? Tile'({captured_color, PAWN}) : end_tile;
                automatic CastlePerms next_castle = in.board.castle_perms;
                automatic logic next_has_ep;
                automatic BoardFile next_ep_file = getFile(to_pos);

                plan = append_tile_delta(plan, start_tile, from_pos);
                plan = append_tile_delta(plan, captured_tile, is_ep ? ep_capture_pos : to_pos);
                plan = append_tile_delta(plan, placed_tile, to_pos);
                if (is_castle) begin
                    automatic Tile rook_tile = Tile'({moved_color, ROOK});
                    plan = append_tile_delta(plan, rook_tile, rook_from);
                    plan = append_tile_delta(plan, rook_tile, rook_to);
                end

                if (from_pos == Position'('d4)  || from_pos == Position'('d7)  || to_pos == Position'('d7))  next_castle.white_kingside = 1'b0;
                if (from_pos == Position'('d4)  || from_pos == Position'('d0)  || to_pos == Position'('d0))  next_castle.white_queenside = 1'b0;
                if (from_pos == Position'('d60) || from_pos == Position'('d63) || to_pos == Position'('d63)) next_castle.black_kingside = 1'b0;
                if (from_pos == Position'('d60) || from_pos == Position'('d56) || to_pos == Position'('d56)) next_castle.black_queenside = 1'b0;
                next_has_ep = (start_tile.piece_type == PAWN && ((moved_color == WHITE && getRank(from_pos) == BoardRank'('d1) && getRank(to_pos) == BoardRank'('d3)) || (moved_color == BLACK && getRank(from_pos) == BoardRank'('d6) && getRank(to_pos) == BoardRank'('d4))));
                plan = append_side_delta(plan, in.board, Color'(~in.board.turn), next_castle, next_has_ep, next_ep_file);
            end

            BOARD_REVERSE_MOVE_OP: begin
                automatic MoveRecord rec = in.move_record;
                automatic Position from_pos = rec.from_pos;
                automatic Position to_pos = rec.to_pos;
                automatic Color moved_color = Color'(~in.board.turn);
                automatic Color captured_color = in.board.turn;
                automatic Tile end_tile = in.board.tiles[to_pos];
                automatic logic is_promo = (rec.move_flag == PROMO_MOVE);
                automatic logic is_ep = (rec.move_flag == EP_MOVE);
                automatic logic is_castle = (rec.move_flag == CASTLE_MOVE);
                automatic PieceType restored_piece = is_promo ? PAWN : end_tile.piece_type;
                automatic Tile restored_mover = Tile'({moved_color, restored_piece});
                automatic Tile restored_capture = (rec.killed_piece == NULL_PIECE) ? EMPTY_TILE : Tile'({captured_color, rec.killed_piece});
                automatic Position ep_capture_pos = getPosition(getRank(from_pos), getFile(to_pos));
                automatic Position rook_from = castle_rook_from(to_pos);
                automatic Position rook_to = castle_rook_to(to_pos);

                plan = append_tile_delta(plan, end_tile, to_pos);
                plan = append_tile_delta(plan, restored_mover, from_pos);
                plan = append_tile_delta(plan, restored_capture, to_pos);
                if (is_ep)
                    plan = append_tile_delta(plan, Tile'({captured_color, PAWN}), ep_capture_pos);
                if (is_castle) begin
                    automatic Tile rook_tile = Tile'({moved_color, ROOK});
                    plan = append_tile_delta(plan, rook_tile, rook_to);
                    plan = append_tile_delta(plan, rook_tile, rook_from);
                end
                plan = append_side_delta(plan, in.board, moved_color, rec.castle_perms, rec.has_ep, rec.ep_file);
            end

            BOARD_SET_TILE_OP: begin
                automatic Position to_pos = in.move.to_pos;
                plan = append_tile_delta(plan, in.board.tiles[to_pos], to_pos);
                plan = append_tile_delta(plan, Tile'(in.set_data[3:0]), to_pos);
            end
            BOARD_SET_TURN_OP:
                plan = append_side_delta(plan, in.board, Color'(in.set_data[0]), in.board.castle_perms, in.board.has_ep, in.board.ep_file);
            BOARD_SET_CASTLE_PERMS_OP:
                plan = append_side_delta(plan, in.board, in.board.turn, CastlePerms'(in.set_data[3:0]), in.board.has_ep, in.board.ep_file);
            BOARD_SET_EN_PASSANT_OP:
                plan = append_side_delta(plan, in.board, in.board.turn, in.board.castle_perms, in.set_data[0], BoardFile'(in.set_data[3:1]));
            default: begin end
        endcase
        zobrist_read_plan = plan;
    end

    // Form all PST reads one stage before board mutation. Two replicated
    // true-dual-port ROMs supply the four values needed by castling without
    // changing the external pipeline latency.
    always_comb begin
        automatic BoardUpdatePipelineCtx in = ctx_pipe[1];
        automatic PstReadPlan plan = PstReadPlan'(0);

        case (in.board_op)
            BOARD_PUSH_MOVE_OP, BOARD_COMMIT_MOVE_OP: begin
                automatic Position from_pos = in.move.from_pos;
                automatic Position to_pos = in.move.to_pos;
                automatic Tile start_tile = in.board.tiles[from_pos];
                automatic Tile end_tile = in.board.tiles[to_pos];
                automatic Color moved_color = start_tile.piece_color;
                automatic Color captured_color = Color'(~moved_color);
                automatic logic is_promo = (start_tile.piece_type == PAWN && (getRank(to_pos) == BoardRank'('d0) || getRank(to_pos) == BoardRank'('d7)));
                automatic logic is_castle = (start_tile.piece_type == KING && getFile(from_pos) == BoardFile'('d4) && (getFile(to_pos) == BoardFile'('d2) || getFile(to_pos) == BoardFile'('d6)));
                automatic logic is_ep = (start_tile.piece_type == PAWN && in.board.has_ep && in.board.ep_file == getFile(to_pos) && end_tile.piece_type == NULL_PIECE && ((moved_color == WHITE && getRank(to_pos) == BoardRank'('d5)) || (moved_color == BLACK && getRank(to_pos) == BoardRank'('d2))));
                automatic PieceType placed_piece = is_promo ? promo_to_piece(in.move.promo_piece) : start_tile.piece_type;
                automatic Tile placed_tile = Tile'({moved_color, placed_piece});
                automatic Position ep_capture_pos = getPosition(getRank(from_pos), getFile(to_pos));
                automatic Position rook_from = castle_rook_from(to_pos);
                automatic Position rook_to = castle_rook_to(to_pos);
                automatic Tile captured_tile = is_ep ? Tile'({captured_color, PAWN}) : end_tile;

                plan.address[0] = pst_addr(start_tile.piece_type, oriented_pos(start_tile, from_pos));
                plan.enable[0] = (start_tile.piece_type != NULL_PIECE);
                plan.address[1] = pst_addr(placed_tile.piece_type, oriented_pos(placed_tile, to_pos));
                plan.enable[1] = (placed_tile.piece_type != NULL_PIECE);
                if (is_castle) begin
                    automatic Tile rook_tile = Tile'({moved_color, ROOK});
                    plan.address[2] = pst_addr(ROOK, oriented_pos(rook_tile, rook_from));
                    plan.address[3] = pst_addr(ROOK, oriented_pos(rook_tile, rook_to));
                    plan.enable[2] = 1'b1;
                    plan.enable[3] = 1'b1;
                end else if (captured_tile.piece_type != NULL_PIECE) begin
                    plan.address[2] = pst_addr(captured_tile.piece_type, oriented_pos(captured_tile, is_ep ? ep_capture_pos : to_pos));
                    plan.enable[2] = 1'b1;
                end
            end

            BOARD_REVERSE_MOVE_OP: begin
                automatic MoveRecord rec = in.move_record;
                automatic Position from_pos = rec.from_pos;
                automatic Position to_pos = rec.to_pos;
                automatic Color moved_color = Color'(~in.board.turn);
                automatic Color captured_color = in.board.turn;
                automatic Tile end_tile = in.board.tiles[to_pos];
                automatic logic is_promo = (rec.move_flag == PROMO_MOVE);
                automatic logic is_ep = (rec.move_flag == EP_MOVE);
                automatic logic is_castle = (rec.move_flag == CASTLE_MOVE);
                automatic PieceType restored_piece = is_promo ? PAWN : end_tile.piece_type;
                automatic Tile restored_mover = Tile'({moved_color, restored_piece});
                automatic Tile restored_capture = (rec.killed_piece == NULL_PIECE) ? EMPTY_TILE : Tile'({captured_color, rec.killed_piece});
                automatic Position ep_capture_pos = getPosition(getRank(from_pos), getFile(to_pos));
                automatic Position rook_from = castle_rook_from(to_pos);
                automatic Position rook_to = castle_rook_to(to_pos);

                plan.address[0] = pst_addr(restored_mover.piece_type, oriented_pos(restored_mover, from_pos));
                plan.enable[0] = 1'b1;
                plan.address[1] = pst_addr(end_tile.piece_type, oriented_pos(end_tile, to_pos));
                plan.enable[1] = (end_tile.piece_type != NULL_PIECE);
                if (is_castle) begin
                    automatic Tile rook_tile = Tile'({moved_color, ROOK});
                    plan.address[2] = pst_addr(ROOK, oriented_pos(rook_tile, rook_from));
                    plan.address[3] = pst_addr(ROOK, oriented_pos(rook_tile, rook_to));
                    plan.enable[2] = 1'b1;
                    plan.enable[3] = 1'b1;
                end else if (is_ep) begin
                    automatic Tile ep_tile = Tile'({captured_color, PAWN});
                    plan.address[2] = pst_addr(PAWN, oriented_pos(ep_tile, ep_capture_pos));
                    plan.enable[2] = 1'b1;
                end else if (rec.killed_piece != NULL_PIECE) begin
                    plan.address[2] = pst_addr(rec.killed_piece, oriented_pos(restored_capture, to_pos));
                    plan.enable[2] = 1'b1;
                end
            end

            BOARD_SET_TILE_OP: begin
                automatic Position to_pos = in.move.to_pos;
                automatic Tile old_tile = in.board.tiles[to_pos];
                automatic Tile new_tile = Tile'(in.set_data[3:0]);
                plan.address[2] = pst_addr(old_tile.piece_type, oriented_pos(old_tile, to_pos));
                plan.enable[2] = (old_tile.piece_type != NULL_PIECE);
                plan.address[1] = pst_addr(new_tile.piece_type, oriented_pos(new_tile, to_pos));
                plan.enable[1] = (new_tile.piece_type != NULL_PIECE);
            end
            default: begin end
        endcase

        pst_read_plan = plan;
    end

    always_comb begin
        automatic BoardUpdatePipelineCtx in = ctx_pipe[2];
        automatic BoardUpdatePipelineCtx out = in;

        for (int port_idx = 0; port_idx < ZOBRIST_READ_PORTS; port_idx++) begin
            if (zobrist_read_enable_q[port_idx])
                out.zobrist_key ^= zobrist_read_data[port_idx];
        end

        case (in.board_op)
            BOARD_PUSH_MOVE_OP, BOARD_COMMIT_MOVE_OP: begin
                automatic Position from_pos = in.move.from_pos;
                automatic Position to_pos = in.move.to_pos;
                automatic Tile start_tile = in.board.tiles[from_pos];
                automatic Tile end_tile = in.board.tiles[to_pos];
                automatic Color moved_color = start_tile.piece_color;
                automatic logic is_promo = (start_tile.piece_type == PAWN && (getRank(to_pos) == BoardRank'('d0) || getRank(to_pos) == BoardRank'('d7)));
                automatic logic is_castle = (start_tile.piece_type == KING && getFile(from_pos) == BoardFile'('d4) && (getFile(to_pos) == BoardFile'('d2) || getFile(to_pos) == BoardFile'('d6)));
                automatic logic is_ep = (start_tile.piece_type == PAWN && in.board.has_ep && in.board.ep_file == getFile(to_pos) && end_tile.piece_type == NULL_PIECE && ((moved_color == WHITE && getRank(to_pos) == BoardRank'('d5)) || (moved_color == BLACK && getRank(to_pos) == BoardRank'('d2))));
                automatic PieceType placed_piece = is_promo ? promo_to_piece(in.move.promo_piece) : start_tile.piece_type;
                automatic Tile placed_tile = Tile'({moved_color, placed_piece});
                automatic Position ep_capture_pos = getPosition(getRank(from_pos), getFile(to_pos));
                automatic Position rook_from = castle_rook_from(to_pos);
                automatic Position rook_to = castle_rook_to(to_pos);
                automatic CastlePerms next_castle = in.board.castle_perms;
                automatic logic next_has_ep;
                automatic BoardFile next_ep_file = getFile(to_pos);
                automatic HalfmoveClock next_halfmove;

                replace_tile(out.board, out.pst_eval, from_pos, EMPTY_TILE, pst_start_out, EvalScore'(0));
                replace_tile(out.board, out.pst_eval, to_pos, placed_tile, (is_ep || is_castle) ? EvalScore'(0) : pst_killed_out, pst_end_out);

                if (is_ep) begin
                    replace_tile(out.board, out.pst_eval, ep_capture_pos, EMPTY_TILE, pst_killed_out, EvalScore'(0));
                end

                if (is_castle) begin
                    automatic Tile rook_tile = Tile'({moved_color, ROOK});
                    replace_tile(out.board, out.pst_eval, rook_from, EMPTY_TILE, pst_killed_out, EvalScore'(0));
                    replace_tile(out.board, out.pst_eval, rook_to, rook_tile, EvalScore'(0), pst_castle_out);
                end

                out.move_record.from_pos = from_pos;
                out.move_record.to_pos = to_pos;
                out.move_record.killed_piece = is_ep ? NULL_PIECE : end_tile.piece_type;
                out.move_record.castle_perms = in.board.castle_perms;
                out.move_record.move_flag = is_promo ? PROMO_MOVE : is_castle ? CASTLE_MOVE : is_ep ? EP_MOVE : NORM_MOVE;
                out.move_record.has_ep = in.board.has_ep;
                out.move_record.ep_file = in.board.ep_file;
                out.move_record.halfmove_clock = in.board.halfmove_clock;
                out.is_castle = is_castle;
                out.is_ep = is_ep;
                out.is_pawn_move = (start_tile.piece_type == PAWN);

                if (from_pos == Position'('d4)  || from_pos == Position'('d7)  || to_pos == Position'('d7))  next_castle.white_kingside = 1'b0;
                if (from_pos == Position'('d4)  || from_pos == Position'('d0)  || to_pos == Position'('d0))  next_castle.white_queenside = 1'b0;
                if (from_pos == Position'('d60) || from_pos == Position'('d63) || to_pos == Position'('d63)) next_castle.black_kingside = 1'b0;
                if (from_pos == Position'('d60) || from_pos == Position'('d56) || to_pos == Position'('d56)) next_castle.black_queenside = 1'b0;

                next_has_ep = (start_tile.piece_type == PAWN && ((moved_color == WHITE && getRank(from_pos) == BoardRank'('d1) && getRank(to_pos) == BoardRank'('d3)) || (moved_color == BLACK && getRank(from_pos) == BoardRank'('d6) && getRank(to_pos) == BoardRank'('d4))));
                next_halfmove = (is_ep || end_tile.piece_type != NULL_PIECE || start_tile.piece_type == PAWN) ? HalfmoveClock'('d0) : in.board.halfmove_clock + HalfmoveClock'('d1);
                replace_side_data(out.board, Color'(~in.board.turn), next_castle, next_has_ep, next_ep_file, next_halfmove);
            end

            BOARD_REVERSE_MOVE_OP: begin
                automatic MoveRecord rec = in.move_record;
                automatic Position from_pos = rec.from_pos;
                automatic Position to_pos = rec.to_pos;
                automatic Color moved_color = Color'(~in.board.turn);
                automatic Color captured_color = in.board.turn;
                automatic Tile end_tile = in.board.tiles[to_pos];
                automatic logic is_promo = (rec.move_flag == PROMO_MOVE);
                automatic logic is_ep = (rec.move_flag == EP_MOVE);
                automatic logic is_castle = (rec.move_flag == CASTLE_MOVE);
                automatic PieceType restored_piece = is_promo ? PAWN : end_tile.piece_type;
                automatic Tile restored_mover = Tile'({moved_color, restored_piece});
                automatic Tile restored_capture = (rec.killed_piece == NULL_PIECE) ? EMPTY_TILE : Tile'({captured_color, rec.killed_piece});
                automatic Position ep_capture_pos = getPosition(getRank(from_pos), getFile(to_pos));
                automatic Position rook_from = castle_rook_from(to_pos);
                automatic Position rook_to = castle_rook_to(to_pos);

                replace_tile(out.board, out.pst_eval, from_pos, restored_mover, EvalScore'(0), pst_start_out);
                replace_tile(out.board, out.pst_eval, to_pos, restored_capture, pst_end_out, is_ep ? EvalScore'(0) : pst_killed_out);

                if (is_ep) begin
                    automatic Tile ep_tile = Tile'({captured_color, PAWN});
                    replace_tile(out.board, out.pst_eval, ep_capture_pos, ep_tile, EvalScore'(0), pst_killed_out);
                end

                if (is_castle) begin
                    automatic Tile rook_tile = Tile'({moved_color, ROOK});
                    replace_tile(out.board, out.pst_eval, rook_to, EMPTY_TILE, pst_castle_out, EvalScore'(0));
                    replace_tile(out.board, out.pst_eval, rook_from, rook_tile, EvalScore'(0), pst_killed_out);
                end

                replace_side_data(out.board, moved_color, rec.castle_perms, rec.has_ep, rec.ep_file, rec.halfmove_clock);
                out.move_record = rec;
                out.is_castle = is_castle;
                out.is_ep = is_ep;
            end

            BOARD_SET_TILE_OP: begin
                automatic Position to_pos = in.move.to_pos;
                automatic Tile new_tile = Tile'(in.set_data[3:0]);

                replace_tile(out.board, out.pst_eval, to_pos, new_tile, pst_killed_out, pst_end_out);
            end

            BOARD_SET_TURN_OP: begin
                replace_side_data(out.board, Color'(in.set_data[0]), in.board.castle_perms, in.board.has_ep, in.board.ep_file, in.board.halfmove_clock);
            end

            BOARD_SET_CASTLE_PERMS_OP: begin
                replace_side_data(out.board, in.board.turn, CastlePerms'(in.set_data[3:0]), in.board.has_ep, in.board.ep_file, in.board.halfmove_clock);
            end

            BOARD_SET_EN_PASSANT_OP: begin
                replace_side_data(out.board, in.board.turn, in.board.castle_perms, in.set_data[0], BoardFile'(in.set_data[3:1]), in.board.halfmove_clock);
            end

            BOARD_SET_HALFMOVE_CLOCK_OP: begin
                replace_side_data(out.board, in.board.turn, in.board.castle_perms, in.board.has_ep, in.board.ep_file, HalfmoveClock'(in.set_data));
            end

            BOARD_IDLE_OP: begin
                out = BoardUpdatePipelineCtx'('dx);
                out.board_op = in.board_op;
            end
        endcase

        next_ctx_pipe[3] = out;
    end

    always_comb begin
        automatic BoardUpdatePipelineCtx in = ctx_pipe[3];
        automatic BoardUpdatePipelineCtx out = in;

        move_record_in = in.move_record;
        move_record_wr_en = (in.board_op == BOARD_PUSH_MOVE_OP);
        move_record_wr_addr = move_hist_addr(in.thread_id, in.search_ply);

        if (in.board_op == BOARD_IDLE_OP) begin
            out = BoardUpdatePipelineCtx'('dx);
            out.board_op = in.board_op;
        end

        next_ctx_pipe[4] = out;
    end

    always_comb begin
        next_ctx_pipe[5] = ctx_pipe[4];
    end

    always_comb begin
        next_ctx_pipe[6] = ctx_pipe[5];
    end

endmodule : board_update_pipeline
