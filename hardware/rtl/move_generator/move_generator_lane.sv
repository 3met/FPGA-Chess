// One independently scheduled destination-centric generation lane.

import chess_defs::*;
import chess_helpers::*;
import move_generator_defs::*;

module move_generator_lane #(
    parameter int THREAD_COUNT = 1,
    parameter int BUCKET_0_CAPACITY = 512,
    parameter int BUCKET_1_CAPACITY = 512,
    parameter int BUCKET_2_CAPACITY = 1024,
    parameter int BUCKET_3_CAPACITY = 512,
    parameter int BUCKET_4_CAPACITY = 512,
    parameter int BUCKET_5_CAPACITY = 512,
    parameter int BUCKET_6_CAPACITY = 512,
    parameter int BUCKET_7_CAPACITY = 512,
    parameter MoveGenCommand GENERATION_COMMAND = MOVE_GEN_GENERATE_NOISY,
    parameter MoveBucketMask OWNED_BUCKETS =
        GOOD_NOISY_BUCKET_MASK | BAD_NOISY_BUCKET_MASK,
    parameter int HISTORY_REWARD_PER_DEPTH = 4,
    parameter int HISTORY_MAXIMUM_REWARD = 63,
    parameter int HISTORY_MALUS_DIVISOR = 2,
    parameter int QUIET_THRESHOLD_1 = 16,
    parameter int QUIET_THRESHOLD_2 = 64,
    parameter int QUIET_THRESHOLD_3 = 128,
    parameter int CASTLING_HISTORY_BONUS = 16,
    parameter bit ASSERT_ON_OVERFLOW = 1'b1,
    parameter bit ENABLE_STATS = 1'b0
) (
    input logic clk,
    input logic rst_n,
    input logic clear,
    input logic flush,
    output logic init_busy,

    input logic cmd_valid,
    output logic cmd_ready,
    input MoveGenCommand cmd,
    input ThreadID cmd_thread,
    input PlyIndex cmd_ply,
    input FullBoard cmd_board,
    input logic cmd_suppress_valid,
    input Move cmd_suppress_move,
    input MoveBucketTops cmd_bucket_tops,

    output logic cmd_resp_valid,
    output ThreadID cmd_resp_thread,
    output PlyIndex cmd_resp_ply,
    output logic cmd_resp_direct_valid,
    output Move cmd_resp_direct_move,
    output MoveBucketTops cmd_resp_bucket_tops,

    input logic pop_valid,
    output logic pop_ready,
    input ThreadID pop_thread,
    input PlyIndex pop_ply,
    input MoveBucketMask pop_eligible,
    input MoveBucketTops pop_current_tops,
    input MoveBucketTops pop_lower_tops,
    output logic pop_resp_valid,
    output ThreadID pop_resp_thread,
    output PlyIndex pop_resp_ply,
    output logic pop_resp_found,
    output Move pop_resp_move,
    output MoveBucketIndex pop_resp_bucket,
    output MoveBucketTop pop_resp_new_top,

    input logic history_update_valid,
    output logic history_update_ready,
    input Color history_update_color,
    input Position history_update_from,
    input Position history_update_to,
    input PlyIndex history_update_depth,
    input logic [11:0] history_update_failed0,
    input logic [11:0] history_update_failed1,
    input logic [11:0] history_update_failed2,
    input logic [1:0] history_update_failed_count,

    output logic overflow_sticky,
    output ThreadID overflow_thread,
    output MoveBucketIndex overflow_bucket,
    output logic [15:0] overflow_count,
    output logic [39:0] stat_noisy_count,
    output logic [39:0] stat_quiet_count,
    output logic [39:0] stat_destination_count,
    output logic [39:0] stat_candidate_count,
    output logic [39:0] stat_history_lookup_count,
    output logic [39:0] stat_generation_cycles,
    output logic [39:0] stat_bucket_count [MOVE_BUCKET_COUNT],
    output MoveBucketTop stat_bucket_high_water [MOVE_BUCKET_COUNT]
);

    typedef enum logic [3:0] {
        GEN_IDLE,
        GEN_DIRECT,
        GEN_SELECT_DEST,
        GEN_EXPAND_SOURCE,
        GEN_BUILD_CONTEXT,
        GEN_HISTORY_WAIT,
        GEN_CASTLE,
        GEN_FINISH
    } GeneratorState;

    function automatic MoveBucketTop bucket_capacity(input MoveBucketIndex bucket);
        case (bucket)
            0: return MoveBucketTop'(BUCKET_0_CAPACITY);
            1: return MoveBucketTop'(BUCKET_1_CAPACITY);
            2: return MoveBucketTop'(BUCKET_2_CAPACITY);
            3: return MoveBucketTop'(BUCKET_3_CAPACITY);
            4: return MoveBucketTop'(BUCKET_4_CAPACITY);
            5: return MoveBucketTop'(BUCKET_5_CAPACITY);
            6: return MoveBucketTop'(BUCKET_6_CAPACITY);
            default: return MoveBucketTop'(BUCKET_7_CAPACITY);
        endcase
    endfunction

    // Forward the top produced by a bucket write so a generation response can
    // accompany the final write instead of waiting another cycle.
    function automatic MoveBucketTops tops_after_candidate_write(
        input MoveBucketTops tops,
        input MoveBucketIndex selected
    );
        automatic MoveBucketTops result = tops;
        if (tops[selected] < bucket_capacity(selected))
            result[selected] = tops[selected] + MoveBucketTop'(1);
        return result;
    endfunction

    function automatic logic is_power_of_two(input int value);
        return value > 0 && (value & (value - 1)) == 0;
    endfunction

`ifndef SYNTHESIS
    initial begin
        if (THREAD_COUNT < 1 || THREAD_COUNT > chess_defs::THREAD_COUNT)
            $fatal(1, "move_generator THREAD_COUNT exceeds ThreadID capacity");
        if (!(QUIET_THRESHOLD_1 < QUIET_THRESHOLD_2
                && QUIET_THRESHOLD_2 < QUIET_THRESHOLD_3))
            $fatal(1, "quiet history thresholds must be strictly increasing");
        if (GENERATION_COMMAND != MOVE_GEN_GENERATE_NOISY
                && GENERATION_COMMAND != MOVE_GEN_GENERATE_QUIET)
            $fatal(1, "move-generator lane must be noisy or quiet");
        for (int bucket = 0; bucket < MOVE_BUCKET_COUNT; bucket++) begin
            if (!is_power_of_two(int'(bucket_capacity(MoveBucketIndex'(bucket))))
                    || int'(bucket_capacity(MoveBucketIndex'(bucket))) > (1 << (MOVE_BUCKET_TOP_BITS - 1)))
                $fatal(1, "move bucket capacities must be powers of two no larger than 1024");
        end
    end
`endif

    GeneratorState state;
    logic path_ready;
    ThreadID job_thread;
    PlyIndex job_ply;
    FullBoard job_board;
    logic job_suppress_valid;
    Move job_suppress_move;
    MoveBucketTops job_tops;
    logic [63:0] destination_mask;
    Position context_destination;
    Tile context_destination_tile;
    RayRecord context_ray[8];
    Tile context_knight[8];
    logic [15:0] source_mask;
    logic [3:0] source_select_index;
    Position selected_destination;
    Tile selected_destination_tile;
    RayRecord selected_context_ray[8];
    Tile selected_context_knight[8];
    logic [15:0] selected_source_mask;
    logic destination_examined_event;
    logic destination_with_source_event;
