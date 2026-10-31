// By Emet Behrendt

import chess_defs::*;
import chess_helpers::*;
import board_update_pipeline_defs::*;
import zobrist_defs::*;
import zobrist_hash_pkg::*;

module board_update_pipeline #(
    parameter int MOVE_RECORD_THREAD_COUNT = THREAD_COUNT,
    parameter int MOVE_RECORD_PLY_COUNT = MAX_PLY_COUNT
) (
    input wire clk,
    input BoardOp board_op,
    input FullBoard board_in,
    input ZobristKey zobrist_key_in,
    input PstEvalPair pst_eval_in,
    input PieceCount piece_count_in,
    input Move move_in,
    input logic [6:0] set_data,
    input ThreadID thread_id,
    input PlyIndex search_ply,

    output FullBoard board_out,
    output ZobristKey zobrist_key_out,
    output PstEvalPair pst_eval_out,
    output PieceCount piece_count_out,
    output logic mover_in_check_out,
    output logic side_in_check_out
);

    typedef logic [8:0] PstAddr;
    typedef logic [2:0] PstPieceIndex;
    localparam int PST_ENTRY_COUNT = 6 * 64;
    localparam PST_MEM_INIT_FILE = rtl_config::PST_VALUES_FILE;
    localparam PST_ENDGAME_MEM_INIT_FILE = rtl_config::PST_VALUES_ENDGAME_FILE;
    localparam int PST_READ_PORTS = 4;
    localparam int ZOBRIST_DELTA_LANES = 4;

    typedef struct packed {
        logic [PST_READ_PORTS-1:0] enable;
        PstAddr [PST_READ_PORTS-1:0] address;
    } PstReadPlan;

    typedef struct packed {
        logic [ZOBRIST_DELTA_LANES-1:0] enable;
        ZobristFeature [ZOBRIST_DELTA_LANES-1:0] feature;
    } ZobristHashPlan;

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
    BoardUpdatePipelineCtx captured_ctx;
    FullBoard next_board_out;
    ZobristKey next_zobrist_key_out;
    PstEvalPair next_pst_eval_out;
    PieceCount next_piece_count_out;

    MoveRecord move_record_in, move_record_out;
    MoveRecordAddr move_record_rd_addr, move_record_wr_addr;
    logic move_record_rd_en, move_record_wr_en;

    sync_read_simple_dual_port_ram #(
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

    // The request-capture edge also reads history RAM. Its synchronous result
    // feeds the existing table-planning stage without adding a pipeline cycle.
    always_comb begin
        captured_ctx = ctx_pipe[0];
        captured_ctx.move_record = move_record_out;
    end

    PstReadPlan pst_read_plan;
    logic [PST_READ_PORTS-1:0] pst_read_enable_q;
    PstScore pst_read_data[PST_READ_PORTS];
    PstScore pst_endgame_read_data[PST_READ_PORTS];
    Tile pst_lane_tile[PST_READ_PORTS];
    logic [PST_READ_PORTS-1:0] pst_lane_remove;
    PstEvalScore pst_first_delta[PST_READ_PORTS];
    PstEvalScore pst_endgame_delta[PST_READ_PORTS];
    ZobristHashPlan zobrist_hash_plan;
    logic [ZOBRIST_DELTA_LANES-1:0] zobrist_hash_enable_q;
    ZobristKey zobrist_lane_keys[ZOBRIST_DELTA_LANES];
    logic zobrist_turn_toggle, zobrist_turn_toggle_q;
    CastlingRights zobrist_castle_toggle, zobrist_castle_toggle_q;
    logic zobrist_old_ep_valid, zobrist_new_ep_valid;
    logic zobrist_old_ep_valid_q, zobrist_new_ep_valid_q;
    BoardFile zobrist_old_ep_address, zobrist_new_ep_address;
    ZobristKey zobrist_old_ep_data, zobrist_new_ep_data;
    MoveEffects move_effects, move_effects_q;
    logic [63:0] check_empty_mask_d, check_empty_mask_q;
    logic [63:0] check_mover_mask_d, check_mover_mask_q;
    logic [63:0] check_rook_mask_d, check_rook_mask_q;
    Tile check_mover_tile_d, check_mover_tile_q;
    Color check_mover_color_d, check_mover_color_q;
    FullBoard check_board;

    // All operations share four square-write lanes: mover, destination, and
    // the two auxiliary squares needed by castling (one for en passant).
    logic [3:0] tile_write_enable;
    Position [3:0] tile_write_position;
    Tile [3:0] tile_write_data;

    // Compute feature keys in logic and register each enabled result. The
    // fourth delta lane selects a constant rook delta for castling.
    always_ff @(posedge clk) begin
        for (int port_index = 0; port_index < ZOBRIST_DELTA_LANES - 1; port_index++) begin
            if (zobrist_hash_plan.enable[port_index])
                zobrist_lane_keys[port_index] <= zobrist_feature_key(zobrist_hash_plan.feature[port_index]);
        end
        // Castling's rook XOR delta is one of four constants, and is the same
        // for push and reversal. The capture lane stays idle during castling.
        if (zobrist_hash_plan.enable[3])
            zobrist_lane_keys[3] <= zobrist_castle_rook_delta({
                zobrist_hash_plan.feature[3][9], zobrist_hash_plan.feature[3][2]});
        if (zobrist_old_ep_valid)
            zobrist_old_ep_data <= zobrist_ep_key(zobrist_old_ep_address);
        if (zobrist_new_ep_valid)
            zobrist_new_ep_data <= zobrist_ep_key(zobrist_new_ep_address);
    end

    genvar port_pair;
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
            sync_read_dual_port_rom #(
                .NUM_WORDS(PST_ENTRY_COUNT),
                .WORD_SIZE($bits(PstScore)),
                .MEM_INIT_FILE(PST_ENDGAME_MEM_INIT_FILE)
            ) pst_endgame_rom (
                .clock(clk),
                .address_a(pst_read_plan.address[port_pair * 2]),
                .address_b(pst_read_plan.address[port_pair * 2 + 1]),
                .rden_a(pst_read_plan.enable[port_pair * 2]),
                .rden_b(pst_read_plan.enable[port_pair * 2 + 1]),
                .q_a(pst_endgame_read_data[port_pair * 2]),
                .q_b(pst_endgame_read_data[port_pair * 2 + 1])
            );
        end
    endgenerate

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
        if (~valid_piece_type(piece)) begin
            return PstAddr'('x);
        end

        return {PstPieceIndex'(piece) - PstPieceIndex'(1), pos};
    endfunction : pst_addr

    function automatic PieceType promo_to_piece(input PromoType promo);
        // Promotion encodings select exactly one resulting piece.
        unique case (promo)
            PROMO_QUEEN:  return QUEEN;
            PROMO_KNIGHT: return KNIGHT;
            PROMO_ROOK:   return ROOK;
            PROMO_BISHOP: return BISHOP;
            default:      return PieceType'('x);
        endcase
    endfunction : promo_to_piece

    function automatic Position castle_rook_from(input Position king_to);
        // The four standard castling destinations are distinct squares.
        unique case (king_to)
            Position'('d2):  return Position'('d0);
            Position'('d6):  return Position'('d7);
            Position'('d58): return Position'('d56);
            Position'('d62): return Position'('d63);
            default:         return Position'('dx);
        endcase
    endfunction : castle_rook_from

    function automatic Position castle_rook_to(input Position king_to);
        // The four standard castling destinations are distinct squares.
        unique case (king_to)
            Position'('d2):  return Position'('d3);
            Position'('d6):  return Position'('d5);
            Position'('d58): return Position'('d59);
            Position'('d62): return Position'('d61);
            default:         return Position'('dx);
        endcase
    endfunction : castle_rook_to

    // Fold removal into color before negation, sharing one signed score path
    // per ROM lane for push, reverse, and setup operations.
    function automatic PstEvalScore pst_lane_score(
        input Tile tile,
        input logic remove_piece,
        input EvalScore material,
        input PstScore pst_value
    );
        PstEvalScore score;
        if (tile.piece_type == NULL_PIECE) return '0;
        score = PstEvalScore'(material) + PstEvalScore'(pst_value);
        return (tile.piece_color == BLACK) ^ remove_piece ? -score : score;
    endfunction

    // Each lane describes one added or removed piece. Castling and en passant
    // share the capture lane because those move effects are mutually exclusive.
    always_comb begin
        for (int lane = 0; lane < PST_READ_PORTS; lane++)
            pst_lane_tile[lane] = EMPTY_TILE;
        pst_lane_remove = '0;
        case (ctx_pipe[1].board_op)
            BOARD_PUSH_MOVE_OP, BOARD_COMMIT_MOVE_OP: begin
                pst_lane_tile[0] = move_effects_q.moving_tile;
                pst_lane_tile[1] = move_effects_q.placed_tile;
                pst_lane_tile[2] = move_effects_q.is_castle
                    ? Tile'({move_effects_q.moving_tile.piece_color, ROOK})
                    : move_effects_q.is_ep
                        ? Tile'({Color'(~move_effects_q.moving_tile.piece_color), PAWN})
                        : move_effects_q.destination_tile;
                pst_lane_tile[3] = Tile'({move_effects_q.moving_tile.piece_color, ROOK});
                pst_lane_remove = 4'b0101;
            end
            BOARD_REVERSE_MOVE_OP: begin
                pst_lane_tile[0] = move_effects_q.restored_mover;
                pst_lane_tile[1] = move_effects_q.destination_tile;
                pst_lane_tile[2] = move_effects_q.is_castle
                    ? Tile'({Color'(~ctx_pipe[1].board.turn), ROOK})
                    : move_effects_q.is_ep
                        ? Tile'({ctx_pipe[1].board.turn, PAWN})
                        : move_effects_q.restored_capture;
                pst_lane_tile[3] = Tile'({Color'(~ctx_pipe[1].board.turn), ROOK});
                pst_lane_remove = 4'b1010;
            end
            BOARD_SET_TILE_OP: begin
                pst_lane_tile[1] = Tile'(ctx_pipe[1].set_data[3:0]);
                pst_lane_tile[2] = ctx_pipe[1].board.tiles[ctx_pipe[1].move.to_pos];
                pst_lane_remove = 4'b0100;
            end
            default: begin end
        endcase
        // Keep both phases scalar through the ROM-to-accumulator datapath;
        // Quartus can prune the first member of packed score-return helpers.
        for (int lane = 0; lane < PST_READ_PORTS; lane++) begin
            pst_first_delta[lane] = pst_read_enable_q[lane]
                ? pst_lane_score(pst_lane_tile[lane], pst_lane_remove[lane],
                    PIECE_VALS_128[pst_lane_tile[lane].piece_type], pst_read_data[lane]) : '0;
            pst_endgame_delta[lane] = pst_read_enable_q[lane]
                ? pst_lane_score(pst_lane_tile[lane], pst_lane_remove[lane],
                    PIECE_VALS_ENDGAME_128[pst_lane_tile[lane].piece_type], pst_endgame_read_data[lane]) : '0;
        end
    end

    // Apply registered move overlays once before both king-safety scans.
    always_comb begin
        check_board = ctx_pipe[1].board;
        for (int pos = 0; pos < 64; pos++) begin
            if (check_empty_mask_q[pos]) check_board.tiles[pos] = EMPTY_TILE;
            if (check_mover_mask_q[pos]) check_board.tiles[pos] = check_mover_tile_q;
            if (check_rook_mask_q[pos])
                check_board.tiles[pos] = Tile'({check_mover_color_q, ROOK});
        end
    end

    // Test independent attackers in parallel; each ray uses a prefix occupancy
    // reduction so no priority chain spans the directions or piece classes.
    function automatic logic board_square_attacked(
        input FullBoard board,
        input Position square,
        input Color attacker_color
    );
        automatic logic [65:0] attacks = '0;
        automatic Tile [63:0] relative_tiles = board.tiles;
        automatic Direction pawn_left = attacker_color == WHITE ? SOUTH_WEST : NORTH_WEST;
        automatic Direction pawn_right = attacker_color == WHITE ? SOUTH_EAST : NORTH_EAST;
        // Share one cyclic board rotation across every attack probe. Relative
        // offsets are constant for knights and rays, avoiding an independent
        // full-board tile multiplexer at each distance in each direction.
        for (int bit_index = 0; bit_index < $bits(Position); bit_index++) begin
            if (square[bit_index])
                relative_tiles = (relative_tiles >> ($bits(Tile) << bit_index))
                    | (relative_tiles << ($bits(board.tiles) - ($bits(Tile) << bit_index)));
        end
        attacks[0] = is_shift_on_board(square, pawn_left, 3'd1)
            && relative_tiles[shift_position(Position'('0), pawn_left, 3'd1)] == Tile'({attacker_color, PAWN});
        attacks[1] = is_shift_on_board(square, pawn_right, 3'd1)
            && relative_tiles[shift_position(Position'('0), pawn_right, 3'd1)] == Tile'({attacker_color, PAWN});
        for (int knight_dir = 0; knight_dir < 8; knight_dir++) begin
            attacks[2 + knight_dir] = is_knight_shift_on_board(square, KnightDirection'(knight_dir))
                && relative_tiles[shift_knight_position(Position'('0), KnightDirection'(knight_dir))]
                    == Tile'({attacker_color, KNIGHT});
        end
        for (int dir_idx = 0; dir_idx < 8; dir_idx++) begin
            automatic Direction dir = Direction'(dir_idx);
            automatic logic [6:0] occupied;
            automatic logic [6:0] attackers;
            for (int distance = 1; distance < 8; distance++) begin
                automatic Tile tile = relative_tiles[shift_position(Position'('0), dir, distance[2:0])];
                automatic logic on_board = is_shift_on_board(square, dir, distance[2:0]);
                occupied[distance - 1] = on_board && tile.piece_type != NULL_PIECE;
                attackers[distance - 1] = on_board && tile.piece_color == attacker_color
                    && ((distance == 1 && tile.piece_type == KING)
                        || is_line_attacker(tile.piece_type, dir));
            end
            for (int distance = 1; distance < 8; distance++) begin
                attacks[10 + dir_idx * 7 + distance - 1] = attackers[distance - 1]
                    && !(|(occupied & ((7'b1 << (distance - 1)) - 7'b1)));
            end
        end
        return |attacks;
    endfunction : board_square_attacked

    function automatic Position pushed_king_square(input FullBoard board, input Move move);
        if (board.tiles[move.from_pos].piece_type == KING)
            return move.to_pos;
        return king_position(board, board.turn);
    endfunction : pushed_king_square

    function automatic Color result_turn(input BoardUpdatePipelineCtx in);
        if (in.board_op == BOARD_PUSH_MOVE_OP || in.board_op == BOARD_COMMIT_MOVE_OP
                || in.board_op == BOARD_PUSH_NULL_OP || in.board_op == BOARD_REVERSE_MOVE_OP)
            return Color'(~in.board.turn);
        if (in.board_op == BOARD_SET_TURN_OP)
            return Color'(in.set_data[0]);
        return in.board.turn;
    endfunction : result_turn

    // Decode compact post-push effects once for table planning and board mutation.
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
            && get_file(effects.from_pos) != get_file(effects.to_pos)
            && effects.destination_tile.piece_type == NULL_PIECE;
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

    // Select a write lane; the common per-square mux applies the plan below.
    task automatic plan_tile_write(
        input int lane,
        input Position pos,
        input Tile tile
    );
        tile_write_enable[lane] = 1'b1;
        tile_write_position[lane] = pos;
        tile_write_data[lane] = tile;
    endtask : plan_tile_write

    // Reversible moves must not wrap an expired draw clock back to zero.
    function automatic HalfmoveClock increment_halfmove_clock(input HalfmoveClock clock_value);
        return (&clock_value) ? clock_value : clock_value + HalfmoveClock'(1);
    endfunction : increment_halfmove_clock

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
        automatic BoardUpdatePipelineCtx in = captured_ctx;
        automatic MoveEffects effects = MoveEffects'('x);

        effects.from_pos = in.move.from_pos;
        effects.to_pos = in.move.to_pos;

        // Board operation encodings are disjoint, including grouped move operations.
        unique case (in.board_op)
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
        mover_in_check_out <= ctx_pipe[1].board_op == BOARD_PUSH_MOVE_OP
            && board_square_attacked(
                check_board,
                ctx_pipe[1].mover_king_square,
                Color'(~ctx_pipe[1].board.turn)
            );
        side_in_check_out <= board_square_attacked(
            check_board,
            ctx_pipe[1].side_king_square,
            Color'(~result_turn(ctx_pipe[1]))
        );
        zobrist_hash_enable_q <= zobrist_hash_plan.enable;
        zobrist_turn_toggle_q <= zobrist_turn_toggle;
        zobrist_castle_toggle_q <= zobrist_castle_toggle;
        zobrist_old_ep_valid_q <= zobrist_old_ep_valid;
        zobrist_new_ep_valid_q <= zobrist_new_ep_valid;
        pst_read_enable_q <= pst_read_plan.enable;
        move_effects_q <= move_effects;
        check_empty_mask_q <= check_empty_mask_d;
        check_mover_mask_q <= check_mover_mask_d;
        check_rook_mask_q <= check_rook_mask_d;
        check_mover_tile_q <= check_mover_tile_d;
        check_mover_color_q <= check_mover_color_d;
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
        next_ctx_pipe[0].move_record = '0;
        next_ctx_pipe[0].mover_king_square = '0;
        next_ctx_pipe[0].side_king_square = '0;
        move_record_rd_addr = move_hist_addr(thread_id, search_ply - PlyIndex'('d1));
        move_record_rd_en = (board_op == BOARD_REVERSE_MOVE_OP);

    end

    always_comb begin
        next_ctx_pipe[1] = captured_ctx;
        // Select the checked king after capture, alongside mover-king decoding.
        // Turn-changing move operations exclude the explicit set-turn operation.
        unique case (1'b1)
            (captured_ctx.board_op == BOARD_PUSH_MOVE_OP || captured_ctx.board_op == BOARD_COMMIT_MOVE_OP
                    || captured_ctx.board_op == BOARD_PUSH_NULL_OP || captured_ctx.board_op == BOARD_REVERSE_MOVE_OP):
                next_ctx_pipe[1].side_king_square = captured_ctx.board.king_positions[Color'(~captured_ctx.board.turn)];
            (captured_ctx.board_op == BOARD_SET_TURN_OP):
                next_ctx_pipe[1].side_king_square = captured_ctx.board.king_positions[Color'(captured_ctx.set_data[0])];
            default:
                next_ctx_pipe[1].side_king_square = captured_ctx.board.king_positions[captured_ctx.board.turn];
        endcase
        // Decode the king destination after request capture so dispatch does
        // not feed a dynamic tile read before the first register boundary.
        next_ctx_pipe[1].mover_king_square = pushed_king_square(captured_ctx.board, captured_ctx.move);
    end

    // Decode the captured request into registered overlay masks during the
    // existing table-alignment stage. The following attack scan therefore has
    // registered inputs without increasing end-to-end pipeline latency.
    always_comb begin
        automatic BoardUpdatePipelineCtx in = captured_ctx;
        automatic MoveEffects check_effects = MoveEffects'('0);

        check_empty_mask_d = 64'd0;
        check_mover_mask_d = 64'd0;
        check_rook_mask_d = 64'd0;
        check_mover_tile_d = EMPTY_TILE;
        check_mover_color_d = in.board.turn;
        if (in.board_op == BOARD_PUSH_MOVE_OP || in.board_op == BOARD_COMMIT_MOVE_OP) begin
            check_effects = decode_push_effects(in.board, in.move);
            check_empty_mask_d[check_effects.from_pos] = 1'b1;
            check_mover_mask_d[check_effects.to_pos] = 1'b1;
            check_mover_tile_d = check_effects.placed_tile;
            check_mover_color_d = check_effects.moving_tile.piece_color;
            if (check_effects.is_ep)
                check_empty_mask_d[check_effects.ep_capture_pos] = 1'b1;
            if (check_effects.is_castle) begin
                check_empty_mask_d[check_effects.rook_from] = 1'b1;
                check_rook_mask_d[check_effects.rook_to] = 1'b1;
            end
        end else if (in.board_op == BOARD_SET_TILE_OP) begin
            check_mover_mask_d[in.move.to_pos] = 1'b1;
            check_mover_tile_d = Tile'(in.set_data[3:0]);
        end
    end

    // Form the incremental hash delta one stage before board mutation. The
    // registered hash outputs then align with the same request in ctx_pipe[1].
    always_comb begin
        automatic BoardUpdatePipelineCtx in = captured_ctx;
        automatic ZobristHashPlan plan = ZobristHashPlan'(0);

        zobrist_turn_toggle = 1'b0;
        zobrist_castle_toggle = CastlingRights'(0);
        zobrist_old_ep_valid = 1'b0;
        zobrist_new_ep_valid = 1'b0;
        zobrist_old_ep_address = BoardFile'(0);
        zobrist_new_ep_address = BoardFile'(0);

        // Board operation encodings are disjoint, including grouped move operations.
        unique case (in.board_op)
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
                automatic Position rook_to = effects.rook_to;
                automatic Tile captured_tile = is_ep ? Tile'({captured_color, PAWN}) : destination_tile;
                automatic CastlingRights next_castle = in.board.castling_rights;
                automatic logic next_has_ep;
                automatic BoardFile next_ep_file = get_file(to_pos);

                plan.feature[0] = zobrist_tile_feature(moving_tile, from_pos);
                plan.enable[0] = valid_piece_type(moving_tile.piece_type) ? 1'b1 : 1'bx;
                plan.feature[1] = zobrist_tile_feature(placed_tile, to_pos);
                plan.enable[1] = valid_piece_type(placed_tile.piece_type) ? 1'b1 : 1'bx;
                if (is_castle) begin
                    automatic Tile rook_tile = Tile'({moved_color, ROOK});
                    plan.feature[3] = zobrist_tile_feature(rook_tile, rook_to);
                    plan.enable[3] = 1'b1;
                end else begin
                    plan.feature[2] = zobrist_tile_feature(captured_tile, is_ep ? ep_capture_pos : to_pos);
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
                automatic Position rook_to = effects.rook_to;

                plan.feature[0] = zobrist_tile_feature(destination_tile, to_pos);
                plan.enable[0] = !is_null_record(rec) && (destination_tile.piece_type != NULL_PIECE);
                plan.feature[1] = zobrist_tile_feature(restored_mover, from_pos);
                plan.enable[1] = !is_null_record(rec) && (restored_mover.piece_type != NULL_PIECE);
                if (!is_null_record(rec) && is_castle) begin
                    automatic Tile rook_tile = Tile'({moved_color, ROOK});
                    plan.feature[3] = zobrist_tile_feature(rook_tile, rook_to);
                    plan.enable[3] = 1'b1;
                end else if (!is_null_record(rec) && is_ep) begin
                    automatic Tile ep_tile = Tile'({captured_color, PAWN});
                    plan.feature[2] = zobrist_tile_feature(ep_tile, ep_capture_pos);
                    plan.enable[2] = 1'b1;
                end else if (!is_null_record(rec)) begin
                    plan.feature[2] = zobrist_tile_feature(restored_capture, to_pos);
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
                plan.feature[0] = zobrist_tile_feature(old_tile, to_pos);
                plan.feature[1] = zobrist_tile_feature(new_tile, to_pos);
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
        zobrist_hash_plan = plan;
    end

    // Form all PST reads one stage before board mutation. Two replicated
    // true-dual-port ROMs supply the four values needed by castling without
    // changing the external pipeline latency.
    always_comb begin
        automatic BoardUpdatePipelineCtx in = captured_ctx;
        automatic PstReadPlan plan = PstReadPlan'(0);

        // Board operation encodings are disjoint, including grouped move operations.
        unique case (in.board_op)
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
                plan.enable[0] = valid_piece_type(moving_tile.piece_type) ? 1'b1 : 1'bx;
                plan.address[1] = pst_addr(placed_tile.piece_type, oriented_pos(placed_tile, to_pos));
                plan.enable[1] = valid_piece_type(placed_tile.piece_type) ? 1'b1 : 1'bx;
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
        ZobristKey tile_delta[ZOBRIST_DELTA_LANES];
        ZobristKey side_delta;
        ZobristKey old_ep_delta, new_ep_delta;

        for (int port_idx = 0; port_idx < ZOBRIST_DELTA_LANES; port_idx++) begin
            tile_delta[port_idx] = '0;
            if (zobrist_hash_enable_q[port_idx])
                tile_delta[port_idx] = zobrist_lane_keys[port_idx];
        end
        side_delta = '0;
        if (zobrist_turn_toggle_q)
            side_delta ^= ZOBRIST_TURN_BLACK_VALUE;
        if (zobrist_castle_toggle_q.white_kingside)
            side_delta ^= ZOBRIST_WHITE_KINGSIDE_VALUE;
        if (zobrist_castle_toggle_q.white_queenside)
            side_delta ^= ZOBRIST_WHITE_QUEENSIDE_VALUE;
        if (zobrist_castle_toggle_q.black_kingside)
            side_delta ^= ZOBRIST_BLACK_KINGSIDE_VALUE;
        if (zobrist_castle_toggle_q.black_queenside)
            side_delta ^= ZOBRIST_BLACK_QUEENSIDE_VALUE;
        old_ep_delta = '0;
        if (zobrist_old_ep_valid_q)
            old_ep_delta = zobrist_old_ep_data;
        new_ep_delta = '0;
        if (zobrist_new_ep_valid_q)
            new_ep_delta = zobrist_new_ep_data;

        // Balance the independent hash contributions within the existing
        // board-mutation stage instead of chaining each 64-bit XOR.
        out.zobrist_key = (in.zobrist_key ^ side_delta)
            ^ ((tile_delta[0] ^ tile_delta[1])
                ^ (tile_delta[2] ^ tile_delta[3]))
            ^ (old_ep_delta ^ new_ep_delta);

        tile_write_enable = '0;
        tile_write_position = '0;
        tile_write_data = '0;

        // Sum all four selected contributions with a balanced tree. Disabled
        // reads contribute zero, preserving side-only operations and null moves.
        out.pst_eval.first = in.pst_eval.first
            + ((pst_first_delta[0] + pst_first_delta[1])
                + (pst_first_delta[2] + pst_first_delta[3]));
        out.pst_eval.endgame = in.pst_eval.endgame
            + ((pst_endgame_delta[0] + pst_endgame_delta[1])
                + (pst_endgame_delta[2] + pst_endgame_delta[3]));

        // Preserve pass-through for unspecified operations; unique without default would make them don't-cares.
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
                plan_tile_write(0, from_pos, EMPTY_TILE);
                plan_tile_write(1, to_pos, placed_tile);

                if (is_ep) begin
                    plan_tile_write(2, ep_capture_pos, EMPTY_TILE);
                end

                if (is_castle) begin
                    automatic Tile rook_tile = Tile'({moved_color, ROOK});
                    plan_tile_write(2, rook_from, EMPTY_TILE);
                    plan_tile_write(3, rook_to, rook_tile);
                end
                // A legal move changes occupancy only when it captures;
                // castling moves its rook and promotion replaces its pawn.
                out.piece_count = in.piece_count - PieceCount'(
                    is_ep || destination_tile.piece_type != NULL_PIECE);

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
                next_halfmove = (is_ep || destination_tile.piece_type != NULL_PIECE || moving_tile.piece_type == PAWN)
                    ? HalfmoveClock'(0) : increment_halfmove_clock(in.board.halfmove_clock);
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
                if (!is_null_record(rec)) begin
                    plan_tile_write(0, from_pos, restored_mover);
                    plan_tile_write(1, to_pos, restored_capture);

                    if (is_ep) begin
                        automatic Tile ep_tile = Tile'({captured_color, PAWN});
                        plan_tile_write(2, ep_capture_pos, ep_tile);
                    end

                    if (is_castle) begin
                        automatic Tile rook_tile = Tile'({moved_color, ROOK});
                        plan_tile_write(2, rook_to, EMPTY_TILE);
                        plan_tile_write(3, rook_from, rook_tile);
                    end
                    // Reverse restores at most the one captured piece.
                    out.piece_count = in.piece_count + PieceCount'(
                        is_ep || restored_capture.piece_type != NULL_PIECE);
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
                    increment_halfmove_clock(in.board.halfmove_clock)
                );
            end

            BOARD_SET_TILE_OP: begin
                automatic Position to_pos = in.move.to_pos;
                automatic Tile new_tile = Tile'(in.set_data[3:0]);

                plan_tile_write(1, to_pos, new_tile);
                out.piece_count = in.piece_count
                    + PieceCount'(new_tile.piece_type != NULL_PIECE)
                    - PieceCount'(in.board.tiles[to_pos].piece_type != NULL_PIECE);
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

        // Decode each lane once per square, sharing the board mutation muxes
        // between push, reversal, and setup. Later lanes retain write priority.
        for (int pos = 0; pos < 64; pos++) begin
            for (int lane = 0; lane < 4; lane++) begin
                if (tile_write_enable[lane] && tile_write_position[lane] == Position'(pos))
                    out.board.tiles[pos] = tile_write_data[lane];
            end
        end
        // A king placement establishes the cached square; removing a king
        // during setup leaves its cache intact until the replacement arrives.
        for (int lane = 0; lane < 4; lane++) begin
            if (tile_write_enable[lane] && tile_write_data[lane].piece_type == KING)
                out.board.king_positions[tile_write_data[lane].piece_color] = tile_write_position[lane];
        end

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
