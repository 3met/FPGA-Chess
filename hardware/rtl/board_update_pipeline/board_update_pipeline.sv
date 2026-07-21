// By Emet Behrendt

import general_chess_defs::*;
import chess_helper_funcs::*;
import board_update_pipeline_defs::*;
import zobrist_defs::*;
import zobrist_values_pkg::*;

module board_update_pipeline #(
    parameter int MOVE_RECORD_THREAD_COUNT = THREAD_COUNT,
    parameter int MOVE_RECORD_PLY_COUNT = MAX_PLY_COUNT
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
    output EvalScore pst_eval_out,
    output logic mover_in_check_out
);

    typedef logic [8:0] PstAddr;
    typedef logic [2:0] PstPieceIndex;
    localparam int PST_ENTRY_COUNT = 6 * 64;
    localparam PST_MEM_INIT_FILE = "hardware/data/pst_values/pst_values.hex";
    localparam int PST_READ_PORTS = 4;
    localparam int ZOBRIST_TILE_READ_PORTS = 4;

    typedef struct packed {
        logic [PST_READ_PORTS-1:0] enable;
        PstAddr [PST_READ_PORTS-1:0] address;
    } PstReadPlan;

    typedef struct packed {
        logic [ZOBRIST_TILE_READ_PORTS-1:0] enable;
        ZobristAddr [ZOBRIST_TILE_READ_PORTS-1:0] address;
    } ZobristReadPlan;

    typedef struct packed {
        Position from_pos;
        Position to_pos;
        Position ep_capture_pos;
        Position rook_from;
        Position rook_to;
        Tile start_tile;
        Tile end_tile;
        Tile placed_tile;
        Tile restored_mover;
        Tile restored_capture;
        logic is_promo;
        logic is_castle;
        logic is_ep;
    } MoveEffects;

    localparam MOVE_RECORD_COUNT = MOVE_RECORD_THREAD_COUNT * MOVE_RECORD_PLY_COUNT;
    localparam MOVE_RECORD_ADDR_BITS = (MOVE_RECORD_COUNT <= 1) ? 1 : $clog2(MOVE_RECORD_COUNT);
    typedef logic [MOVE_RECORD_ADDR_BITS-1:0] MoveRecordAddr;

    BoardUpdatePipelineCtx ctx_pipe[2];
    BoardUpdatePipelineCtx next_ctx_pipe[2];
    FullBoard next_board_out;
    ZobristKey next_zobrist_key_out;
    EvalScore next_pst_eval_out;

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
    PstScore pst_read_data[PST_READ_PORTS];
    EvalScore pst_start_out, pst_end_out, pst_killed_out, pst_castle_out;
    ZobristReadPlan zobrist_read_plan;
    logic [ZOBRIST_TILE_READ_PORTS-1:0] zobrist_read_enable_q;
    ZobristKey zobrist_read_data[ZOBRIST_TILE_READ_PORTS];
    logic zobrist_turn_toggle, zobrist_turn_toggle_q;
    CastlePerms zobrist_castle_toggle, zobrist_castle_toggle_q;
    logic zobrist_old_ep_enable, zobrist_new_ep_enable;
    logic zobrist_old_ep_enable_q, zobrist_new_ep_enable_q;
    ZobristAddr zobrist_old_ep_address, zobrist_new_ep_address;
    ZobristKey zobrist_old_ep_data, zobrist_new_ep_data;
    MoveEffects move_effects, move_effects_q;

    localparam ZobristKey ZOBRIST_TURN_VALUE =
        zobrist_value(ZobristAddr'(ZOBRIST_TURN_BLACK_ADDR));
    localparam ZobristKey ZOBRIST_WHITE_KINGSIDE_VALUE =
        zobrist_value(ZobristAddr'(ZOBRIST_CASTLE_BASE_ADDR));
    localparam ZobristKey ZOBRIST_WHITE_QUEENSIDE_VALUE =
        zobrist_value(ZobristAddr'(ZOBRIST_CASTLE_BASE_ADDR + 1));
    localparam ZobristKey ZOBRIST_BLACK_KINGSIDE_VALUE =
        zobrist_value(ZobristAddr'(ZOBRIST_CASTLE_BASE_ADDR + 2));
    localparam ZobristKey ZOBRIST_BLACK_QUEENSIDE_VALUE =
        zobrist_value(ZobristAddr'(ZOBRIST_CASTLE_BASE_ADDR + 3));

    genvar port_pair;
    generate
        for (port_pair = 0; port_pair < ZOBRIST_TILE_READ_PORTS / 2; port_pair = port_pair + 1) begin : gen_zobrist_rom
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
    endgenerate

    // Side-state hashing needs only the old and new en-passant file values.
    // Turn and castling keys are fixed constants, so keeping them out of the
    // replicated piece ROMs halves the piece-table read-port requirement.
    synchronous_dual_port_rom #(
        .NUM_WORDS(ZOBRIST_ENTRY_CNT),
        .WORD_SIZE($bits(ZobristKey)),
        .MEM_INIT_FILE(ZOBRIST_MEM_INIT_FILE)
    ) zobrist_ep_rom (
        .clock(clk),
        .address_a(zobrist_old_ep_address),
        .address_b(zobrist_new_ep_address),
        .rden_a(zobrist_old_ep_enable),
        .rden_b(zobrist_new_ep_enable),
        .q_a(zobrist_old_ep_data),
        .q_b(zobrist_new_ep_data)
    );

    generate
        for (port_pair = 0; port_pair < PST_READ_PORTS / 2; port_pair = port_pair + 1) begin : gen_pst_rom
            synchronous_dual_port_rom #(
                .NUM_WORDS(PST_ENTRY_COUNT),
                .WORD_SIZE($bits(PstScore)),
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
    endgenerate

    // Keep all accumulated evaluation state at 16 bits while the ROM uses compact entries.
    assign pst_start_out = pst_read_enable_q[0] ? EvalScore'(pst_read_data[0]) : EvalScore'(0);
    assign pst_end_out = pst_read_enable_q[1] ? EvalScore'(pst_read_data[1]) : EvalScore'(0);
    assign pst_killed_out = pst_read_enable_q[2] ? EvalScore'(pst_read_data[2]) : EvalScore'(0);
    assign pst_castle_out = pst_read_enable_q[3] ? EvalScore'(pst_read_data[3]) : EvalScore'(0);

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

    function automatic EvalScore signed_piece_score(input Tile tile, input EvalScore pst_value);
        automatic EvalScore score;

        if (tile.piece_type == NULL_PIECE) begin
            return EvalScore'(0);
        end

        score = PIECE_VALS_128[tile.piece_type] + pst_value;
        return (tile.piece_color == WHITE) ? score : -score;
    endfunction : signed_piece_score

    function automatic logic is_line_attacker(input PieceType piece, input Direction dir);
        return piece == QUEEN
            || (piece == ROOK && isDirCardinal(dir))
            || (piece == BISHOP && isDirDiag(dir));
    endfunction : is_line_attacker

    function automatic Position find_king(input FullBoard board, input Color king_color);
        for (int pos = 0; pos < 64; pos++) begin
            if (board.tiles[pos] == Tile'({king_color, KING})) begin
                return Position'(pos);
            end
        end
        return Position'('x);
    endfunction : find_king

    function automatic Tile pushed_tile(input FullBoard board, input MoveEffects effects, input Position pos);
        automatic Tile tile = board.tiles[pos];

        if (pos == effects.from_pos) tile = EMPTY_TILE;
        if (pos == effects.to_pos) tile = effects.placed_tile;
        if (effects.is_ep && pos == effects.ep_capture_pos) tile = EMPTY_TILE;
        if (effects.is_castle && pos == effects.rook_from) tile = EMPTY_TILE;
        if (effects.is_castle && pos == effects.rook_to) tile = Tile'({board.turn, ROOK});
        return tile;
    endfunction : pushed_tile

    function automatic logic pushed_square_attacked(
        input FullBoard board,
        input MoveEffects effects,
        input Position square,
        input Color attacker_color
    );
        automatic Position test_pos;
        automatic Tile test_tile;

        if (attacker_color == WHITE) begin
            if (isShiftOnBoard(square, SOUTH_WEST, 3'd1)
                    && pushed_tile(board, effects, shiftPos(square, SOUTH_WEST, 3'd1)) == WHITE_PAWN) return 1'b1;
            if (isShiftOnBoard(square, SOUTH_EAST, 3'd1)
                    && pushed_tile(board, effects, shiftPos(square, SOUTH_EAST, 3'd1)) == WHITE_PAWN) return 1'b1;
        end else begin
            if (isShiftOnBoard(square, NORTH_WEST, 3'd1)
                    && pushed_tile(board, effects, shiftPos(square, NORTH_WEST, 3'd1)) == BLACK_PAWN) return 1'b1;
            if (isShiftOnBoard(square, NORTH_EAST, 3'd1)
                    && pushed_tile(board, effects, shiftPos(square, NORTH_EAST, 3'd1)) == BLACK_PAWN) return 1'b1;
        end

        for (int knight_dir = 0; knight_dir < 8; knight_dir++) begin
            if (isKnightShiftOnBoard(square, KnightDirection'(knight_dir))) begin
                test_pos = shiftKnightPos(square, KnightDirection'(knight_dir));
                if (pushed_tile(board, effects, test_pos) == Tile'({attacker_color, KNIGHT})) return 1'b1;
            end
        end

        for (int dir_idx = 0; dir_idx < 8; dir_idx++) begin
            automatic Direction dir = Direction'(dir_idx);
            for (int distance = 1; distance < 8; distance++) begin
                if (isShiftOnBoard(square, dir, distance[2:0])) begin
                    test_pos = shiftPos(square, dir, distance[2:0]);
                    test_tile = pushed_tile(board, effects, test_pos);
                    if (test_tile.piece_type != NULL_PIECE) begin
                        if (test_tile.piece_color == attacker_color) begin
                            if (distance == 1 && test_tile.piece_type == KING) return 1'b1;
                            if (is_line_attacker(test_tile.piece_type, dir)) return 1'b1;
                        end
                        break;
                    end
                end
            end
        end

        return 1'b0;
    endfunction : pushed_square_attacked

    function automatic logic pushed_mover_in_check(
        input FullBoard board,
        input MoveEffects effects,
        input Position king_square
    );
        automatic Color mover_color = board.turn;
        return pushed_square_attacked(
            board,
            effects,
            king_square,
            Color'(~mover_color)
        );
    endfunction : pushed_mover_in_check

    function automatic Position pushed_king_square(input FullBoard board, input Move move);
        if (board.tiles[move.from_pos].piece_type == KING) begin
            return move.to_pos;
        end
        return find_king(board, board.turn);
    endfunction : pushed_king_square

    task automatic plan_side_delta(
        input FullBoard old_board,
        input Color new_turn,
        input CastlePerms new_castle,
        input logic new_has_ep,
        input BoardFile new_ep_file
    );
        zobrist_turn_toggle = (old_board.turn != new_turn);
        zobrist_castle_toggle = old_board.castle_perms ^ new_castle;
        zobrist_old_ep_enable = old_board.has_ep;
        zobrist_new_ep_enable = new_has_ep;
        zobrist_old_ep_address = zobrist_ep_addr(old_board.ep_file);
        zobrist_new_ep_address = zobrist_ep_addr(new_ep_file);
    endtask : plan_side_delta

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

    // Decode dynamic board reads and special-move geometry once for both
    // table planners, then register the same effects for board mutation.
    always_comb begin
        automatic BoardUpdatePipelineCtx in = ctx_pipe[0];
        automatic MoveEffects effects = MoveEffects'('x);

        effects.from_pos = in.move.from_pos;
        effects.to_pos = in.move.to_pos;

        case (in.board_op)
            BOARD_PUSH_MOVE_OP, BOARD_COMMIT_MOVE_OP: begin
                automatic Color moved_color;

                effects.start_tile = in.board.tiles[effects.from_pos];
                effects.end_tile = in.board.tiles[effects.to_pos];
                moved_color = effects.start_tile.piece_color;
                effects.is_promo = effects.start_tile.piece_type == PAWN
                    && (getRank(effects.to_pos) == BoardRank'('d0)
                        || getRank(effects.to_pos) == BoardRank'('d7));
                effects.is_castle = effects.start_tile.piece_type == KING
                    && getFile(effects.from_pos) == BoardFile'('d4)
                    && (getFile(effects.to_pos) == BoardFile'('d2)
                        || getFile(effects.to_pos) == BoardFile'('d6));
                effects.is_ep = effects.start_tile.piece_type == PAWN
                    && in.board.has_ep
                    && in.board.ep_file == getFile(effects.to_pos)
                    && effects.end_tile.piece_type == NULL_PIECE
                    && ((moved_color == WHITE && getRank(effects.to_pos) == BoardRank'('d5))
                        || (moved_color == BLACK && getRank(effects.to_pos) == BoardRank'('d2)));
                effects.placed_tile = Tile'({
                    moved_color,
                    effects.is_promo
                        ? promo_to_piece(in.move.promo_piece)
                        : effects.start_tile.piece_type
                });
                effects.ep_capture_pos = getPosition(
                    getRank(effects.from_pos),
                    getFile(effects.to_pos)
                );
                effects.rook_from = castle_rook_from(effects.to_pos);
                effects.rook_to = castle_rook_to(effects.to_pos);
            end

            BOARD_REVERSE_MOVE_OP: begin
                automatic MoveRecord rec = in.move_record;
                automatic Color moved_color = Color'(~in.board.turn);
                automatic Color captured_color = in.board.turn;

                effects.from_pos = rec.from_pos;
                effects.to_pos = rec.to_pos;
                effects.end_tile = in.board.tiles[effects.to_pos];
                effects.is_promo = (rec.move_flag == PROMO_MOVE);
                effects.is_ep = (rec.move_flag == EP_MOVE);
                effects.is_castle = (rec.move_flag == CASTLE_MOVE);
                effects.restored_mover = Tile'({
                    moved_color,
                    effects.is_promo ? PAWN : effects.end_tile.piece_type
                });
                effects.restored_capture = rec.killed_piece == NULL_PIECE
                    ? EMPTY_TILE
                    : Tile'({captured_color, rec.killed_piece});
                effects.ep_capture_pos = getPosition(
                    getRank(effects.from_pos),
                    getFile(effects.to_pos)
                );
                effects.rook_from = castle_rook_from(effects.to_pos);
                effects.rook_to = castle_rook_to(effects.to_pos);
            end

            default: begin end
        endcase

        move_effects = effects;
    end

    always_ff @(posedge clk) begin
        ctx_pipe <= next_ctx_pipe;
        board_out <= next_board_out;
        zobrist_key_out <= next_zobrist_key_out;
        pst_eval_out <= next_pst_eval_out;
        mover_in_check_out <= ctx_pipe[1].mover_in_check;
        zobrist_read_enable_q <= zobrist_read_plan.enable;
        zobrist_turn_toggle_q <= zobrist_turn_toggle;
        zobrist_castle_toggle_q <= zobrist_castle_toggle;
        zobrist_old_ep_enable_q <= zobrist_old_ep_enable;
        zobrist_new_ep_enable_q <= zobrist_new_ep_enable;
        pst_read_enable_q <= pst_read_plan.enable;
        move_effects_q <= move_effects;
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
        // Locate the mover's king one stage before the attack scan so neither
        // operation sits in series on the same timing path.
        next_ctx_pipe[0].mover_king_square = (board_op == BOARD_PUSH_MOVE_OP)
            ? pushed_king_square(board_in, move_in)
            : Position'(0);
        next_ctx_pipe[0].mover_in_check = 1'b0;

        move_record_rd_addr = move_hist_addr(thread_id, search_ply - PlyIndex'('d1));
        move_record_rd_en = (board_op == BOARD_REVERSE_MOVE_OP);
    end

    always_comb begin
        next_ctx_pipe[1] = ctx_pipe[0];
        // King safety is evaluated in parallel with the synchronous table
        // reads and carried to the stage-2 board result without adding a cycle.
        next_ctx_pipe[1].mover_in_check = (ctx_pipe[0].board_op == BOARD_PUSH_MOVE_OP)
            ? pushed_mover_in_check(ctx_pipe[0].board, move_effects, ctx_pipe[0].mover_king_square)
            : 1'b0;
    end

    // Form the incremental hash delta one stage before board mutation. The
    // synchronous ROM outputs then align with the same request in ctx_pipe[1].
    always_comb begin
        automatic BoardUpdatePipelineCtx in = ctx_pipe[0];
        automatic ZobristReadPlan plan = ZobristReadPlan'(0);

        zobrist_turn_toggle = 1'b0;
        zobrist_castle_toggle = CastlePerms'(0);
        zobrist_old_ep_enable = 1'b0;
        zobrist_new_ep_enable = 1'b0;
        zobrist_old_ep_address = ZobristAddr'(0);
        zobrist_new_ep_address = ZobristAddr'(0);

        case (in.board_op)
            BOARD_PUSH_MOVE_OP, BOARD_COMMIT_MOVE_OP: begin
                automatic MoveEffects effects = move_effects;
                automatic Position from_pos = effects.from_pos;
                automatic Position to_pos = effects.to_pos;
                automatic Tile start_tile = effects.start_tile;
                automatic Tile end_tile = effects.end_tile;
                automatic Color moved_color = start_tile.piece_color;
                automatic Color captured_color = Color'(~moved_color);
                automatic logic is_castle = effects.is_castle;
                automatic logic is_ep = effects.is_ep;
                automatic Tile placed_tile = effects.placed_tile;
                automatic Position ep_capture_pos = effects.ep_capture_pos;
                automatic Position rook_from = effects.rook_from;
                automatic Position rook_to = effects.rook_to;
                automatic Tile captured_tile = is_ep ? Tile'({captured_color, PAWN}) : end_tile;
                automatic CastlePerms next_castle = in.board.castle_perms;
                automatic logic next_has_ep;
                automatic BoardFile next_ep_file = getFile(to_pos);

                plan.address[0] = zobrist_tile_addr(start_tile, from_pos);
                plan.enable[0] = (start_tile.piece_type != NULL_PIECE);
                plan.address[1] = zobrist_tile_addr(placed_tile, to_pos);
                plan.enable[1] = (placed_tile.piece_type != NULL_PIECE);
                if (is_castle) begin
                    automatic Tile rook_tile = Tile'({moved_color, ROOK});
                    plan.address[2] = zobrist_tile_addr(rook_tile, rook_from);
                    plan.address[3] = zobrist_tile_addr(rook_tile, rook_to);
                    plan.enable[2] = 1'b1;
                    plan.enable[3] = 1'b1;
                end else begin
                    plan.address[2] = zobrist_tile_addr(captured_tile, is_ep ? ep_capture_pos : to_pos);
                    plan.enable[2] = (captured_tile.piece_type != NULL_PIECE);
                end

                if (from_pos == Position'('d4)  || from_pos == Position'('d7)  || to_pos == Position'('d7))  next_castle.white_kingside = 1'b0;
                if (from_pos == Position'('d4)  || from_pos == Position'('d0)  || to_pos == Position'('d0))  next_castle.white_queenside = 1'b0;
                if (from_pos == Position'('d60) || from_pos == Position'('d63) || to_pos == Position'('d63)) next_castle.black_kingside = 1'b0;
                if (from_pos == Position'('d60) || from_pos == Position'('d56) || to_pos == Position'('d56)) next_castle.black_queenside = 1'b0;
                next_has_ep = (start_tile.piece_type == PAWN && ((moved_color == WHITE && getRank(from_pos) == BoardRank'('d1) && getRank(to_pos) == BoardRank'('d3)) || (moved_color == BLACK && getRank(from_pos) == BoardRank'('d6) && getRank(to_pos) == BoardRank'('d4))));
                plan_side_delta(in.board, Color'(~in.board.turn), next_castle, next_has_ep, next_ep_file);
            end

            BOARD_REVERSE_MOVE_OP: begin
                automatic MoveRecord rec = in.move_record;
                automatic MoveEffects effects = move_effects;
                automatic Position from_pos = effects.from_pos;
                automatic Position to_pos = effects.to_pos;
                automatic Color moved_color = Color'(~in.board.turn);
                automatic Color captured_color = in.board.turn;
                automatic Tile end_tile = effects.end_tile;
                automatic logic is_ep = effects.is_ep;
                automatic logic is_castle = effects.is_castle;
                automatic Tile restored_mover = effects.restored_mover;
                automatic Tile restored_capture = effects.restored_capture;
                automatic Position ep_capture_pos = effects.ep_capture_pos;
                automatic Position rook_from = effects.rook_from;
                automatic Position rook_to = effects.rook_to;

                plan.address[0] = zobrist_tile_addr(end_tile, to_pos);
                plan.enable[0] = (end_tile.piece_type != NULL_PIECE);
                plan.address[1] = zobrist_tile_addr(restored_mover, from_pos);
                plan.enable[1] = (restored_mover.piece_type != NULL_PIECE);
                if (is_castle) begin
                    automatic Tile rook_tile = Tile'({moved_color, ROOK});
                    plan.address[2] = zobrist_tile_addr(rook_tile, rook_to);
                    plan.address[3] = zobrist_tile_addr(rook_tile, rook_from);
                    plan.enable[2] = 1'b1;
                    plan.enable[3] = 1'b1;
                end else if (is_ep) begin
                    automatic Tile ep_tile = Tile'({captured_color, PAWN});
                    plan.address[2] = zobrist_tile_addr(ep_tile, ep_capture_pos);
                    plan.enable[2] = 1'b1;
                end else begin
                    plan.address[2] = zobrist_tile_addr(restored_capture, to_pos);
                    plan.enable[2] = (restored_capture.piece_type != NULL_PIECE);
                end
                plan_side_delta(in.board, moved_color, rec.castle_perms, rec.has_ep, rec.ep_file);
            end

            BOARD_SET_TILE_OP: begin
                automatic Position to_pos = in.move.to_pos;
                automatic Tile old_tile = in.board.tiles[to_pos];
                automatic Tile new_tile = Tile'(in.set_data[3:0]);
                plan.address[0] = zobrist_tile_addr(old_tile, to_pos);
                plan.address[1] = zobrist_tile_addr(new_tile, to_pos);
                plan.enable[0] = (old_tile.piece_type != NULL_PIECE);
                plan.enable[1] = (new_tile.piece_type != NULL_PIECE);
            end
            BOARD_SET_TURN_OP:
                plan_side_delta(in.board, Color'(in.set_data[0]), in.board.castle_perms, in.board.has_ep, in.board.ep_file);
            BOARD_SET_CASTLE_PERMS_OP:
                plan_side_delta(in.board, in.board.turn, CastlePerms'(in.set_data[3:0]), in.board.has_ep, in.board.ep_file);
            BOARD_SET_EN_PASSANT_OP:
                plan_side_delta(in.board, in.board.turn, in.board.castle_perms, in.set_data[0], BoardFile'(in.set_data[3:1]));
            default: begin end
        endcase
        zobrist_read_plan = plan;
    end

    // Form all PST reads one stage before board mutation. Two replicated
    // true-dual-port ROMs supply the four values needed by castling without
    // changing the external pipeline latency.
    always_comb begin
        automatic BoardUpdatePipelineCtx in = ctx_pipe[0];
        automatic PstReadPlan plan = PstReadPlan'(0);

        case (in.board_op)
            BOARD_PUSH_MOVE_OP, BOARD_COMMIT_MOVE_OP: begin
                automatic MoveEffects effects = move_effects;
                automatic Position from_pos = effects.from_pos;
                automatic Position to_pos = effects.to_pos;
                automatic Tile start_tile = effects.start_tile;
                automatic Tile end_tile = effects.end_tile;
                automatic Color moved_color = start_tile.piece_color;
                automatic Color captured_color = Color'(~moved_color);
                automatic logic is_castle = effects.is_castle;
                automatic logic is_ep = effects.is_ep;
                automatic Tile placed_tile = effects.placed_tile;
                automatic Position ep_capture_pos = effects.ep_capture_pos;
                automatic Position rook_from = effects.rook_from;
                automatic Position rook_to = effects.rook_to;
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
                automatic MoveEffects effects = move_effects;
                automatic Position from_pos = effects.from_pos;
                automatic Position to_pos = effects.to_pos;
                automatic Color moved_color = Color'(~in.board.turn);
                automatic Color captured_color = in.board.turn;
                automatic Tile end_tile = effects.end_tile;
                automatic logic is_ep = effects.is_ep;
                automatic logic is_castle = effects.is_castle;
                automatic Tile restored_mover = effects.restored_mover;
                automatic Tile restored_capture = effects.restored_capture;
                automatic Position ep_capture_pos = effects.ep_capture_pos;
                automatic Position rook_from = effects.rook_from;
                automatic Position rook_to = effects.rook_to;

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
        automatic BoardUpdatePipelineCtx in = ctx_pipe[1];
        automatic BoardUpdatePipelineCtx out = in;

        for (int port_idx = 0; port_idx < ZOBRIST_TILE_READ_PORTS; port_idx++) begin
            if (zobrist_read_enable_q[port_idx])
                out.zobrist_key ^= zobrist_read_data[port_idx];
        end
        if (zobrist_turn_toggle_q)
            out.zobrist_key ^= ZOBRIST_TURN_VALUE;
        if (zobrist_castle_toggle_q.white_kingside)
            out.zobrist_key ^= ZOBRIST_WHITE_KINGSIDE_VALUE;
        if (zobrist_castle_toggle_q.white_queenside)
            out.zobrist_key ^= ZOBRIST_WHITE_QUEENSIDE_VALUE;
        if (zobrist_castle_toggle_q.black_kingside)
            out.zobrist_key ^= ZOBRIST_BLACK_KINGSIDE_VALUE;
        if (zobrist_castle_toggle_q.black_queenside)
            out.zobrist_key ^= ZOBRIST_BLACK_QUEENSIDE_VALUE;
        if (zobrist_old_ep_enable_q)
            out.zobrist_key ^= zobrist_old_ep_data;
        if (zobrist_new_ep_enable_q)
            out.zobrist_key ^= zobrist_new_ep_data;

        case (in.board_op)
            BOARD_PUSH_MOVE_OP, BOARD_COMMIT_MOVE_OP: begin
                automatic MoveEffects effects = move_effects_q;
                automatic Position from_pos = effects.from_pos;
                automatic Position to_pos = effects.to_pos;
                automatic Tile start_tile = effects.start_tile;
                automatic Tile end_tile = effects.end_tile;
                automatic Color moved_color = start_tile.piece_color;
                automatic logic is_promo = effects.is_promo;
                automatic logic is_castle = effects.is_castle;
                automatic logic is_ep = effects.is_ep;
                automatic Tile placed_tile = effects.placed_tile;
                automatic Position ep_capture_pos = effects.ep_capture_pos;
                automatic Position rook_from = effects.rook_from;
                automatic Position rook_to = effects.rook_to;
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
                automatic MoveEffects effects = move_effects_q;
                automatic Position from_pos = effects.from_pos;
                automatic Position to_pos = effects.to_pos;
                automatic Color moved_color = Color'(~in.board.turn);
                automatic Color captured_color = in.board.turn;
                automatic logic is_ep = effects.is_ep;
                automatic logic is_castle = effects.is_castle;
                automatic Tile restored_mover = effects.restored_mover;
                automatic Tile restored_capture = effects.restored_capture;
                automatic Position ep_capture_pos = effects.ep_capture_pos;
                automatic Position rook_from = effects.rook_from;
                automatic Position rook_to = effects.rook_to;

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

        move_record_in = out.move_record;
        move_record_wr_en = (out.board_op == BOARD_PUSH_MOVE_OP);
        move_record_wr_addr = move_hist_addr(out.thread_id, out.search_ply);
        next_board_out = out.board;
        next_zobrist_key_out = out.zobrist_key;
        next_pst_eval_out = out.pst_eval;
    end

endmodule : board_update_pipeline