`ifdef FPGA_CHESS_PROFILE
    logic profile_candidate_event;
`endif
    logic castle_index;

    Move candidate_move;
    Tile candidate_attacker;
    Tile candidate_victim;
    logic candidate_is_capture;
    logic candidate_is_ep;
    logic candidate_is_promotion;
    logic candidate_is_castle;
    logic candidate_is_knight;
    logic candidate_see_good;
    Direction candidate_lane;
    logic [1:0] candidate_promo_counter;
    logic candidate_valid;
    logic candidate_slot_ready;
    logic candidate_finishes_write;

    logic source_valid;
    Move source_move;
    Tile source_attacker;
    Tile source_victim;
    logic source_is_capture;
    logic source_is_ep;
    logic source_is_promotion;
    logic source_is_knight;
    Direction source_lane;

    logic bucket_wr_en[MOVE_BUCKET_COUNT];
    Move bucket_wr_data;
    ThreadID bucket_wr_thread;
    MoveBucketTop bucket_wr_top;
    MoveBucketIndex bucket_wr_select;
    logic bucket_rd_en[MOVE_BUCKET_COUNT];
    ThreadID bucket_rd_thread;
    MoveBucketTop bucket_rd_top;
    Move bucket_q[MOVE_BUCKET_COUNT];

    logic pop_pending;
    logic pop_found_q;
    ThreadID pop_thread_q;
    PlyIndex pop_ply_q;
    MoveBucketIndex pop_bucket_q;
    MoveBucketTop pop_new_top_q;
    logic pop_select_found;
    MoveBucketIndex pop_select_bucket;
    MoveBucketTop pop_select_new_top;

    logic signed [8:0] history_score;
    logic generator_history_read;
    logic generator_history_read_early;
    logic generator_history_read_castle;
    Move castle_candidate_move;
    logic castle_candidate_pseudo_legal;
    logic castle_candidate_suppressed;

    // Generate distant destinations first so the per-bucket LIFO stores return
    // otherwise equally ranked moves toward the center before edge moves.
    localparam Position DESTINATION_ORDER[0:63] = '{
        Position'(0),  Position'(7),  Position'(56), Position'(63),
        Position'(1),  Position'(6),  Position'(8),  Position'(15),
        Position'(48), Position'(55), Position'(57), Position'(62),
        Position'(2),  Position'(5),  Position'(9),  Position'(14),
        Position'(16), Position'(23), Position'(40), Position'(47),
        Position'(49), Position'(54), Position'(58), Position'(61),
        Position'(3),  Position'(4),  Position'(10), Position'(13),
        Position'(17), Position'(22), Position'(24), Position'(31),
        Position'(32), Position'(39), Position'(41), Position'(46),
        Position'(50), Position'(53), Position'(59), Position'(60),
        Position'(11), Position'(12), Position'(18), Position'(21),
        Position'(25), Position'(30), Position'(33), Position'(38),
        Position'(42), Position'(45), Position'(51), Position'(52),
        Position'(19), Position'(20), Position'(26), Position'(29),
        Position'(34), Position'(37), Position'(43), Position'(44),
        Position'(27), Position'(28), Position'(35), Position'(36)
    };

    function automatic logic [2:0] first_set_lane(input logic [7:0] mask);
        for (int lane = 0; lane < 8; lane++)
            if (mask[lane]) return 3'(lane);
        return 3'd0;
    endfunction

    // Encode the fixed destination preference in two balanced eight-entry
    // levels instead of a timing-critical 64-entry priority chain.
    function automatic Position first_destination(input logic [63:0] mask);
        automatic logic [63:0] ordered_mask;
        automatic logic [7:0] group_mask;
        automatic logic [7:0] lane_mask;
        automatic logic [2:0] group_index;
        automatic logic [2:0] lane_index;
        automatic logic [5:0] order_index;
        for (int index = 0; index < 64; index++)
            ordered_mask[index] = mask[DESTINATION_ORDER[index]];
        for (int group = 0; group < 8; group++)
            group_mask[group] = |ordered_mask[group*8 +: 8];
        group_index = first_set_lane(group_mask);
        lane_mask = ordered_mask[int'(group_index)*8 +: 8];
        lane_index = first_set_lane(lane_mask);
        order_index = {group_index, lane_index};
        return DESTINATION_ORDER[order_index];
    endfunction

    // Avoid scheduling pawn-only noisy destinations that have no possible source.
    function automatic logic noisy_pawn_destination_has_source(
        input FullBoard board,
        input Position destination
    );
        if (get_rank(destination) == (board.turn == WHITE ? BoardRank'(7) : BoardRank'(0))) begin
            return is_shift_on_board(destination, board.turn == WHITE ? SOUTH : NORTH, 3'd1)
                && board.tiles[shift_position(destination, board.turn == WHITE ? SOUTH : NORTH, 3'd1)]
                    == Tile'({board.turn, PAWN});
        end
        if (board.has_ep && get_file(destination) == board.ep_file
                && get_rank(destination) == (board.turn == WHITE ? BoardRank'(5) : BoardRank'(2))) begin
            return (is_shift_on_board(destination, board.turn == WHITE ? SOUTH_WEST : NORTH_WEST, 3'd1)
                    && board.tiles[shift_position(destination,
                        board.turn == WHITE ? SOUTH_WEST : NORTH_WEST, 3'd1)]
                        == Tile'({board.turn, PAWN}))
                || (is_shift_on_board(destination, board.turn == WHITE ? SOUTH_EAST : NORTH_EAST, 3'd1)
                    && board.tiles[shift_position(destination,
                        board.turn == WHITE ? SOUTH_EAST : NORTH_EAST, 3'd1)]
                        == Tile'({board.turn, PAWN}));
        end
        return 1'b0;
    endfunction

    function automatic logic [63:0] generation_destination_mask(input FullBoard board);
        automatic logic [63:0] mask;
        mask = '0;
        for (int pos = 0; pos < 64; pos++) begin
            if (GENERATION_COMMAND == MOVE_GEN_GENERATE_NOISY) begin
                // Capturing a king is never a chess move; check detection
                // determines mate without presenting its square as a capture.
                if ((board.tiles[pos].piece_type != NULL_PIECE
                        && board.tiles[pos].piece_color != board.turn
                        && board.tiles[pos].piece_type != KING)
                        || (board.tiles[pos].piece_type == NULL_PIECE
                            && get_rank(Position'(pos))
                                == (board.turn == WHITE ? BoardRank'(7) : BoardRank'(0))
                            && noisy_pawn_destination_has_source(board, Position'(pos))))
                    mask[pos] = 1'b1;
            end else if (GENERATION_COMMAND == MOVE_GEN_GENERATE_QUIET
                    && board.tiles[pos].piece_type == NULL_PIECE) begin
                mask[pos] = 1'b1;
            end
        end
        if (GENERATION_COMMAND == MOVE_GEN_GENERATE_NOISY && board.has_ep) begin
            automatic Position ep_destination = Position'({
                board.turn == WHITE ? BoardRank'(5) : BoardRank'(2), board.ep_file
            });
            if (board.tiles[ep_destination].piece_type == NULL_PIECE
                    && noisy_pawn_destination_has_source(board, ep_destination))
                mask[ep_destination] = 1'b1;
        end
        return mask;
    endfunction

    function automatic logic [2:0] ray_max_distance(input Position pos, input Direction dir);
        automatic BoardRank rank = get_rank(pos);
        automatic BoardFile file = get_file(pos);
        case (dir)
            NORTH:      return 3'd7 - rank;
            NORTH_EAST: return ((3'd7 - rank) < (3'd7 - file))
                ? (3'd7 - rank) : (3'd7 - file);
            EAST:       return 3'd7 - file;
            SOUTH_EAST: return (rank < (3'd7 - file)) ? rank : (3'd7 - file);
            SOUTH:      return rank;
            SOUTH_WEST: return (rank < file) ? rank : file;
            WEST:       return file;
            default:    return ((3'd7 - rank) < file) ? (3'd7 - rank) : file;
        endcase
    endfunction

    // One shared nearest-occupant selector is evaluated for the active destination.
    function automatic RayRecord nearest_ray(
        input FullBoard board,
        input Position destination,
        input Direction dir
    );
        automatic RayRecord result;
        automatic Tile candidates[7];
        automatic logic [6:0] occupied;
        result = NULL_RAY;
        for (int index = 0; index < 7; index++) begin
            automatic logic on_ray = 3'(index + 1)
                <= ray_max_distance(destination, dir);
            automatic Position pos = shift_position(destination, dir, 3'(index + 1));
            candidates[index] = board.tiles[pos];
            occupied[index] = on_ray
                && candidates[index].piece_type != NULL_PIECE;
        end
        // A priority mux avoids carrying the selected tile through seven
        // dependent conditional assignments on long rays.
        casez (occupied)
            7'b??????1: begin result.tile = candidates[0]; result.distance = 3'd0; end
            7'b?????10: begin result.tile = candidates[1]; result.distance = 3'd1; end
            7'b????100: begin result.tile = candidates[2]; result.distance = 3'd2; end
            7'b???1000: begin result.tile = candidates[3]; result.distance = 3'd3; end
            7'b??10000: begin result.tile = candidates[4]; result.distance = 3'd4; end
            7'b?100000: begin result.tile = candidates[5]; result.distance = 3'd5; end
            7'b1000000: begin result.tile = candidates[6]; result.distance = 3'd6; end
            default: begin end
        endcase
        return result;
    endfunction

    function automatic logic line_path_clear(
        input FullBoard board,
        input Position from_pos,
        input Position to_pos
    );
        automatic BoardRank from_rank = get_rank(from_pos);
        automatic BoardFile from_file = get_file(from_pos);
        automatic BoardRank to_rank = get_rank(to_pos);
        automatic BoardFile to_file = get_file(to_pos);
        automatic logic signed [1:0] rank_step =
            (to_rank > from_rank) ? 2'sd1 : (to_rank < from_rank) ? -2'sd1 : 2'sd0;
        automatic logic signed [1:0] file_step =
            (to_file > from_file) ? 2'sd1 : (to_file < from_file) ? -2'sd1 : 2'sd0;
        automatic logic [2:0] distance = (to_rank == from_rank)
            ? ((to_file > from_file) ? to_file - from_file : from_file - to_file)
            : ((to_rank > from_rank) ? to_rank - from_rank : from_rank - to_rank);
        for (int step = 1; step < 8; step++) begin
            automatic logic signed [4:0] path_rank =
                $signed({1'b0, from_rank}) + rank_step * 4'(step);
            automatic logic signed [4:0] path_file =
                $signed({1'b0, from_file}) + file_step * 4'(step);
            automatic Position path_pos = Position'({path_rank[2:0], path_file[2:0]});
            if (step < distance
                    && board.tiles[path_pos].piece_type != NULL_PIECE)
                return 1'b0;
        end
        return 1'b1;
    endfunction

    // Standard chess has only four castling paths. Keeping their squares
    // constant lets synthesis remove the dynamic board-index muxes from the
    // direct-validation path without adding a pipeline stage.
    function automatic logic white_kingside_castle_pseudo_legal(input FullBoard board);
        automatic FullBoard transit_board = board;
        automatic FullBoard final_board = board;
        if (board.turn != WHITE || !board.castling_rights.white_kingside
                || board.tiles[4] != WHITE_KING || board.tiles[7] != WHITE_ROOK
                || board.tiles[5].piece_type != NULL_PIECE
                || board.tiles[6].piece_type != NULL_PIECE) return 1'b0;
        transit_board.tiles[4] = EMPTY_TILE;
        transit_board.tiles[5] = WHITE_KING;
        final_board.tiles[4] = EMPTY_TILE;
        final_board.tiles[7] = EMPTY_TILE;
        final_board.tiles[6] = WHITE_KING;
        final_board.tiles[5] = WHITE_ROOK;
        return !square_attacked(board, Position'(4), BLACK)
            && !square_attacked(transit_board, Position'(5), BLACK)
            && !square_attacked(final_board, Position'(6), BLACK);
    endfunction

    function automatic logic white_queenside_castle_pseudo_legal(input FullBoard board);
        automatic FullBoard transit_board = board;
        automatic FullBoard final_board = board;
        if (board.turn != WHITE || !board.castling_rights.white_queenside
                || board.tiles[4] != WHITE_KING || board.tiles[0] != WHITE_ROOK
                || board.tiles[1].piece_type != NULL_PIECE
                || board.tiles[2].piece_type != NULL_PIECE
                || board.tiles[3].piece_type != NULL_PIECE) return 1'b0;
        transit_board.tiles[4] = EMPTY_TILE;
        transit_board.tiles[3] = WHITE_KING;
        final_board.tiles[4] = EMPTY_TILE;
        final_board.tiles[0] = EMPTY_TILE;
        final_board.tiles[2] = WHITE_KING;
        final_board.tiles[3] = WHITE_ROOK;
        return !square_attacked(board, Position'(4), BLACK)
            && !square_attacked(transit_board, Position'(3), BLACK)
            && !square_attacked(final_board, Position'(2), BLACK);
    endfunction

    function automatic logic black_kingside_castle_pseudo_legal(input FullBoard board);
        automatic FullBoard transit_board = board;
        automatic FullBoard final_board = board;
        if (board.turn != BLACK || !board.castling_rights.black_kingside
                || board.tiles[60] != BLACK_KING || board.tiles[63] != BLACK_ROOK
                || board.tiles[61].piece_type != NULL_PIECE
                || board.tiles[62].piece_type != NULL_PIECE) return 1'b0;
        transit_board.tiles[60] = EMPTY_TILE;
        transit_board.tiles[61] = BLACK_KING;
        final_board.tiles[60] = EMPTY_TILE;
        final_board.tiles[63] = EMPTY_TILE;
        final_board.tiles[62] = BLACK_KING;
        final_board.tiles[61] = BLACK_ROOK;
        return !square_attacked(board, Position'(60), WHITE)
            && !square_attacked(transit_board, Position'(61), WHITE)
            && !square_attacked(final_board, Position'(62), WHITE);
    endfunction

    function automatic logic black_queenside_castle_pseudo_legal(input FullBoard board);
        automatic FullBoard transit_board = board;
        automatic FullBoard final_board = board;
        if (board.turn != BLACK || !board.castling_rights.black_queenside
                || board.tiles[60] != BLACK_KING || board.tiles[56] != BLACK_ROOK
                || board.tiles[57].piece_type != NULL_PIECE
                || board.tiles[58].piece_type != NULL_PIECE
                || board.tiles[59].piece_type != NULL_PIECE) return 1'b0;
        transit_board.tiles[60] = EMPTY_TILE;
        transit_board.tiles[59] = BLACK_KING;
        final_board.tiles[60] = EMPTY_TILE;
        final_board.tiles[56] = EMPTY_TILE;
        final_board.tiles[58] = BLACK_KING;
        final_board.tiles[59] = BLACK_ROOK;
        return !square_attacked(board, Position'(60), WHITE)
            && !square_attacked(transit_board, Position'(59), WHITE)
            && !square_attacked(final_board, Position'(58), WHITE);
    endfunction

    function automatic logic castle_pseudo_legal(input FullBoard board, input Move move);
        case ({move.from_pos, move.to_pos})
            {Position'(4), Position'(6)}: return white_kingside_castle_pseudo_legal(board);
            {Position'(4), Position'(2)}: return white_queenside_castle_pseudo_legal(board);
            {Position'(60), Position'(62)}: return black_kingside_castle_pseudo_legal(board);
            {Position'(60), Position'(58)}: return black_queenside_castle_pseudo_legal(board);
            default: return 1'b0;
        endcase
    endfunction

    // Direct moves use the same pseudo-legality contract as generated candidates.
    function automatic logic move_pseudo_legal(
        input FullBoard board,
        input Move move
    );
        automatic Tile source = board.tiles[move.from_pos];
        automatic Tile destination = board.tiles[move.to_pos];
        automatic BoardRank from_rank = get_rank(move.from_pos);
        automatic BoardFile from_file = get_file(move.from_pos);
        automatic BoardRank to_rank = get_rank(move.to_pos);
        automatic BoardFile to_file = get_file(move.to_pos);
        automatic logic signed [3:0] dr =
            $signed({1'b0, to_rank}) - $signed({1'b0, from_rank});
        automatic logic signed [3:0] df =
            $signed({1'b0, to_file}) - $signed({1'b0, from_file});
        automatic logic [2:0] abs_dr = dr[3] ? 3'(-dr) : 3'(dr);
        automatic logic [2:0] abs_df = df[3] ? 3'(-df) : 3'(df);
        if (move.from_pos == move.to_pos || source.piece_type == NULL_PIECE
                || source.piece_color != board.turn
                || (destination.piece_type != NULL_PIECE && destination.piece_color == board.turn))
            return 1'b0;
        case (source.piece_type)
            PAWN: begin
                if (board.turn == WHITE) begin
                    if (df == 0 && destination.piece_type == NULL_PIECE
                            && (dr == 1 || (dr == 2 && from_rank == 1
                                && board.tiles[Position'(move.from_pos + Position'(8))].piece_type == NULL_PIECE)))
                        return 1'b1;
                    if (dr == 1 && abs_df == 1
                            && ((destination.piece_type != NULL_PIECE && destination.piece_color == BLACK)
                                || (board.has_ep && to_rank == 3'd5 && to_file == board.ep_file
                                    && from_rank == 4)))
                        return 1'b1;
                end else begin
                    if (df == 0 && destination.piece_type == NULL_PIECE
                            && (dr == -1 || (dr == -2 && from_rank == 6
                                && board.tiles[Position'(move.from_pos - Position'(8))].piece_type == NULL_PIECE)))
                        return 1'b1;
                    if (dr == -1 && abs_df == 1
                            && ((destination.piece_type != NULL_PIECE && destination.piece_color == WHITE)
                                || (board.has_ep && to_rank == 3'd2 && to_file == board.ep_file
                                    && from_rank == 3)))
                        return 1'b1;
                end
                return 1'b0;
            end
            KNIGHT: return (abs_dr == 2 && abs_df == 1) || (abs_dr == 1 && abs_df == 2);
            BISHOP: return abs_dr == abs_df && line_path_clear(board, move.from_pos, move.to_pos);
            ROOK: return (dr == 0 || df == 0) && line_path_clear(board, move.from_pos, move.to_pos);
            QUEEN: return (dr == 0 || df == 0 || abs_dr == abs_df)
                && line_path_clear(board, move.from_pos, move.to_pos);
            KING: begin
                if (abs_dr <= 1 && abs_df <= 1) return 1'b1;
                return castle_pseudo_legal(board, move);
            end
            default: return 1'b0;
        endcase
    endfunction

    function automatic logic ray_piece_attacks(
        input Tile source,
        input Direction dir,
        input logic [2:0] distance
    );
        case (source.piece_type)
            PAWN: return distance == 0 && ((source.piece_color == WHITE
                    && (dir == SOUTH_WEST || dir == SOUTH_EAST))
                || (source.piece_color == BLACK
                    && (dir == NORTH_WEST || dir == NORTH_EAST)));
            BISHOP: return is_diagonal_direction(dir);
            ROOK: return is_cardinal_direction(dir);
            QUEEN: return 1'b1;
            KING: return distance == 0;
            default: return 1'b0;
        endcase
    endfunction

    function automatic logic [3:0] exchange_value(input PieceType piece);
        case (piece)
            PAWN: return 4'd1;
            KNIGHT, BISHOP: return 4'd3;
            ROOK: return 4'd5;
            QUEEN: return 4'd9;
            KING: return 4'd15;
            default: return 4'd0;
        endcase
    endfunction

    // Shared bounded SEE: victim, least visible recapturer, and one defender reply.
    function automatic logic see_nonnegative(
        input Tile attacker,
        input Tile victim_tile,
        input logic is_ep,
        input logic is_knight,
        input Direction lane
    );
        automatic PieceType victim = is_ep ? PAWN : victim_tile.piece_type;
        automatic logic [4:0] enemy_classes = '0;
        automatic logic friendly_defender = 1'b0;
        automatic logic [3:0] recapturer_value;
        if (exchange_value(attacker.piece_type) <= exchange_value(victim)) return 1'b1;
        for (int dir = 0; dir < 8; dir++) begin
            automatic Tile tile = context_ray[dir].tile;
            if (!(is_knight == 1'b0 && lane == Direction'(dir))
                    && tile.piece_type != NULL_PIECE
                    && ray_piece_attacks(tile, Direction'(dir), context_ray[dir].distance)) begin
                if (tile.piece_color == job_board.turn) friendly_defender = 1'b1;
                else begin
                    case (tile.piece_type)
                        PAWN: enemy_classes[0] = 1'b1;
                        KNIGHT, BISHOP: enemy_classes[1] = 1'b1;
                        ROOK: enemy_classes[2] = 1'b1;
                        QUEEN: enemy_classes[3] = 1'b1;
                        KING: enemy_classes[4] = 1'b1;
                        default: begin end
                    endcase
                end
            end
        end
        for (int dir = 0; dir < 8; dir++) begin
            automatic Tile tile = context_knight[dir];
            if (!(is_knight && lane == Direction'(dir))
                    && tile.piece_type == KNIGHT) begin
                if (tile.piece_color == job_board.turn) friendly_defender = 1'b1;
                else enemy_classes[1] = 1'b1;
            end
        end
        if (enemy_classes == '0) return 1'b1;
        if (!friendly_defender) return 1'b0;
        if (enemy_classes[0]) recapturer_value = 4'd1;
        else if (enemy_classes[1]) recapturer_value = 4'd3;
        else if (enemy_classes[2]) recapturer_value = 4'd5;
        else if (enemy_classes[3]) recapturer_value = 4'd9;
        else recapturer_value = 4'd15;
        return 5'(exchange_value(victim)) + 5'(recapturer_value)
            >= 5'(exchange_value(attacker.piece_type));
    endfunction

    function automatic MoveBucketIndex noisy_bucket();
        automatic PieceType victim = candidate_is_ep ? PAWN : candidate_victim.piece_type;
        if (candidate_is_promotion) begin
            return candidate_move.promo_piece == PROMO_QUEEN
                ? GOOD_NOISY_HIGH_BUCKET : GOOD_NOISY_LOW_BUCKET;
        end
        if (candidate_see_good) begin
            return victim == ROOK || victim == QUEEN || victim == KING
                ? GOOD_NOISY_HIGH_BUCKET : GOOD_NOISY_LOW_BUCKET;
        end
        return victim == ROOK || victim == QUEEN || victim == KING
            ? BAD_NOISY_HIGH_BUCKET : BAD_NOISY_LOW_BUCKET;
    endfunction

    function automatic MoveBucketIndex quiet_bucket(input logic signed [10:0] score);
        if (score >= QUIET_THRESHOLD_3) return QUIET_HIGHEST_BUCKET;
        if (score >= QUIET_THRESHOLD_2) return QUIET_HIGH_BUCKET;
        if (score >= QUIET_THRESHOLD_1) return QUIET_MEDIUM_BUCKET;
        return QUIET_LOW_BUCKET;
    endfunction

    function automatic logic same_move(input Move left, input Move right);
        return left.from_pos == right.from_pos
            && left.to_pos == right.to_pos
            && left.promo_piece == right.promo_piece;
    endfunction

    function automatic logic kingside_castle_permitted(input FullBoard board);
        return board.turn == WHITE
            ? board.castling_rights.white_kingside : board.castling_rights.black_kingside;
    endfunction

    function automatic logic queenside_castle_permitted(input FullBoard board);
        return board.turn == WHITE
            ? board.castling_rights.white_queenside : board.castling_rights.black_queenside;
    endfunction

    function automatic logic [3:0] first_source(input logic [15:0] mask);
        for (int index = 0; index < 16; index++)
            if (mask[index]) return 4'(index);
        return 4'd0;
    endfunction

    // Build a cheap exact-or-conservative eligibility mask once per
    // destination so the shared expander never serially visits empty lanes.
    function automatic logic potential_ray_source(
        input FullBoard board,
        input Position destination,
        input Tile destination_tile,
        input Direction dir,
        input RayRecord ray
    );
        automatic Tile source = ray.tile;
        automatic logic destination_occupied =
            destination_tile.piece_type != NULL_PIECE;
        automatic logic promotion_destination =
            get_rank(destination) == BoardRank'(0)
            || get_rank(destination) == BoardRank'(7);
        automatic logic ep_destination = board.has_ep
            && !destination_occupied
            && get_file(destination) == board.ep_file
            && ((board.turn == WHITE && get_rank(destination) == BoardRank'(5))
                || (board.turn == BLACK && get_rank(destination) == BoardRank'(2)));
        automatic logic phase_matches = GENERATION_COMMAND == MOVE_GEN_GENERATE_NOISY
            ? destination_occupied : !destination_occupied;

        if (source.piece_type == NULL_PIECE || source.piece_color != board.turn)
            return 1'b0;
        case (source.piece_type)
            PAWN: begin
                if (board.turn == WHITE) begin
                    if (GENERATION_COMMAND == MOVE_GEN_GENERATE_NOISY)
                        return (!destination_occupied && promotion_destination
                                && dir == SOUTH && ray.distance == 3'd0)
                            || ((destination_occupied || ep_destination)
                                && (dir == SOUTH_WEST || dir == SOUTH_EAST)
                                && ray.distance == 3'd0);
                    return !promotion_destination && dir == SOUTH
                        && (ray.distance == 3'd0
                            || (ray.distance == 3'd1
                                && get_rank(destination) == BoardRank'(3)));
                end
                if (GENERATION_COMMAND == MOVE_GEN_GENERATE_NOISY)
                    return (!destination_occupied && promotion_destination
                            && dir == NORTH && ray.distance == 3'd0)
                        || ((destination_occupied || ep_destination)
                            && (dir == NORTH_WEST || dir == NORTH_EAST)
                            && ray.distance == 3'd0);
                return !promotion_destination && dir == NORTH
                    && (ray.distance == 3'd0
                        || (ray.distance == 3'd1
                            && get_rank(destination) == BoardRank'(4)));
            end
            BISHOP: return phase_matches && is_diagonal_direction(dir);
            ROOK: return phase_matches && is_cardinal_direction(dir);
            QUEEN: return phase_matches;
            KING: return phase_matches && ray.distance == 3'd0;
            default: return 1'b0;
        endcase
    endfunction

    function automatic logic potential_knight_source(
        input FullBoard board,
        input Tile destination_tile,
        input Tile source
    );
        return source.piece_type == KNIGHT
            && source.piece_color == board.turn
            && ((GENERATION_COMMAND == MOVE_GEN_GENERATE_NOISY)
                == (destination_tile.piece_type != NULL_PIECE));
    endfunction

    // Build ray and knight context from a registered destination so the fixed
    // priority encoder and board scan occupy separate timing stages.
    always_comb begin
        selected_destination = first_destination(destination_mask);
        selected_destination_tile = job_board.tiles[selected_destination];
        selected_source_mask = 16'd0;
        for (int dir = 0; dir < 8; dir++) begin
            selected_context_ray[dir] =
                nearest_ray(job_board, context_destination, Direction'(dir));
            selected_context_knight[dir] =
                is_knight_shift_on_board(context_destination, KnightDirection'(dir))
                    ? job_board.tiles[
                        shift_knight_position(context_destination, KnightDirection'(dir))
                    ] : EMPTY_TILE;
            selected_source_mask[dir] = potential_ray_source(
                job_board, context_destination, context_destination_tile,
                Direction'(dir), selected_context_ray[dir]
            );
            selected_source_mask[dir + 8] = potential_knight_source(
                job_board, context_destination_tile, selected_context_knight[dir]
            );
        end
    end

    // These combinational events keep optional counters and simulation
    // profiling exact when a registered destination is analyzed.
    always_comb begin
        destination_examined_event = state == GEN_BUILD_CONTEXT;
        destination_with_source_event =
            destination_examined_event && selected_source_mask != 16'd0;
`ifdef FPGA_CHESS_PROFILE
        // Candidate analysis precedes suppression and may therefore exceed writes.
        profile_candidate_event =
            (state == GEN_EXPAND_SOURCE && candidate_slot_ready
                && source_mask != 16'd0 && source_valid)
            || castle_candidate_pseudo_legal;
`endif
    end

    // Castling uses the same pending writeback stage as ordinary quiet moves.
    always_comb begin
        castle_candidate_move.from_pos =
            job_board.turn == WHITE ? Position'(4) : Position'(60);
        castle_candidate_move.to_pos = job_board.turn == WHITE
            ? (castle_index ? Position'(2) : Position'(6))
            : (castle_index ? Position'(58) : Position'(62));
        castle_candidate_move.promo_piece = PROMO_QUEEN;
        castle_candidate_pseudo_legal = state == GEN_CASTLE && candidate_slot_ready
            && castle_pseudo_legal(job_board, castle_candidate_move);
        castle_candidate_suppressed = job_suppress_valid
            && same_move(castle_candidate_move, job_suppress_move);
    end

    // Expand one of the active context's eight ray or eight knight sources.
    always_comb begin
        automatic Tile source;
        automatic Move move;
        automatic logic ep_move;
        automatic logic geometry_ok;
        source_valid = 1'b0;
        source_move = NULL_MOVE;
        source_attacker = EMPTY_TILE;
        source_victim = context_destination_tile;
        source_is_capture = 1'b0;
        source_is_ep = 1'b0;
        source_is_promotion = 1'b0;
        source_is_knight = 1'b0;
        source_lane = Direction'(0);
        move.to_pos = context_destination;
        move.promo_piece = PROMO_QUEEN;
        if (source_select_index < 4'd8) begin
            source = context_ray[source_select_index].tile;
            move.from_pos = shift_position(context_destination, Direction'(source_select_index),
                3'(context_ray[source_select_index].distance + 3'd1));
            ep_move = source.piece_type == PAWN && job_board.has_ep
                && context_destination_tile.piece_type == NULL_PIECE
                && get_file(context_destination) == job_board.ep_file
                && ((job_board.turn == WHITE && get_rank(move.from_pos) == BoardRank'(4)
                        && get_rank(context_destination) == BoardRank'(5))
                    || (job_board.turn == BLACK && get_rank(move.from_pos) == BoardRank'(3)
                        && get_rank(context_destination) == BoardRank'(2)));
            geometry_ok = 1'b0;
            case (source.piece_type)
                PAWN: begin
                    if (job_board.turn == WHITE) begin
                        if (Direction'(source_select_index) == SOUTH
                                && context_destination_tile.piece_type == NULL_PIECE)
                            geometry_ok = context_ray[source_select_index].distance == 0
                                || (context_ray[source_select_index].distance == 1
                                    && get_rank(context_destination) == BoardRank'(3));
                        else geometry_ok = context_ray[source_select_index].distance == 0
                            && (Direction'(source_select_index) == SOUTH_WEST
                                || Direction'(source_select_index) == SOUTH_EAST)
                            && ((context_destination_tile.piece_type != NULL_PIECE
                                && context_destination_tile.piece_color == BLACK) || ep_move);
                    end else begin
                        if (Direction'(source_select_index) == NORTH
                                && context_destination_tile.piece_type == NULL_PIECE)
                            geometry_ok = context_ray[source_select_index].distance == 0
                                || (context_ray[source_select_index].distance == 1
                                    && get_rank(context_destination) == BoardRank'(4));
                        else geometry_ok = context_ray[source_select_index].distance == 0
                            && (Direction'(source_select_index) == NORTH_WEST
                                || Direction'(source_select_index) == NORTH_EAST)
                            && ((context_destination_tile.piece_type != NULL_PIECE
                                && context_destination_tile.piece_color == WHITE) || ep_move);
                    end
                end
                BISHOP: geometry_ok = is_diagonal_direction(Direction'(source_select_index));
                ROOK: geometry_ok = is_cardinal_direction(Direction'(source_select_index));
                QUEEN: geometry_ok = 1'b1;
                KING: geometry_ok = context_ray[source_select_index].distance == 0;
                default: geometry_ok = 1'b0;
            endcase
            if (source.piece_type != NULL_PIECE && source.piece_color == job_board.turn
                    && geometry_ok) begin
                source_attacker = source;
                source_move = move;
                source_is_ep = ep_move;
                source_is_capture = ep_move || context_destination_tile.piece_type != NULL_PIECE;
                source_is_promotion = source.piece_type == PAWN
                    && (get_rank(context_destination) == BoardRank'(0)
                        || get_rank(context_destination) == BoardRank'(7));
                source_lane = Direction'(source_select_index);
                source_valid = (GENERATION_COMMAND == MOVE_GEN_GENERATE_NOISY)
                    ? source_is_capture || source_is_promotion
                    : !source_is_capture && !source_is_promotion;
            end
        end else begin
            automatic int knight_index = int'(source_select_index) - 8;
            source = context_knight[knight_index];
            if (source.piece_type == KNIGHT && source.piece_color == job_board.turn) begin
                move.from_pos = shift_knight_position(context_destination, KnightDirection'(knight_index));
                source_attacker = source;
                source_move = move;
                source_is_capture = context_destination_tile.piece_type != NULL_PIECE;
                source_is_knight = 1'b1;
                source_lane = Direction'(knight_index);
                source_valid = (GENERATION_COMMAND == MOVE_GEN_GENERATE_NOISY)
                    ? source_is_capture : !source_is_capture;
            end
        end
    end

    always_comb begin
        pop_select_found = 1'b0;
        pop_select_bucket = MoveBucketIndex'(0);
        pop_select_new_top = MoveBucketTop'(0);
        for (int bucket = MOVE_BUCKET_COUNT - 1; bucket >= 0; bucket--) begin
            if (!pop_select_found && pop_eligible[bucket]
                    && pop_current_tops[bucket] != pop_lower_tops[bucket]) begin
                pop_select_found = 1'b1;
                pop_select_bucket = MoveBucketIndex'(bucket);
                pop_select_new_top = pop_current_tops[bucket] - MoveBucketTop'(1);
            end
        end
    end

    assign path_ready = state == GEN_IDLE && !init_busy;
    // A normal candidate is consumed every cycle; promotion variants retain
    // the slot until all four encodings have been written.
    assign candidate_slot_ready = !candidate_valid
        || !(candidate_is_promotion && candidate_promo_counter != 2'd0);
    assign candidate_finishes_write = candidate_valid
        && !(candidate_is_promotion && candidate_promo_counter != 2'd0);
    assign cmd_ready = path_ready
        && (cmd == GENERATION_COMMAND
            || (GENERATION_COMMAND == MOVE_GEN_GENERATE_NOISY
                && cmd == MOVE_GEN_VALIDATE_DIRECT));
    assign pop_ready = !init_busy && !pop_pending;
    assign pop_resp_valid = pop_pending;
    assign pop_resp_thread = pop_thread_q;
    assign pop_resp_ply = pop_ply_q;
    assign pop_resp_found = pop_found_q;
    assign pop_resp_bucket = pop_bucket_q;
    assign pop_resp_new_top = pop_new_top_q;
    assign pop_resp_move = pop_found_q ? bucket_q[pop_bucket_q] : NULL_MOVE;

    always_comb begin
        for (int bucket = 0; bucket < MOVE_BUCKET_COUNT; bucket++) begin
            bucket_wr_en[bucket] = 1'b0;
            bucket_rd_en[bucket] = 1'b0;
        end
        bucket_wr_data = candidate_move;
        bucket_wr_thread = job_thread;
        bucket_wr_select = MoveBucketIndex'(0);
        bucket_wr_top = job_tops[0];
        bucket_rd_thread = pop_thread;
        bucket_rd_top = pop_select_new_top;
        if (pop_valid && pop_ready && pop_select_found)
            bucket_rd_en[pop_select_bucket] = 1'b1;

        generator_history_read_early = state == GEN_EXPAND_SOURCE
            && candidate_slot_ready
            && source_mask != 16'd0 && source_valid
            && !source_is_capture && !source_is_promotion
            && !(job_suppress_valid && same_move(source_move, job_suppress_move));
        generator_history_read_castle = castle_candidate_pseudo_legal
            && !castle_candidate_suppressed;
        generator_history_read =
            generator_history_read_early || generator_history_read_castle;

        if (candidate_valid && (candidate_is_capture || candidate_is_promotion)) begin
            bucket_wr_select = noisy_bucket();
            bucket_wr_top = job_tops[bucket_wr_select];
            if (job_tops[bucket_wr_select] < bucket_capacity(bucket_wr_select))
                bucket_wr_en[bucket_wr_select] = 1'b1;
        end else if (candidate_valid) begin
            automatic logic signed [10:0] score;
            score = $signed(history_score);
            if (candidate_is_castle) score += CASTLING_HISTORY_BONUS;
            bucket_wr_select = quiet_bucket(score);
            bucket_wr_top = job_tops[bucket_wr_select];
            if (job_tops[bucket_wr_select] < bucket_capacity(bucket_wr_select))
                bucket_wr_en[bucket_wr_select] = 1'b1;
        end
    end

    generate
        if (GENERATION_COMMAND == MOVE_GEN_GENERATE_QUIET) begin : gen_quiet_history
            // Quiet ordering and background updates share one dual-color table.
            move_generator_quiet_history #(
                .REWARD_PER_DEPTH(HISTORY_REWARD_PER_DEPTH),
                .MAXIMUM_REWARD(HISTORY_MAXIMUM_REWARD),
                .MALUS_DIVISOR(HISTORY_MALUS_DIVISOR)
            ) quiet_history (
                .clk, .rst_n, .clear, .init_busy,
                .lookup_valid(generator_history_read),
                .lookup_color(job_board.turn),
                .lookup_address(generator_history_read_castle
                    ? {castle_candidate_move.from_pos, castle_candidate_move.to_pos}
                    : {source_move.from_pos, source_move.to_pos}),
                .lookup_value(history_score),
                .update_valid(history_update_valid), .update_ready(history_update_ready),
                .update_color(history_update_color),
                .update_from(history_update_from), .update_to(history_update_to),
                .update_depth(history_update_depth),
                .update_failed0(history_update_failed0),
                .update_failed1(history_update_failed1),
                .update_failed2(history_update_failed2),
                .update_failed_count(history_update_failed_count)
            );
        end else begin : gen_no_history
            assign init_busy = 1'b0;
            assign history_update_ready = 1'b0;
            assign history_score = '0;
        end
    endgenerate

    // Move storage is a separate resource so lane control does not own RAM layout.
    move_generator_bucket_store #(
        .THREAD_COUNT(THREAD_COUNT),
        .BUCKET_0_CAPACITY(BUCKET_0_CAPACITY), .BUCKET_1_CAPACITY(BUCKET_1_CAPACITY),
        .BUCKET_2_CAPACITY(BUCKET_2_CAPACITY), .BUCKET_3_CAPACITY(BUCKET_3_CAPACITY),
        .BUCKET_4_CAPACITY(BUCKET_4_CAPACITY), .BUCKET_5_CAPACITY(BUCKET_5_CAPACITY),
        .BUCKET_6_CAPACITY(BUCKET_6_CAPACITY), .BUCKET_7_CAPACITY(BUCKET_7_CAPACITY),
        .OWNED_BUCKETS(OWNED_BUCKETS)
    ) bucket_store (
        .clk,
        .wr_en(bucket_wr_en), .wr_data(bucket_wr_data),
        .wr_thread(bucket_wr_thread), .wr_top(bucket_wr_top),
        .rd_en(bucket_rd_en), .rd_thread(bucket_rd_thread), .rd_top(bucket_rd_top),
        .rd_data(bucket_q)
    );

    always_ff @(posedge clk) begin
        if (!rst_n) begin
            state <= GEN_IDLE;
            pop_pending <= 1'b0;
            candidate_valid <= 1'b0;
            source_select_index <= 4'd0;
            cmd_resp_valid <= 1'b0;
            cmd_resp_thread <= ThreadID'(0);
            cmd_resp_ply <= PlyIndex'(0);
            cmd_resp_direct_valid <= 1'b0;
            cmd_resp_direct_move <= NULL_MOVE;
            cmd_resp_bucket_tops <= '0;
            overflow_sticky <= 1'b0;
            overflow_thread <= ThreadID'(0);
            overflow_bucket <= MoveBucketIndex'(0);
            overflow_count <= 16'd0;
            stat_noisy_count <= 40'd0;
            stat_quiet_count <= 40'd0;
            stat_destination_count <= 40'd0;
            stat_candidate_count <= 40'd0;
            stat_history_lookup_count <= 40'd0;
            stat_generation_cycles <= 40'd0;
            for (int bucket = 0; bucket < MOVE_BUCKET_COUNT; bucket++) begin
                stat_bucket_count[bucket] <= 40'd0;
                stat_bucket_high_water[bucket] <= MoveBucketTop'(0);
            end
        end else begin
            cmd_resp_valid <= 1'b0;
            pop_pending <= pop_valid && pop_ready;
            if (pop_valid && pop_ready) begin
                pop_found_q <= pop_select_found;
                pop_thread_q <= pop_thread;
                pop_ply_q <= pop_ply;
                pop_bucket_q <= pop_select_bucket;
                pop_new_top_q <= pop_select_new_top;
            end

            if (clear) begin
                overflow_sticky <= 1'b0;
                overflow_count <= 16'd0;
            end

            if (flush) begin
                state <= GEN_IDLE;
                pop_pending <= 1'b0;
                candidate_valid <= 1'b0;
            end else begin
                if (state != GEN_IDLE && ENABLE_STATS)
                    stat_generation_cycles <= stat_generation_cycles + 40'd1;
                if (destination_examined_event && ENABLE_STATS)
                    stat_destination_count <= stat_destination_count + 40'd1;

                // Candidate writeback runs independently of destination/source
                // walking, permitting one ordinary candidate to complete while
                // the next candidate or destination is prepared.
                if (candidate_valid) begin
                    automatic MoveBucketIndex selected = bucket_wr_select;
                    if (job_tops[selected] < bucket_capacity(selected)) begin
                        job_tops[selected] <= job_tops[selected] + MoveBucketTop'(1);
                        if (ENABLE_STATS) begin
                            stat_bucket_count[selected] <= stat_bucket_count[selected] + 40'd1;
                            if (candidate_is_capture || candidate_is_promotion)
                                stat_noisy_count <= stat_noisy_count + 40'd1;
                            else
                                stat_quiet_count <= stat_quiet_count + 40'd1;
                            if (job_tops[selected] + MoveBucketTop'(1)
                                    > stat_bucket_high_water[selected])
                                stat_bucket_high_water[selected]
                                    <= job_tops[selected] + MoveBucketTop'(1);
                        end
                    end else begin
                        overflow_sticky <= 1'b1;
                        overflow_thread <= job_thread;
                        overflow_bucket <= selected;
                        if (overflow_count != 16'hffff)
                            overflow_count <= overflow_count + 16'd1;
`ifndef SYNTHESIS
                        if (ASSERT_ON_OVERFLOW)
                            $error("move bucket overflow bucket=%0d thread=%0d",
                                selected, job_thread);
`endif
                    end
                    if (candidate_is_promotion && candidate_promo_counter != 2'd0) begin
                        candidate_promo_counter <= candidate_promo_counter - 2'd1;
                        candidate_move.promo_piece
                            <= PromoType'(candidate_promo_counter - 2'd1);
                    end else begin
                        candidate_valid <= 1'b0;
                    end
                end
                case (state)
                    GEN_IDLE: begin
                        // Payload is irrelevant until a command is accepted.
                        // Preload it while idle so command validity controls
                        // only the state transition, not a 64-bit data mux.
                        destination_mask <= generation_destination_mask(cmd_board);
                        if (cmd_valid && cmd_ready) begin
                            job_thread <= cmd_thread;
                            job_ply <= cmd_ply;
                            job_board <= cmd_board;
                            job_suppress_valid <= cmd_suppress_valid;
                            job_suppress_move <= cmd_suppress_move;
                            job_tops <= cmd_bucket_tops;
                            candidate_valid <= 1'b0;
                            if (GENERATION_COMMAND == MOVE_GEN_GENERATE_NOISY
                                    && cmd == MOVE_GEN_VALIDATE_DIRECT) begin
                                state <= GEN_DIRECT;
                            end else begin
                                state <= GEN_SELECT_DEST;
                            end
                        end
                    end

                    GEN_DIRECT: begin
                        cmd_resp_valid <= 1'b1;
                        cmd_resp_thread <= job_thread;
                        cmd_resp_ply <= job_ply;
                        cmd_resp_direct_valid <= move_pseudo_legal(job_board, job_suppress_move);
                        cmd_resp_direct_move <= job_suppress_move;
                        cmd_resp_bucket_tops <= job_tops;
                        state <= GEN_IDLE;
                    end

                    GEN_SELECT_DEST: begin
                        if (destination_mask != 64'd0) begin
                            destination_mask[selected_destination] <= 1'b0;
                            context_destination <= selected_destination;
                            context_destination_tile <= selected_destination_tile;
                            state <= GEN_BUILD_CONTEXT;
                        end else if (candidate_finishes_write) begin
                            if (GENERATION_COMMAND == MOVE_GEN_GENERATE_QUIET
                                    && (kingside_castle_permitted(job_board)
                                        || queenside_castle_permitted(job_board))) begin
                                castle_index <= !kingside_castle_permitted(job_board);
                                state <= GEN_CASTLE;
                            end else begin
                                cmd_resp_valid <= 1'b1;
                                cmd_resp_thread <= job_thread;
                                cmd_resp_ply <= job_ply;
                                cmd_resp_direct_valid <= 1'b0;
                                cmd_resp_direct_move <= NULL_MOVE;
                                cmd_resp_bucket_tops <= tops_after_candidate_write(
                                    job_tops, bucket_wr_select
                                );
                                state <= GEN_IDLE;
                            end
                        end else if (!candidate_valid) begin
                            if (GENERATION_COMMAND == MOVE_GEN_GENERATE_QUIET
                                    && (kingside_castle_permitted(job_board)
                                        || queenside_castle_permitted(job_board))) begin
                                // Skip a denied kingside attempt and avoid the
                                // castle sequencer entirely once both rights
                                // have been lost.
                                castle_index <= !kingside_castle_permitted(job_board);
                                state <= GEN_CASTLE;
                            end else begin
                                cmd_resp_valid <= 1'b1;
                                cmd_resp_thread <= job_thread;
                                cmd_resp_ply <= job_ply;
                                cmd_resp_direct_valid <= 1'b0;
                                cmd_resp_direct_move <= NULL_MOVE;
                                cmd_resp_bucket_tops <= job_tops;
                                state <= GEN_IDLE;
                            end
                        end
                    end

                    GEN_EXPAND_SOURCE: begin
                        if (!candidate_slot_ready) begin
                            state <= GEN_EXPAND_SOURCE;
                        end else if (source_mask == 16'd0) begin
                            state <= GEN_SELECT_DEST;
                        end else begin
                            automatic logic [15:0] remaining_mask =
                                source_mask & ~(16'b1 << source_select_index);
                            source_mask <= remaining_mask;
                            source_select_index <= first_source(remaining_mask);
                            if (source_valid) begin
                                candidate_move <= source_move;
                                candidate_attacker <= source_attacker;
                                candidate_victim <= source_victim;
                                candidate_is_capture <= source_is_capture;
                                candidate_is_ep <= source_is_ep;
                                candidate_is_promotion <= source_is_promotion;
                                candidate_is_castle <= 1'b0;
                                candidate_is_knight <= source_is_knight;
                                candidate_see_good <= see_nonnegative(
                                    source_attacker,
                                    source_victim,
                                    source_is_ep,
                                    source_is_knight,
                                    source_lane
                                );
                                candidate_lane <= source_lane;
                                candidate_promo_counter <= source_is_promotion ? 2'd3 : 2'd0;
                                if (source_is_promotion)
                                    candidate_move.promo_piece <= PROMO_BISHOP;
                                if (ENABLE_STATS)
                                    stat_candidate_count <= stat_candidate_count + 40'd1;
                                if (job_suppress_valid
                                        && same_move(source_move, job_suppress_move)) begin
                                    candidate_valid <= 1'b0;
                                end else begin
                                    candidate_valid <= 1'b1;
                                    if (!source_is_capture && !source_is_promotion
                                            && ENABLE_STATS)
                                        stat_history_lookup_count
                                            <= stat_history_lookup_count + 40'd1;
                                end
                            end
                            if (remaining_mask == 16'd0 && destination_mask != 64'd0) begin
                                // Select the next destination while the final
                                // current source enters writeback, then build
                                // its board context in the following cycle.
                                destination_mask[selected_destination] <= 1'b0;
                                context_destination <= selected_destination;
                                context_destination_tile <= selected_destination_tile;
                                state <= GEN_BUILD_CONTEXT;
                            end else begin
                                state <= remaining_mask == 16'd0
                                    ? GEN_SELECT_DEST : GEN_EXPAND_SOURCE;
                            end
                        end
                    end

                    GEN_BUILD_CONTEXT: begin
                        for (int dir = 0; dir < 8; dir++) begin
                            context_ray[dir] <= selected_context_ray[dir];
                            context_knight[dir] <= selected_context_knight[dir];
                        end
                        if (selected_source_mask != 16'd0) begin
                            source_mask <= selected_source_mask;
                            source_select_index <= first_source(selected_source_mask);
                            state <= GEN_EXPAND_SOURCE;
                        end else begin
                            state <= GEN_SELECT_DEST;
                        end
                    end

                    GEN_HISTORY_WAIT: begin
                        // Retained encoding for stable profiling; new commands
                        // never enter this state.
                        state <= GEN_SELECT_DEST;
                    end

                    GEN_CASTLE: begin
                        if (!candidate_slot_ready) begin
                            state <= GEN_CASTLE;
                        end else if (castle_candidate_pseudo_legal) begin
                            candidate_move <= castle_candidate_move;
                            candidate_attacker <= Tile'({job_board.turn, KING});
                            candidate_victim <= EMPTY_TILE;
                            candidate_is_capture <= 1'b0;
                            candidate_is_ep <= 1'b0;
                            candidate_is_promotion <= 1'b0;
                            candidate_is_castle <= 1'b1;
                            candidate_is_knight <= 1'b0;
                            candidate_see_good <= 1'b1;
                            candidate_lane <= Direction'(0);
                            if (ENABLE_STATS) stat_candidate_count <= stat_candidate_count + 40'd1;
                            if (castle_candidate_suppressed) begin
                                candidate_valid <= 1'b0;
                            end else begin
                                candidate_valid <= 1'b1;
                                if (ENABLE_STATS)
                                    stat_history_lookup_count
                                        <= stat_history_lookup_count + 40'd1;
                            end
                            if (!castle_index && queenside_castle_permitted(job_board)) begin
                                castle_index <= 1'b1;
                            end else begin
                                state <= GEN_FINISH;
                            end
                        end else if (!castle_index
                                && queenside_castle_permitted(job_board)) begin
                            castle_index <= 1'b1;
                        end else if (candidate_valid) begin
                            // A previously accepted castle writes on this edge;
                            // forward its incremented top with the response.
                            cmd_resp_valid <= 1'b1;
                            cmd_resp_thread <= job_thread;
                            cmd_resp_ply <= job_ply;
                            cmd_resp_direct_valid <= 1'b0;
                            cmd_resp_direct_move <= NULL_MOVE;
                            cmd_resp_bucket_tops <= tops_after_candidate_write(
                                job_tops, bucket_wr_select
                            );
                            state <= GEN_IDLE;
                        end else begin
                            cmd_resp_valid <= 1'b1;
                            cmd_resp_thread <= job_thread;
                            cmd_resp_ply <= job_ply;
                            cmd_resp_direct_valid <= 1'b0;
                            cmd_resp_direct_move <= NULL_MOVE;
                            cmd_resp_bucket_tops <= job_tops;
                            state <= GEN_IDLE;
                        end
                    end

                    GEN_FINISH: begin
                        if (candidate_finishes_write) begin
                            cmd_resp_valid <= 1'b1;
                            cmd_resp_thread <= job_thread;
                            cmd_resp_ply <= job_ply;
                            cmd_resp_direct_valid <= 1'b0;
                            cmd_resp_direct_move <= NULL_MOVE;
                            cmd_resp_bucket_tops <= tops_after_candidate_write(
                                job_tops, bucket_wr_select
                            );
                            state <= GEN_IDLE;
                        end else if (!candidate_valid) begin
                            cmd_resp_valid <= 1'b1;
                            cmd_resp_thread <= job_thread;
                            cmd_resp_ply <= job_ply;
                            cmd_resp_direct_valid <= 1'b0;
                            cmd_resp_direct_move <= NULL_MOVE;
                            cmd_resp_bucket_tops <= job_tops;
                            state <= GEN_IDLE;
                        end
                    end

                    default: state <= GEN_IDLE;
                endcase
            end
        end
    end

endmodule : move_generator_lane
