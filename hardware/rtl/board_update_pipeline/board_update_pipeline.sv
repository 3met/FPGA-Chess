// By Emet Behrendt

import chess_defs::*;
import chess_helpers::*;
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
    input PieceCount piece_count_in,
    input Move move_in,
    input logic [6:0] set_data,
    input ThreadID thread_id,
    input PlyIndex search_ply,

    output FullBoard board_out,
    output ZobristKey zobrist_key_out,
    output EvalScore pst_eval_out,
    output PieceCount piece_count_out,
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
        ZobristTileAddr [ZOBRIST_TILE_READ_PORTS-1:0] address;
    } ZobristReadPlan;

    typedef struct packed {
        Position from_pos;
        Position to_pos;
        Position ep_capture_pos;
        Position rook_from;
        Position rook_to;
        Tile moving_tile;
        Tile destination_tile;
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
    PieceCount next_piece_count_out;

    MoveRecord move_record_in, move_record_out;
    MoveRecordAddr move_record_rd_addr, move_record_wr_addr;
    logic move_record_rd_en, move_record_wr_en;

    async_read_simple_dual_port_ram #(
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
    EvalScore pst_source_out, pst_destination_out, pst_captured_out, pst_castle_out;
    ZobristReadPlan zobrist_read_plan;
    logic [ZOBRIST_TILE_READ_PORTS-1:0] zobrist_read_enable_q;
    ZobristKey zobrist_read_data[ZOBRIST_TILE_READ_PORTS];
    logic zobrist_turn_toggle, zobrist_turn_toggle_q;
    CastlingRights zobrist_castle_toggle, zobrist_castle_toggle_q;
    logic zobrist_old_ep_valid, zobrist_new_ep_valid;
    logic zobrist_old_ep_valid_q, zobrist_new_ep_valid_q;
    BoardFile zobrist_old_ep_address, zobrist_new_ep_address;
    ZobristKey zobrist_old_ep_data, zobrist_new_ep_data;
    MoveEffects move_effects, move_effects_q;
    MoveEffects check_move_effects_d, check_move_effects_q;
    logic [63:0] check_empty_mask;
    logic [63:0] check_mover_mask;
    logic [63:0] check_rook_mask;
    Tile check_mover_tile;
    Color check_mover_color;

    genvar port_pair;
    generate
        for (port_pair = 0; port_pair < ZOBRIST_TILE_READ_PORTS / 2; port_pair = port_pair + 1) begin : gen_zobrist_rom
            sync_read_dual_port_rom #(
                .NUM_WORDS(ZOBRIST_TILE_ENTRY_CNT),
                .WORD_SIZE($bits(ZobristKey)),
                .MEM_INIT_FILE(ZOBRIST_TILE_MEM_INIT_FILE)
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
    // replicated piece ROMs limits the tile table to the four move ports. The
    // separate eight-entry EP ROM supplies both side-state reads directly.
    sync_read_dual_port_rom #(
        .NUM_WORDS(ZOBRIST_EP_ENTRY_CNT),
        .WORD_SIZE($bits(ZobristKey)),
        .MEM_INIT_FILE(ZOBRIST_EP_MEM_INIT_FILE)
    ) zobrist_ep_rom (
        .clock(clk),
        .address_a(zobrist_old_ep_address),
        .address_b(zobrist_new_ep_address),
        .rden_a(zobrist_old_ep_valid),
        .rden_b(zobrist_new_ep_valid),
        .q_a(zobrist_old_ep_data),
        .q_b(zobrist_new_ep_data)
    );

    generate
        for (port_pair = 0; port_pair < PST_READ_PORTS / 2; port_pair = port_pair + 1) begin : gen_pst_rom
            sync_read_dual_port_rom #(
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
    assign pst_source_out = pst_read_enable_q[0] ? EvalScore'(pst_read_data[0]) : EvalScore'(0);
    assign pst_destination_out = pst_read_enable_q[1] ? EvalScore'(pst_read_data[1]) : EvalScore'(0);
    assign pst_captured_out = pst_read_enable_q[2] ? EvalScore'(pst_read_data[2]) : EvalScore'(0);
    assign pst_castle_out = pst_read_enable_q[3] ? EvalScore'(pst_read_data[3]) : EvalScore'(0);

    function automatic MoveRecordAddr move_hist_addr(input ThreadID tid, input PlyIndex ply);
        return MoveRecordAddr'(MoveRecordAddr'(tid) * MoveRecordAddr'(MOVE_RECORD_PLY_COUNT)
            + MoveRecordAddr'(ply));
    endfunction : move_hist_addr

    // Standard chess never moves a piece onto its origin square, so a
    // same-square record identifies a null move without widening history RAM.
    function automatic logic is_null_record(input MoveRecord rec);
        return rec.from_pos == rec.to_pos;
    endfunction : is_null_record

    function automatic Position oriented_pos(input Tile tile, input Position pos);
        return (tile.piece_color == BLACK) ? mirror_position(pos) : pos;
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

    // Overlay push masks decoded once from registered move effects instead of
    // repeating position comparisons in every pawn, knight, and ray lookup.
    function automatic Tile checked_tile(input FullBoard board, input Position pos);
        automatic Tile tile = board.tiles[pos];
        if (check_empty_mask[pos]) tile = EMPTY_TILE;
        if (check_mover_mask[pos]) tile = check_mover_tile;
        if (check_rook_mask[pos]) tile = Tile'({check_mover_color, ROOK});
        return tile;
    endfunction : checked_tile

    function automatic logic board_square_attacked(
        input FullBoard board,
        input Position square,
        input Color attacker_color
    );
        automatic Position test_pos;
        automatic Tile test_tile;

        if (attacker_color == WHITE) begin
            if (is_shift_on_board(square, SOUTH_WEST, 3'd1)
                    && checked_tile(board, shift_position(square, SOUTH_WEST, 3'd1)) == WHITE_PAWN) return 1'b1;
            if (is_shift_on_board(square, SOUTH_EAST, 3'd1)
                    && checked_tile(board, shift_position(square, SOUTH_EAST, 3'd1)) == WHITE_PAWN) return 1'b1;
        end else begin
            if (is_shift_on_board(square, NORTH_WEST, 3'd1)
                    && checked_tile(board, shift_position(square, NORTH_WEST, 3'd1)) == BLACK_PAWN) return 1'b1;
            if (is_shift_on_board(square, NORTH_EAST, 3'd1)
                    && checked_tile(board, shift_position(square, NORTH_EAST, 3'd1)) == BLACK_PAWN) return 1'b1;
        end

        for (int knight_dir = 0; knight_dir < 8; knight_dir++) begin
            if (is_knight_shift_on_board(square, KnightDirection'(knight_dir))) begin
                test_pos = shift_knight_position(square, KnightDirection'(knight_dir));
                if (checked_tile(board, test_pos) == Tile'({attacker_color, KNIGHT})) return 1'b1;
            end
        end

        for (int dir_idx = 0; dir_idx < 8; dir_idx++) begin
            automatic Direction dir = Direction'(dir_idx);
            for (int distance = 1; distance < 8; distance++) begin
                if (is_shift_on_board(square, dir, distance[2:0])) begin
                    test_pos = shift_position(square, dir, distance[2:0]);
                    test_tile = checked_tile(board, test_pos);
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
    endfunction : board_square_attacked

    function automatic Position pushed_king_square(input FullBoard board, input Move move);
        if (board.tiles[move.from_pos].piece_type == KING) begin
            return move.to_pos;
        end
        return king_position(board, board.turn);
    endfunction : pushed_king_square

    // Decode the compact post-push effects shared by board mutation and the
    // stage-1 king-safety overlay.
    function automatic MoveEffects decode_push_effects(input FullBoard board, input Move move);
        automatic MoveEffects effects = MoveEffects'('0);
        automatic Color moved_color;

        effects.from_pos = move.from_pos;
        effects.to_pos = move.to_pos;
        effects.moving_tile = board.tiles[effects.from_pos];
        effects.destination_tile = board.tiles[effects.to_pos];
        moved_color = effects.moving_tile.piece_color;
        effects.is_promo = effects.moving_tile.piece_type == PAWN
            && (get_rank(effects.to_pos) == BoardRank'('d0)
                || get_rank(effects.to_pos) == BoardRank'('d7));
        effects.is_castle = effects.moving_tile.piece_type == KING
            && get_file(effects.from_pos) == BoardFile'('d4)
            && (get_file(effects.to_pos) == BoardFile'('d2)
                || get_file(effects.to_pos) == BoardFile'('d6));
        effects.is_ep = effects.moving_tile.piece_type == PAWN
            && board.has_ep
            && board.ep_file == get_file(effects.to_pos)
            && effects.destination_tile.piece_type == NULL_PIECE
            && ((moved_color == WHITE && get_rank(effects.to_pos) == BoardRank'('d5))
                || (moved_color == BLACK && get_rank(effects.to_pos) == BoardRank'('d2)));
        effects.placed_tile = Tile'({
            moved_color,
            effects.is_promo
                ? promo_to_piece(move.promo_piece)
                : effects.moving_tile.piece_type
        });
        effects.ep_capture_pos = get_position(
            get_rank(effects.from_pos), get_file(effects.to_pos));
        effects.rook_from = castle_rook_from(effects.to_pos);
        effects.rook_to = castle_rook_to(effects.to_pos);
        return effects;
    endfunction : decode_push_effects

    task automatic plan_side_delta(
        input FullBoard old_board,
        input Color new_turn,
        input CastlingRights new_castle,
        input logic new_has_ep,
        input BoardFile new_ep_file
    );
        zobrist_turn_toggle = (old_board.turn != new_turn);
        zobrist_castle_toggle = old_board.castling_rights ^ new_castle;
        zobrist_old_ep_valid = old_board.has_ep;
        zobrist_new_ep_valid = new_has_ep;
        zobrist_old_ep_address = old_board.ep_file;
        zobrist_new_ep_address = new_ep_file;
    endtask : plan_side_delta

    task automatic replace_tile(
        inout FullBoard board,
        inout PieceCount piece_count,
        input Position pos,
        input Tile old_tile,
        input Tile new_tile
    );
        automatic Tile placed_tile = new_tile;

        if (old_tile.piece_type == NULL_PIECE && placed_tile.piece_type != NULL_PIECE)
            piece_count += PieceCount'(1);
        else if (old_tile.piece_type != NULL_PIECE && placed_tile.piece_type == NULL_PIECE)
            piece_count -= PieceCount'(1);
        board.tiles[pos] = placed_tile;
        // Legal positions contain one king per color, so placing a king also
        // establishes that color's canonical cached square.
        if (placed_tile.piece_type == KING)
            board.king_positions[placed_tile.piece_color] = pos;
    endtask : replace_tile

    task automatic replace_side_data(
        inout FullBoard board,
        input Color turn,
        input CastlingRights castling_rights,
        input logic has_ep,
        input BoardFile ep_file,
        input HalfmoveClock halfmove_clock
    );
        board.turn = turn;
        board.castling_rights = castling_rights;
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
                effects = decode_push_effects(in.board, in.move);
            end

            BOARD_REVERSE_MOVE_OP: begin
                automatic MoveRecord rec = in.move_record;
                automatic Color moved_color = Color'(~in.board.turn);
                automatic Color captured_color = in.board.turn;

                effects.from_pos = rec.from_pos;
                effects.to_pos = rec.to_pos;
                if (is_null_record(rec)) begin
                    effects.destination_tile = EMPTY_TILE;
                    effects.is_promo = 1'b0;
                    effects.is_ep = 1'b0;
                    effects.is_castle = 1'b0;
                    effects.restored_mover = EMPTY_TILE;
                    effects.restored_capture = EMPTY_TILE;
                    effects.ep_capture_pos = Position'(0);
                    effects.rook_from = Position'(0);
                    effects.rook_to = Position'(0);
                end else begin
                    effects.destination_tile = in.board.tiles[effects.to_pos];
                    effects.is_promo = (rec.move_flag == PROMO_MOVE);
                    effects.is_ep = (rec.move_flag == EP_MOVE);
                    effects.is_castle = (rec.move_flag == CASTLE_MOVE);
                    effects.restored_mover = Tile'({
                        moved_color,
                        effects.is_promo ? PAWN : effects.destination_tile.piece_type
                    });
                    effects.restored_capture = rec.captured_piece == NULL_PIECE
                        ? EMPTY_TILE
                        : Tile'({captured_color, rec.captured_piece});
                    effects.ep_capture_pos = get_position(
                        get_rank(effects.from_pos),
                        get_file(effects.to_pos)
                    );
                    effects.rook_from = castle_rook_from(effects.to_pos);
                    effects.rook_to = castle_rook_to(effects.to_pos);
                end
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
        piece_count_out <= next_piece_count_out;
        mover_in_check_out <= ctx_pipe[1].mover_in_check;
        zobrist_read_enable_q <= zobrist_read_plan.enable;
        zobrist_turn_toggle_q <= zobrist_turn_toggle;
        zobrist_castle_toggle_q <= zobrist_castle_toggle;
        zobrist_old_ep_valid_q <= zobrist_old_ep_valid;
        zobrist_new_ep_valid_q <= zobrist_new_ep_valid;
        pst_read_enable_q <= pst_read_plan.enable;
        move_effects_q <= move_effects;
        check_move_effects_q <= check_move_effects_d;
    end

    always_comb begin
        next_ctx_pipe[0].board_op    = board_op;
        next_ctx_pipe[0].board       = board_in;
        next_ctx_pipe[0].zobrist_key = zobrist_key_in;
        next_ctx_pipe[0].pst_eval    = pst_eval_in;
        next_ctx_pipe[0].piece_count = piece_count_in;
        next_ctx_pipe[0].move        = move_in;
        next_ctx_pipe[0].set_data    = set_data;
        next_ctx_pipe[0].thread_id   = thread_id;
        next_ctx_pipe[0].search_ply  = search_ply;
        next_ctx_pipe[0].move_record = move_record_out;
        // Select the tracked post-move king square before the attack scan.
        // The value is consumed only for a registered push operation. Decode
        // it unconditionally so operation arbitration does not gate its data.
        next_ctx_pipe[0].mover_king_square = pushed_king_square(board_in, move_in);
        next_ctx_pipe[0].mover_in_check = 1'b0;
        check_move_effects_d = MoveEffects'('0);
        if (board_op == BOARD_PUSH_MOVE_OP)
            check_move_effects_d = decode_push_effects(board_in, move_in);

        move_record_rd_addr = move_hist_addr(thread_id, search_ply - PlyIndex'('d1));
        move_record_rd_en = (board_op == BOARD_REVERSE_MOVE_OP);

    end

    always_comb begin
        next_ctx_pipe[1] = ctx_pipe[0];
        // Decode the post-move overlay from registered effects so thread
        // arbitration terminates at compact stage-0 registers rather than at
        // each bit of three one-hot masks.
        check_empty_mask = 64'd0;
        check_mover_mask = 64'd0;
        check_rook_mask = 64'd0;
        check_mover_tile = check_move_effects_q.placed_tile;
        check_mover_color = check_move_effects_q.moving_tile.piece_color;
        check_empty_mask[check_move_effects_q.from_pos] = 1'b1;
        check_mover_mask[check_move_effects_q.to_pos] = 1'b1;
        if (check_move_effects_q.is_ep)
            check_empty_mask[check_move_effects_q.ep_capture_pos] = 1'b1;
        if (check_move_effects_q.is_castle) begin
            check_empty_mask[check_move_effects_q.rook_from] = 1'b1;
            check_rook_mask[check_move_effects_q.rook_to] = 1'b1;
        end
        // King safety is evaluated in parallel with the synchronous table
        // reads and carried to the stage-2 board result without adding a cycle.
        next_ctx_pipe[1].mover_in_check = (ctx_pipe[0].board_op == BOARD_PUSH_MOVE_OP)
            ? board_square_attacked(ctx_pipe[0].board, ctx_pipe[0].mover_king_square,
                Color'(~ctx_pipe[0].board.turn))
            : 1'b0;
    end

    // Form the incremental hash delta one stage before board mutation. The
    // synchronous ROM outputs then align with the same request in ctx_pipe[1].
    always_comb begin
        automatic BoardUpdatePipelineCtx in = ctx_pipe[0];
        automatic ZobristReadPlan plan = ZobristReadPlan'(0);

        zobrist_turn_toggle = 1'b0;
        zobrist_castle_toggle = CastlingRights'(0);
        zobrist_old_ep_valid = 1'b0;
        zobrist_new_ep_valid = 1'b0;
        zobrist_old_ep_address = BoardFile'(0);
        zobrist_new_ep_address = BoardFile'(0);

        case (in.board_op)
            BOARD_PUSH_MOVE_OP, BOARD_COMMIT_MOVE_OP: begin
                automatic MoveEffects effects = move_effects;
                automatic Position from_pos = effects.from_pos;
                automatic Position to_pos = effects.to_pos;
                automatic Tile moving_tile = effects.moving_tile;
                automatic Tile destination_tile = effects.destination_tile;
                automatic Color moved_color = moving_tile.piece_color;
                automatic Color captured_color = Color'(~moved_color);
                automatic logic is_castle = effects.is_castle;
                automatic logic is_ep = effects.is_ep;
                automatic Tile placed_tile = effects.placed_tile;
                automatic Position ep_capture_pos = effects.ep_capture_pos;
                automatic Position rook_from = effects.rook_from;
                automatic Position rook_to = effects.rook_to;
                automatic Tile captured_tile = is_ep ? Tile'({captured_color, PAWN}) : destination_tile;
                automatic CastlingRights next_castle = in.board.castling_rights;
                automatic logic next_has_ep;
                automatic BoardFile next_ep_file = get_file(to_pos);

                plan.address[0] = zobrist_tile_addr(moving_tile, from_pos);
                plan.enable[0] = (moving_tile.piece_type != NULL_PIECE);
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
                next_has_ep = moving_tile.piece_type == PAWN
                    && ((moved_color == WHITE
                            && get_rank(from_pos) == BoardRank'(1)
                            && get_rank(to_pos) == BoardRank'(3))
                        || (moved_color == BLACK
                            && get_rank(from_pos) == BoardRank'(6)
                            && get_rank(to_pos) == BoardRank'(4)))
                    && has_ep_capturer(
                        in.board, Color'(~in.board.turn), next_ep_file);
                plan_side_delta(in.board, Color'(~in.board.turn), next_castle, next_has_ep, next_ep_file);
            end

            BOARD_REVERSE_MOVE_OP: begin
                automatic MoveRecord rec = in.move_record;
                automatic MoveEffects effects = move_effects;
                automatic Position from_pos = effects.from_pos;
                automatic Position to_pos = effects.to_pos;
                automatic Color moved_color = Color'(~in.board.turn);
                automatic Color captured_color = in.board.turn;
                automatic Tile destination_tile = effects.destination_tile;
                automatic logic is_ep = effects.is_ep;
                automatic logic is_castle = effects.is_castle;
                automatic Tile restored_mover = effects.restored_mover;
                automatic Tile restored_capture = effects.restored_capture;
                automatic Position ep_capture_pos = effects.ep_capture_pos;
                automatic Position rook_from = effects.rook_from;
                automatic Position rook_to = effects.rook_to;

                plan.address[0] = zobrist_tile_addr(destination_tile, to_pos);
                plan.enable[0] = !is_null_record(rec) && (destination_tile.piece_type != NULL_PIECE);
                plan.address[1] = zobrist_tile_addr(restored_mover, from_pos);
                plan.enable[1] = !is_null_record(rec) && (restored_mover.piece_type != NULL_PIECE);
                if (!is_null_record(rec) && is_castle) begin
                    automatic Tile rook_tile = Tile'({moved_color, ROOK});
                    plan.address[2] = zobrist_tile_addr(rook_tile, rook_to);
                    plan.address[3] = zobrist_tile_addr(rook_tile, rook_from);
                    plan.enable[2] = 1'b1;
                    plan.enable[3] = 1'b1;
                end else if (!is_null_record(rec) && is_ep) begin
                    automatic Tile ep_tile = Tile'({captured_color, PAWN});
                    plan.address[2] = zobrist_tile_addr(ep_tile, ep_capture_pos);
                    plan.enable[2] = 1'b1;
                end else if (!is_null_record(rec)) begin
                    plan.address[2] = zobrist_tile_addr(restored_capture, to_pos);
                    plan.enable[2] = (restored_capture.piece_type != NULL_PIECE);
                end
                plan_side_delta(in.board, moved_color, rec.castling_rights, rec.has_ep, rec.ep_file);
            end

            BOARD_PUSH_NULL_OP: begin
                plan_side_delta(
                    in.board,
                    Color'(~in.board.turn),
                    in.board.castling_rights,
                    1'b0,
                    in.board.ep_file
                );
            end

            BOARD_SET_TILE_OP: begin
                automatic Position to_pos = in.move.to_pos;
                automatic Tile old_tile = in.board.tiles[to_pos];
                automatic Tile new_tile = Tile'(in.set_data[3:0]);
                automatic FullBoard new_board = in.board;
                automatic logic new_has_ep;
                new_board.tiles[to_pos] = new_tile;
                new_has_ep = in.board.has_ep
                    && has_ep_capturer(
                        new_board, in.board.turn, in.board.ep_file);
                plan.address[0] = zobrist_tile_addr(old_tile, to_pos);
                plan.address[1] = zobrist_tile_addr(new_tile, to_pos);
                plan.enable[0] = (old_tile.piece_type != NULL_PIECE);
                plan.enable[1] = (new_tile.piece_type != NULL_PIECE);
                plan_side_delta(in.board, in.board.turn, in.board.castling_rights,
                    new_has_ep, in.board.ep_file);
            end
            BOARD_SET_TURN_OP: begin
                automatic Color new_turn = Color'(in.set_data[0]);
                automatic logic new_has_ep = in.board.has_ep
                    && has_ep_capturer(in.board, new_turn, in.board.ep_file);
                plan_side_delta(in.board, new_turn, in.board.castling_rights,
                    new_has_ep, in.board.ep_file);
            end
            BOARD_SET_CASTLING_RIGHTS_OP:
                plan_side_delta(in.board, in.board.turn, CastlingRights'(in.set_data[3:0]), in.board.has_ep, in.board.ep_file);
            BOARD_SET_EN_PASSANT_OP: begin
                automatic BoardFile new_ep_file = BoardFile'(in.set_data[3:1]);
                automatic logic new_has_ep = in.set_data[0]
                    && has_ep_capturer(in.board, in.board.turn, new_ep_file);
                plan_side_delta(in.board, in.board.turn, in.board.castling_rights,
                    new_has_ep, new_ep_file);
            end
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
                automatic Tile moving_tile = effects.moving_tile;
                automatic Tile destination_tile = effects.destination_tile;
                automatic Color moved_color = moving_tile.piece_color;
                automatic Color captured_color = Color'(~moved_color);
                automatic logic is_castle = effects.is_castle;
                automatic logic is_ep = effects.is_ep;
                automatic Tile placed_tile = effects.placed_tile;
                automatic Position ep_capture_pos = effects.ep_capture_pos;
                automatic Position rook_from = effects.rook_from;
                automatic Position rook_to = effects.rook_to;
                automatic Tile captured_tile = is_ep ? Tile'({captured_color, PAWN}) : destination_tile;

                plan.address[0] = pst_addr(moving_tile.piece_type, oriented_pos(moving_tile, from_pos));
                plan.enable[0] = (moving_tile.piece_type != NULL_PIECE);
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
                automatic Tile destination_tile = effects.destination_tile;
                automatic logic is_ep = effects.is_ep;
                automatic logic is_castle = effects.is_castle;
                automatic Tile restored_mover = effects.restored_mover;
                automatic Tile restored_capture = effects.restored_capture;
                automatic Position ep_capture_pos = effects.ep_capture_pos;
                automatic Position rook_from = effects.rook_from;
                automatic Position rook_to = effects.rook_to;

                plan.address[0] = pst_addr(restored_mover.piece_type, oriented_pos(restored_mover, from_pos));
                plan.enable[0] = !is_null_record(rec);
                plan.address[1] = pst_addr(destination_tile.piece_type, oriented_pos(destination_tile, to_pos));
                plan.enable[1] = !is_null_record(rec) && (destination_tile.piece_type != NULL_PIECE);
                if (!is_null_record(rec) && is_castle) begin
                    automatic Tile rook_tile = Tile'({moved_color, ROOK});
                    plan.address[2] = pst_addr(ROOK, oriented_pos(rook_tile, rook_from));
                    plan.address[3] = pst_addr(ROOK, oriented_pos(rook_tile, rook_to));
                    plan.enable[2] = 1'b1;
                    plan.enable[3] = 1'b1;
                end else if (!is_null_record(rec) && is_ep) begin
                    automatic Tile ep_tile = Tile'({captured_color, PAWN});
                    plan.address[2] = pst_addr(PAWN, oriented_pos(ep_tile, ep_capture_pos));
                    plan.enable[2] = 1'b1;
                end else if (!is_null_record(rec) && rec.captured_piece != NULL_PIECE) begin
                    plan.address[2] = pst_addr(rec.captured_piece, oriented_pos(restored_capture, to_pos));
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
            out.zobrist_key ^= ZOBRIST_TURN_BLACK_VALUE;
        if (zobrist_castle_toggle_q.white_kingside)
            out.zobrist_key ^= ZOBRIST_WHITE_KINGSIDE_VALUE;
        if (zobrist_castle_toggle_q.white_queenside)
            out.zobrist_key ^= ZOBRIST_WHITE_QUEENSIDE_VALUE;
        if (zobrist_castle_toggle_q.black_kingside)
            out.zobrist_key ^= ZOBRIST_BLACK_KINGSIDE_VALUE;
        if (zobrist_castle_toggle_q.black_queenside)
            out.zobrist_key ^= ZOBRIST_BLACK_QUEENSIDE_VALUE;
        if (zobrist_old_ep_valid_q)
            out.zobrist_key ^= zobrist_old_ep_data;
        if (zobrist_new_ep_valid_q)
            out.zobrist_key ^= zobrist_new_ep_data;

        case (in.board_op)
            BOARD_PUSH_MOVE_OP, BOARD_COMMIT_MOVE_OP: begin
                automatic MoveEffects effects = move_effects_q;
                automatic Position from_pos = effects.from_pos;
                automatic Position to_pos = effects.to_pos;
                automatic Tile moving_tile = effects.moving_tile;
                automatic Tile destination_tile = effects.destination_tile;
                automatic Color moved_color = moving_tile.piece_color;
                automatic logic is_promo = effects.is_promo;
                automatic logic is_castle = effects.is_castle;
                automatic logic is_ep = effects.is_ep;
                automatic Tile placed_tile = effects.placed_tile;
                automatic Position ep_capture_pos = effects.ep_capture_pos;
                automatic Position rook_from = effects.rook_from;
                automatic Position rook_to = effects.rook_to;
                automatic CastlingRights next_castle = in.board.castling_rights;
                automatic logic next_has_ep;
                automatic BoardFile next_ep_file = get_file(to_pos);
                automatic HalfmoveClock next_halfmove;
                automatic EvalScore mover_delta =
                    signed_piece_score(placed_tile, pst_destination_out)
                    - signed_piece_score(moving_tile, pst_source_out);
                automatic EvalScore capture_delta = (is_ep || is_castle)
                    ? EvalScore'(0) : -signed_piece_score(destination_tile, pst_captured_out);
                automatic Tile auxiliary_tile = is_ep
                    ? Tile'({Color'(~moved_color), PAWN})
                    : Tile'({moved_color, ROOK});
                automatic EvalScore auxiliary_remove_delta = (is_ep || is_castle)
                    ? -signed_piece_score(auxiliary_tile, pst_captured_out)
                    : EvalScore'(0);
                automatic EvalScore rook_place_delta = is_castle
                    ? signed_piece_score(Tile'({moved_color, ROOK}), pst_castle_out)
                    : EvalScore'(0);

                // Balance the independent tile-score deltas so a synchronous
                // PST ROM output crosses two adders rather than a serial task chain.
                out.pst_eval = in.pst_eval
                    + EvalScore'(mover_delta + capture_delta)
                    + EvalScore'(auxiliary_remove_delta + rook_place_delta);

                replace_tile(out.board, out.piece_count,
                    from_pos, moving_tile, EMPTY_TILE);
                replace_tile(out.board, out.piece_count,
                    to_pos, destination_tile, placed_tile);

                if (is_ep) begin
                    replace_tile(out.board, out.piece_count,
                        ep_capture_pos, Tile'({Color'(~moved_color), PAWN}), EMPTY_TILE);
                end

                if (is_castle) begin
                    automatic Tile rook_tile = Tile'({moved_color, ROOK});
                    replace_tile(out.board, out.piece_count,
                        rook_from, rook_tile, EMPTY_TILE);
                    replace_tile(out.board, out.piece_count,
                        rook_to, EMPTY_TILE, rook_tile);
                end

                out.move_record.from_pos = from_pos;
                out.move_record.to_pos = to_pos;
                out.move_record.captured_piece = is_ep ? NULL_PIECE : destination_tile.piece_type;
                out.move_record.castling_rights = in.board.castling_rights;
                out.move_record.move_flag = is_promo ? PROMO_MOVE : is_castle ? CASTLE_MOVE : is_ep ? EP_MOVE : NORM_MOVE;
                out.move_record.has_ep = in.board.has_ep;
                out.move_record.ep_file = in.board.ep_file;
                out.move_record.halfmove_clock = in.board.halfmove_clock;

                if (from_pos == Position'('d4)  || from_pos == Position'('d7)  || to_pos == Position'('d7))  next_castle.white_kingside = 1'b0;
                if (from_pos == Position'('d4)  || from_pos == Position'('d0)  || to_pos == Position'('d0))  next_castle.white_queenside = 1'b0;
                if (from_pos == Position'('d60) || from_pos == Position'('d63) || to_pos == Position'('d63)) next_castle.black_kingside = 1'b0;
                if (from_pos == Position'('d60) || from_pos == Position'('d56) || to_pos == Position'('d56)) next_castle.black_queenside = 1'b0;

                next_has_ep = zobrist_new_ep_valid_q;
                next_halfmove = (is_ep || destination_tile.piece_type != NULL_PIECE || moving_tile.piece_type == PAWN) ? HalfmoveClock'('d0) : in.board.halfmove_clock + HalfmoveClock'('d1);
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
                automatic EvalScore mover_delta =
                    signed_piece_score(restored_mover, pst_source_out);
                automatic EvalScore capture_delta =
                    signed_piece_score(restored_capture,
                        is_ep ? EvalScore'(0) : pst_captured_out)
                    - signed_piece_score(effects.destination_tile, pst_destination_out);
                automatic EvalScore ep_restore_delta = is_ep
                    ? signed_piece_score(Tile'({captured_color, PAWN}), pst_captured_out)
                    : EvalScore'(0);
                automatic EvalScore castle_rook_delta = is_castle
                    ? signed_piece_score(Tile'({moved_color, ROOK}), pst_captured_out)
                        - signed_piece_score(Tile'({moved_color, ROOK}), pst_castle_out)
                    : EvalScore'(0);

                if (!is_null_record(rec)) begin
                    out.pst_eval = in.pst_eval
                        + EvalScore'(mover_delta + capture_delta)
                        + EvalScore'(ep_restore_delta + castle_rook_delta);
                    replace_tile(out.board, out.piece_count,
                        from_pos, EMPTY_TILE, restored_mover);
                    replace_tile(out.board, out.piece_count,
                        to_pos, effects.destination_tile, restored_capture);

                    if (is_ep) begin
                        automatic Tile ep_tile = Tile'({captured_color, PAWN});
                        replace_tile(out.board, out.piece_count,
                            ep_capture_pos, EMPTY_TILE, ep_tile);
                    end

                    if (is_castle) begin
                        automatic Tile rook_tile = Tile'({moved_color, ROOK});
                        replace_tile(out.board, out.piece_count,
                            rook_to, rook_tile, EMPTY_TILE);
                        replace_tile(out.board, out.piece_count,
                            rook_from, EMPTY_TILE, rook_tile);
                    end
                end

                replace_side_data(out.board, moved_color, rec.castling_rights, rec.has_ep, rec.ep_file, rec.halfmove_clock);
                out.move_record = rec;
            end

            BOARD_PUSH_NULL_OP: begin
                out.move_record.from_pos = Position'(0);
                out.move_record.to_pos = Position'(0);
                out.move_record.captured_piece = NULL_PIECE;
                out.move_record.castling_rights = in.board.castling_rights;
                out.move_record.move_flag = NORM_MOVE;
                out.move_record.has_ep = in.board.has_ep;
                out.move_record.ep_file = in.board.ep_file;
                out.move_record.halfmove_clock = in.board.halfmove_clock;
                replace_side_data(
                    out.board,
                    Color'(~in.board.turn),
                    in.board.castling_rights,
                    1'b0,
                    in.board.ep_file,
                    in.board.halfmove_clock + HalfmoveClock'(1)
                );
            end

            BOARD_SET_TILE_OP: begin
                automatic Position to_pos = in.move.to_pos;
                automatic Tile new_tile = Tile'(in.set_data[3:0]);

                out.pst_eval = in.pst_eval
                    + signed_piece_score(new_tile, pst_destination_out)
                    - signed_piece_score(in.board.tiles[to_pos], pst_captured_out);
                replace_tile(out.board, out.piece_count,
                    to_pos, in.board.tiles[to_pos], new_tile);
                out.board.has_ep = zobrist_new_ep_valid_q;
            end

            BOARD_SET_TURN_OP: begin
                automatic Color new_turn = Color'(in.set_data[0]);
                replace_side_data(out.board, new_turn, in.board.castling_rights,
                    zobrist_new_ep_valid_q, in.board.ep_file, in.board.halfmove_clock);
            end

            BOARD_SET_CASTLING_RIGHTS_OP: begin
                replace_side_data(out.board, in.board.turn, CastlingRights'(in.set_data[3:0]), in.board.has_ep, in.board.ep_file, in.board.halfmove_clock);
            end

            BOARD_SET_EN_PASSANT_OP: begin
                automatic BoardFile new_ep_file = BoardFile'(in.set_data[3:1]);
                replace_side_data(out.board, in.board.turn, in.board.castling_rights,
                    zobrist_new_ep_valid_q, new_ep_file, in.board.halfmove_clock);
            end

            BOARD_SET_HALFMOVE_CLOCK_OP: begin
                replace_side_data(out.board, in.board.turn, in.board.castling_rights, in.board.has_ep, in.board.ep_file, HalfmoveClock'(in.set_data));
            end

            BOARD_IDLE_OP: begin
                out = BoardUpdatePipelineCtx'('dx);
                out.board_op = in.board_op;
            end
        endcase

        move_record_in = out.move_record;
        move_record_wr_en = out.board_op == BOARD_PUSH_MOVE_OP
            || out.board_op == BOARD_PUSH_NULL_OP;
        move_record_wr_addr = move_hist_addr(out.thread_id, out.search_ply);
        next_board_out = out.board;
        next_zobrist_key_out = out.zobrist_key;
        next_pst_eval_out = out.pst_eval;
        next_piece_count_out = out.piece_count;
    end

endmodule : board_update_pipeline
