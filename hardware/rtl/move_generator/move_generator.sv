// One specialized destination-centric move-generation and bucket-storage pipeline.

import general_chess_defs::*;
import chess_helper_funcs::*;
import move_generator_defs::*;

module move_generator_pipeline #(
    parameter int THREAD_COUNT = 1,
    parameter int BUCKET_0_CAPACITY = 512,
    parameter int BUCKET_1_CAPACITY = 512,
    parameter int BUCKET_2_CAPACITY = 512,
    parameter int BUCKET_3_CAPACITY = 512,
    parameter int BUCKET_4_CAPACITY = 512,
    parameter int BUCKET_5_CAPACITY = 512,
    parameter int BUCKET_6_CAPACITY = 512,
    parameter int BUCKET_7_CAPACITY = 512,
    parameter MoveGenCommand GENERATION_COMMAND = MOVE_GEN_GENERATE_NOISY,
    parameter MoveBucketMask OWNED_BUCKETS =
        GOOD_NOISY_BUCKET_MASK | BAD_NOISY_BUCKET_MASK,
    parameter bit ASSERT_ON_OVERFLOW = 1'b1,
    parameter bit ENABLE_STATS = 1'b0
) (
    input logic clk,
    input logic rst_n,
    input logic clear,
    input logic flush,
    output logic init_busy,
    output logic path_ready,

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
    input logic [5:0] history_update_depth,
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

    localparam int HISTORY_BITS = 9;
    localparam int HISTORY_WORDS = 4096;
    localparam int HISTORY_LIMIT_SHIFT = HISTORY_BITS - 1;

    typedef enum logic [3:0] {
        GEN_IDLE,
        GEN_DIRECT,
        GEN_SELECT_DEST,
        GEN_EXPAND_SOURCE,
        GEN_SCORE,
        GEN_HISTORY_WAIT,
        GEN_CASTLE,
        GEN_FINISH
    } GeneratorState;

    typedef enum logic [1:0] {
        HISTORY_UPDATE_IDLE,
        HISTORY_UPDATE_READ,
        HISTORY_UPDATE_CAPTURE,
        HISTORY_UPDATE_WRITE
    } HistoryUpdateState;

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

    function automatic logic is_power_of_two(input int value);
        return value > 0 && (value & (value - 1)) == 0;
    endfunction

`ifndef SYNTHESIS
    initial begin
        if (THREAD_COUNT < 1 || THREAD_COUNT > general_chess_defs::THREAD_COUNT)
            $fatal(1, "move_generator THREAD_COUNT exceeds ThreadID capacity");
        if (GENERATION_COMMAND != MOVE_GEN_GENERATE_NOISY
                && GENERATION_COMMAND != MOVE_GEN_GENERATE_QUIET)
            $fatal(1, "move-generator pipeline must be noisy or quiet");
        for (int bucket = 0; bucket < MOVE_BUCKET_COUNT; bucket++) begin
            if (!is_power_of_two(int'(bucket_capacity(MoveBucketIndex'(bucket))))
                    || int'(bucket_capacity(MoveBucketIndex'(bucket))) > (1 << (MOVE_BUCKET_TOP_BITS - 1)))
                $fatal(1, "move bucket capacities must be powers of two no larger than 512");
        end
    end
`endif

    GeneratorState state;
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
    logic castle_index;

    Move candidate_move;
    Tile candidate_attacker;
    Tile candidate_victim;
    logic candidate_is_capture;
    logic candidate_is_ep;
    logic candidate_is_promotion;
    logic candidate_is_castle;
    logic candidate_is_knight;
    Direction candidate_lane;
    logic [1:0] candidate_promo_counter;
    logic candidate_valid;
    logic candidate_slot_ready;

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

    logic [11:0] history_clear_addr;
    logic signed [HISTORY_BITS-1:0] history_q[2];
    logic history_rd_en[2];
    logic [11:0] history_rd_addr[2];
    logic history_wr_en[2];
    logic [11:0] history_wr_addr[2];
    logic signed [HISTORY_BITS-1:0] history_wr_data[2];
    HistoryUpdateState history_update_state;
    Color update_color;
    logic [11:0] update_address;
    logic [5:0] update_depth;
    logic [11:0] update_failed0;
    logic [11:0] update_failed1;
    logic [11:0] update_failed2;
    logic [1:0] update_failed_count;
    logic [1:0] update_entry;
    logic update_is_malus;
    logic signed [HISTORY_BITS-1:0] update_history_value;
    logic generator_history_read;
    logic generator_history_read_early;
    logic generator_history_read_castle;
    logic update_read_blocked;
    logic update_write_blocked;
    Move castle_candidate_move;
    logic castle_candidate_pseudo_legal;
    logic castle_candidate_suppressed;

    function automatic Position first_destination(input logic [63:0] mask);
        for (int pos = 0; pos < 64; pos++)
            if (mask[pos]) return Position'(pos);
        return Position'(0);
    endfunction

    // Avoid scheduling pawn-only noisy destinations that have no possible source.
    function automatic logic noisy_pawn_destination_has_source(
        input FullBoard board,
        input Position destination
    );
        if (getRank(destination) == (board.turn == WHITE ? BoardRank'(7) : BoardRank'(0))) begin
            return isShiftOnBoard(destination, board.turn == WHITE ? SOUTH : NORTH, 3'd1)
                && board.tiles[shiftPos(destination, board.turn == WHITE ? SOUTH : NORTH, 3'd1)]
                    == Tile'({board.turn, PAWN});
        end
        if (board.has_ep && getFile(destination) == board.ep_file
                && getRank(destination) == (board.turn == WHITE ? BoardRank'(5) : BoardRank'(2))) begin
            return (isShiftOnBoard(destination, board.turn == WHITE ? SOUTH_WEST : NORTH_WEST, 3'd1)
                    && board.tiles[shiftPos(destination,
                        board.turn == WHITE ? SOUTH_WEST : NORTH_WEST, 3'd1)]
                        == Tile'({board.turn, PAWN}))
                || (isShiftOnBoard(destination, board.turn == WHITE ? SOUTH_EAST : NORTH_EAST, 3'd1)
                    && board.tiles[shiftPos(destination,
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
                            && getRank(Position'(pos))
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
        automatic BoardRank rank = getRank(pos);
        automatic BoardFile file = getFile(pos);
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
        result = NULL_RAY;
        for (int distance = 1; distance < 8; distance++) begin
            if (3'(distance) <= ray_max_distance(destination, dir)
                    && result.tile.piece_type == NULL_PIECE) begin
                automatic Position pos = shiftPos(destination, dir, 3'(distance));
                if (board.tiles[pos].piece_type != NULL_PIECE) begin
                    result.tile = board.tiles[pos];
                    result.distance = 3'(distance - 1);
                end
            end
        end
        return result;
    endfunction

    function automatic logic line_path_clear(
        input FullBoard board,
        input Position from_pos,
        input Position to_pos
    );
        automatic BoardRank from_rank = getRank(from_pos);
        automatic BoardFile from_file = getFile(from_pos);
        automatic BoardRank to_rank = getRank(to_pos);
        automatic BoardFile to_file = getFile(to_pos);
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

    function automatic logic line_attacker(input PieceType piece, input Direction dir);
        return piece == QUEEN
            || (piece == ROOK && isDirCardinal(dir))
            || (piece == BISHOP && isDirDiag(dir));
    endfunction

    function automatic logic square_attacked(
        input FullBoard board,
        input Position square,
        input Color attacker_color
    );
        automatic Position test_pos;
        automatic Tile test_tile;
        if (attacker_color == WHITE) begin
            if (isShiftOnBoard(square, SOUTH_WEST, 3'd1)
                    && board.tiles[shiftPos(square, SOUTH_WEST, 3'd1)] == WHITE_PAWN) return 1'b1;
            if (isShiftOnBoard(square, SOUTH_EAST, 3'd1)
                    && board.tiles[shiftPos(square, SOUTH_EAST, 3'd1)] == WHITE_PAWN) return 1'b1;
        end else begin
            if (isShiftOnBoard(square, NORTH_WEST, 3'd1)
                    && board.tiles[shiftPos(square, NORTH_WEST, 3'd1)] == BLACK_PAWN) return 1'b1;
            if (isShiftOnBoard(square, NORTH_EAST, 3'd1)
                    && board.tiles[shiftPos(square, NORTH_EAST, 3'd1)] == BLACK_PAWN) return 1'b1;
        end
        for (int dir = 0; dir < 8; dir++) begin
            if (isKnightShiftOnBoard(square, KnightDirection'(dir))) begin
                test_pos = shiftKnightPos(square, KnightDirection'(dir));
                if (board.tiles[test_pos] == Tile'({attacker_color, KNIGHT})) return 1'b1;
            end
        end
        for (int dir = 0; dir < 8; dir++) begin
            for (int distance = 1; distance < 8; distance++) begin
                if (isShiftOnBoard(square, Direction'(dir), 3'(distance))) begin
                    test_pos = shiftPos(square, Direction'(dir), 3'(distance));
                    test_tile = board.tiles[test_pos];
                    if (test_tile.piece_type != NULL_PIECE) begin
                        if (test_tile.piece_color == attacker_color) begin
                            if (distance == 1 && test_tile.piece_type == KING) return 1'b1;
                            if (line_attacker(test_tile.piece_type, Direction'(dir))) return 1'b1;
                        end
                        break;
                    end
                end
            end
        end
        return 1'b0;
    endfunction

    function automatic FullBoard castle_transit_board(
        input FullBoard board,
        input Move move
    );
        automatic FullBoard result = board;
        automatic Position transit = getFile(move.to_pos) > getFile(move.from_pos)
            ? move.from_pos + Position'(1) : move.from_pos - Position'(1);
        result.tiles[move.from_pos] = EMPTY_TILE;
        result.tiles[transit] = Tile'({board.turn, KING});
        return result;
    endfunction

    function automatic FullBoard castle_final_board(
        input FullBoard board,
        input Move move
    );
        automatic FullBoard result = board;
        automatic Position rook_from;
        automatic Position rook_to;
        case (move.to_pos)
            Position'(2): begin rook_from = Position'(0); rook_to = Position'(3); end
            Position'(6): begin rook_from = Position'(7); rook_to = Position'(5); end
            Position'(58): begin rook_from = Position'(56); rook_to = Position'(59); end
            default: begin rook_from = Position'(63); rook_to = Position'(61); end
        endcase
        result.tiles[move.from_pos] = EMPTY_TILE;
        result.tiles[rook_from] = EMPTY_TILE;
        result.tiles[move.to_pos] = Tile'({board.turn, KING});
        result.tiles[rook_to] = Tile'({board.turn, ROOK});
        return result;
    endfunction

    function automatic logic castle_pseudo_legal(input FullBoard board, input Move move);
        automatic logic occupancy_ok;
        automatic logic permission_ok;
        automatic Position rook_pos;
        automatic Position transit;
        automatic FullBoard transit_board;
        automatic FullBoard final_board;
        occupancy_ok = 1'b0;
        permission_ok = 1'b0;
        rook_pos = Position'(0);
        if (board.turn == WHITE && move.from_pos == Position'(4) && move.to_pos == Position'(6)) begin
            permission_ok = board.castle_perms.white_kingside;
            rook_pos = Position'(7);
            occupancy_ok = board.tiles[5].piece_type == NULL_PIECE && board.tiles[6].piece_type == NULL_PIECE;
        end else if (board.turn == WHITE && move.from_pos == Position'(4) && move.to_pos == Position'(2)) begin
            permission_ok = board.castle_perms.white_queenside;
            rook_pos = Position'(0);
            occupancy_ok = board.tiles[1].piece_type == NULL_PIECE
                && board.tiles[2].piece_type == NULL_PIECE && board.tiles[3].piece_type == NULL_PIECE;
        end else if (board.turn == BLACK && move.from_pos == Position'(60) && move.to_pos == Position'(62)) begin
            permission_ok = board.castle_perms.black_kingside;
            rook_pos = Position'(63);
            occupancy_ok = board.tiles[61].piece_type == NULL_PIECE && board.tiles[62].piece_type == NULL_PIECE;
        end else if (board.turn == BLACK && move.from_pos == Position'(60) && move.to_pos == Position'(58)) begin
            permission_ok = board.castle_perms.black_queenside;
            rook_pos = Position'(56);
            occupancy_ok = board.tiles[57].piece_type == NULL_PIECE
                && board.tiles[58].piece_type == NULL_PIECE && board.tiles[59].piece_type == NULL_PIECE;
        end else begin
            return 1'b0;
        end
        if (!permission_ok || !occupancy_ok
                || board.tiles[rook_pos] != Tile'({board.turn, ROOK})) return 1'b0;
        transit = getFile(move.to_pos) > getFile(move.from_pos)
            ? move.from_pos + Position'(1) : move.from_pos - Position'(1);
        transit_board = castle_transit_board(board, move);
        final_board = castle_final_board(board, move);
        return !square_attacked(board, move.from_pos, Color'(~board.turn))
            && !square_attacked(transit_board, transit, Color'(~board.turn))
            && !square_attacked(final_board, move.to_pos, Color'(~board.turn));
    endfunction

    // Direct moves use the same pseudo-legality contract as generated candidates.
    function automatic logic move_pseudo_legal(input FullBoard board, input Move move);
        automatic Tile source = board.tiles[move.from_pos];
        automatic Tile destination = board.tiles[move.to_pos];
        automatic BoardRank from_rank = getRank(move.from_pos);
        automatic BoardFile from_file = getFile(move.from_pos);
        automatic BoardRank to_rank = getRank(move.to_pos);
        automatic BoardFile to_file = getFile(move.to_pos);
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
            BISHOP: return isDirDiag(dir);
            ROOK: return isDirCardinal(dir);
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
    function automatic logic candidate_see_nonnegative();
        automatic PieceType victim = candidate_is_ep ? PAWN : candidate_victim.piece_type;
        automatic logic [4:0] enemy_classes = '0;
        automatic logic friendly_defender = 1'b0;
        automatic logic [3:0] recapturer_value;
        if (exchange_value(candidate_attacker.piece_type) <= exchange_value(victim)) return 1'b1;
        for (int dir = 0; dir < 8; dir++) begin
            automatic Tile tile = context_ray[dir].tile;
            if (!(candidate_is_knight == 1'b0 && candidate_lane == Direction'(dir))
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
            if (!(candidate_is_knight && candidate_lane == Direction'(dir))
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
            >= 5'(exchange_value(candidate_attacker.piece_type));
    endfunction

    function automatic MoveBucketIndex noisy_bucket();
        automatic PieceType victim = candidate_is_ep ? PAWN : candidate_victim.piece_type;
        if (candidate_is_promotion) begin
            return candidate_move.promo_piece == PROMO_QUEEN
                ? GOOD_NOISY_HIGH_BUCKET : GOOD_NOISY_LOW_BUCKET;
        end
        if (candidate_see_nonnegative()) begin
            return victim == ROOK || victim == QUEEN || victim == KING
                ? GOOD_NOISY_HIGH_BUCKET : GOOD_NOISY_LOW_BUCKET;
        end
        return victim == ROOK || victim == QUEEN || victim == KING
            ? BAD_NOISY_HIGH_BUCKET : BAD_NOISY_LOW_BUCKET;
    endfunction

    function automatic MoveBucketIndex quiet_bucket(input logic signed [10:0] score);
        if (score >= 11'sd128) return QUIET_HIGHEST_BUCKET;
        if (score >= 11'sd64) return QUIET_HIGH_BUCKET;
        if (score >= 11'sd16) return QUIET_MEDIUM_BUCKET;
        return QUIET_LOW_BUCKET;
    endfunction

    function automatic logic same_move(input Move left, input Move right);
        return left.from_pos == right.from_pos
            && left.to_pos == right.to_pos
            && left.promo_piece == right.promo_piece;
    endfunction

    function automatic logic kingside_castle_permitted(input FullBoard board);
        return board.turn == WHITE
            ? board.castle_perms.white_kingside : board.castle_perms.black_kingside;
    endfunction

    function automatic logic queenside_castle_permitted(input FullBoard board);
        return board.turn == WHITE
            ? board.castle_perms.white_queenside : board.castle_perms.black_queenside;
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
            getRank(destination) == BoardRank'(0)
            || getRank(destination) == BoardRank'(7);
        automatic logic ep_destination = board.has_ep
            && !destination_occupied
            && getFile(destination) == board.ep_file
            && ((board.turn == WHITE && getRank(destination) == BoardRank'(5))
                || (board.turn == BLACK && getRank(destination) == BoardRank'(2)));
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
                                && getRank(destination) == BoardRank'(3)));
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
                            && getRank(destination) == BoardRank'(4)));
            end
            BISHOP: return phase_matches && isDirDiag(dir);
            ROOK: return phase_matches && isDirCardinal(dir);
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

    always_comb source_select_index = first_source(source_mask);

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
            move.from_pos = shiftPos(context_destination, Direction'(source_select_index),
                3'(context_ray[source_select_index].distance + 3'd1));
            ep_move = source.piece_type == PAWN && job_board.has_ep
                && context_destination_tile.piece_type == NULL_PIECE
                && getFile(context_destination) == job_board.ep_file
                && ((job_board.turn == WHITE && getRank(move.from_pos) == BoardRank'(4)
                        && getRank(context_destination) == BoardRank'(5))
                    || (job_board.turn == BLACK && getRank(move.from_pos) == BoardRank'(3)
                        && getRank(context_destination) == BoardRank'(2)));
            geometry_ok = 1'b0;
            case (source.piece_type)
                PAWN: begin
                    if (job_board.turn == WHITE) begin
                        if (Direction'(source_select_index) == SOUTH
                                && context_destination_tile.piece_type == NULL_PIECE)
                            geometry_ok = context_ray[source_select_index].distance == 0
                                || (context_ray[source_select_index].distance == 1
                                    && getRank(context_destination) == BoardRank'(3));
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
                                    && getRank(context_destination) == BoardRank'(4));
                        else geometry_ok = context_ray[source_select_index].distance == 0
                            && (Direction'(source_select_index) == NORTH_WEST
                                || Direction'(source_select_index) == NORTH_EAST)
                            && ((context_destination_tile.piece_type != NULL_PIECE
                                && context_destination_tile.piece_color == WHITE) || ep_move);
                    end
                end
                BISHOP: geometry_ok = isDirDiag(Direction'(source_select_index));
                ROOK: geometry_ok = isDirCardinal(Direction'(source_select_index));
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
                    && (getRank(context_destination) == BoardRank'(0)
                        || getRank(context_destination) == BoardRank'(7));
                source_lane = Direction'(source_select_index);
                source_valid = (GENERATION_COMMAND == MOVE_GEN_GENERATE_NOISY)
                    ? source_is_capture || source_is_promotion
                    : !source_is_capture && !source_is_promotion;
            end
        end else begin
            automatic int knight_index = int'(source_select_index) - 8;
            source = context_knight[knight_index];
            if (source.piece_type == KNIGHT && source.piece_color == job_board.turn) begin
                move.from_pos = shiftKnightPos(context_destination, KnightDirection'(knight_index));
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
    assign cmd_ready = path_ready
        && (cmd == GENERATION_COMMAND
            || (GENERATION_COMMAND == MOVE_GEN_GENERATE_NOISY
                && cmd == MOVE_GEN_VALIDATE_DIRECT));
    assign pop_ready = !init_busy && !pop_pending;
    assign history_update_ready = GENERATION_COMMAND == MOVE_GEN_GENERATE_QUIET
        && !init_busy && history_update_state == HISTORY_UPDATE_IDLE;
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
        update_read_blocked = generator_history_read && job_board.turn == update_color;
        update_write_blocked = generator_history_read && job_board.turn == update_color;

        if (candidate_valid && (candidate_is_capture || candidate_is_promotion)) begin
            bucket_wr_select = noisy_bucket();
            bucket_wr_top = job_tops[bucket_wr_select];
            if (job_tops[bucket_wr_select] < bucket_capacity(bucket_wr_select))
                bucket_wr_en[bucket_wr_select] = 1'b1;
        end else if (candidate_valid) begin
            automatic logic signed [10:0] score;
            score = $signed(history_q[job_board.turn]);
            if (candidate_is_castle) score += 11'sd16;
            bucket_wr_select = quiet_bucket(score);
            bucket_wr_top = job_tops[bucket_wr_select];
            if (job_tops[bucket_wr_select] < bucket_capacity(bucket_wr_select))
                bucket_wr_en[bucket_wr_select] = 1'b1;
        end
    end

    always_comb begin
        for (int color = 0; color < 2; color++) begin
            history_rd_en[color] = 1'b0;
            history_rd_addr[color] = 12'd0;
            history_wr_en[color] = 1'b0;
            history_wr_addr[color] = 12'd0;
            history_wr_data[color] = '0;
            if (init_busy) begin
                history_wr_en[color] = 1'b1;
                history_wr_addr[color] = history_clear_addr;
            end
        end
        if (!init_busy && history_update_state == HISTORY_UPDATE_READ && !update_read_blocked) begin
            history_rd_en[update_color] = 1'b1;
            history_rd_addr[update_color] = update_address;
        end
        if (!init_busy && generator_history_read) begin
            history_rd_en[job_board.turn] = 1'b1;
            history_rd_addr[job_board.turn] = generator_history_read_castle
                ? {castle_candidate_move.from_pos, castle_candidate_move.to_pos}
                : {source_move.from_pos, source_move.to_pos};
        end
        if (!init_busy && history_update_state == HISTORY_UPDATE_WRITE && !update_write_blocked) begin
            automatic logic [6:0] reward_magnitude;
            automatic logic [6:0] magnitude;
            automatic logic signed [7:0] signed_bonus;
            automatic logic signed [16:0] gravity_product;
            automatic logic signed [10:0] updated_history;
            reward_magnitude = (update_depth >= 6'd16) ? 7'd63 : {update_depth[4:0], 2'b00};
            magnitude = update_is_malus ? (reward_magnitude >> 1) : reward_magnitude;
            signed_bonus = update_is_malus
                ? -$signed({1'b0, magnitude}) : $signed({1'b0, magnitude});
            // Gravity makes established history progressively harder to change:
            // H' = H + B - H*|B|/256 for rewards and depth-scaled maluses.
            gravity_product = $signed(update_history_value) * $signed({1'b0, magnitude});
            updated_history = $signed(update_history_value) + signed_bonus
                - (gravity_product >>> HISTORY_LIMIT_SHIFT);
            history_wr_en[update_color] = 1'b1;
            history_wr_addr[update_color] = update_address;
            if (updated_history > 11'sd255)
                history_wr_data[update_color] = 9'sd255;
            else if (updated_history < -11'sd256)
                history_wr_data[update_color] = 9'sh100;
            else
                history_wr_data[update_color] = updated_history[8:0];
        end
    end

    genvar history_color;
    generate
        for (history_color = 0; history_color < 2; history_color++) begin : gen_history
            if (GENERATION_COMMAND == MOVE_GEN_GENERATE_QUIET) begin : gen_ram
                sync_read_simple_dual_port_ram #(
                    .NUM_WORDS(HISTORY_WORDS),
                    .WORD_SIZE(HISTORY_BITS)
                ) history_ram (
                    .clock(clk),
                    .data(history_wr_data[history_color]),
                    .rdaddress(history_rd_addr[history_color]),
                    .rden(history_rd_en[history_color]),
                    .wraddress(history_wr_addr[history_color]),
                    .wren(history_wr_en[history_color]),
                    .q(history_q[history_color])
                );
            end else begin : gen_no_ram
                assign history_q[history_color] = '0;
            end
        end
    endgenerate

    genvar bucket_gen;
    generate
        for (bucket_gen = 0; bucket_gen < MOVE_BUCKET_COUNT; bucket_gen++) begin : gen_bucket_ram
            localparam int CAPACITY = int'(bucket_capacity(MoveBucketIndex'(bucket_gen)));
            localparam int WORDS = THREAD_COUNT * CAPACITY;
            localparam int ADDR_BITS = (WORDS <= 1) ? 1 : $clog2(WORDS);
            if (OWNED_BUCKETS[bucket_gen]) begin : gen_ram
                logic [ADDR_BITS-1:0] rd_addr;
                logic [ADDR_BITS-1:0] wr_addr;
                always_comb begin
                    rd_addr = ADDR_BITS'(int'(bucket_rd_thread) * CAPACITY + int'(bucket_rd_top));
                    wr_addr = ADDR_BITS'(int'(bucket_wr_thread) * CAPACITY + int'(bucket_wr_top));
                end
                sync_read_simple_dual_port_ram #(
                    .NUM_WORDS(WORDS),
                    .WORD_SIZE($bits(Move))
                ) move_ram (
                    .clock(clk),
                    .data(bucket_wr_data),
                    .rdaddress(rd_addr),
                    .rden(bucket_rd_en[bucket_gen]),
                    .wraddress(wr_addr),
                    .wren(bucket_wr_en[bucket_gen]),
                    .q(bucket_q[bucket_gen])
                );
`ifndef SYNTHESIS
                always_ff @(posedge clk) begin
                    if (bucket_wr_en[bucket_gen] && bucket_rd_en[bucket_gen])
                        assert (wr_addr != rd_addr)
                            else $error("simultaneous move-bucket read/write address collision");
                end
`endif
            end else begin : gen_no_ram
                assign bucket_q[bucket_gen] = NULL_MOVE;
            end
        end
    endgenerate

    always_ff @(posedge clk) begin
        if (!rst_n) begin
            state <= GEN_IDLE;
            init_busy <= GENERATION_COMMAND == MOVE_GEN_GENERATE_QUIET;
            history_clear_addr <= 12'd0;
            history_update_state <= HISTORY_UPDATE_IDLE;
            pop_pending <= 1'b0;
            candidate_valid <= 1'b0;
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
                init_busy <= GENERATION_COMMAND == MOVE_GEN_GENERATE_QUIET;
                history_clear_addr <= 12'd0;
                overflow_sticky <= 1'b0;
                overflow_count <= 16'd0;
                history_update_state <= HISTORY_UPDATE_IDLE;
            end else if (init_busy) begin
                if (history_clear_addr == 12'hfff) begin
                    init_busy <= 1'b0;
                end else begin
                    history_clear_addr <= history_clear_addr + 12'd1;
                end
            end

            if (!init_busy) begin
                case (history_update_state)
                    HISTORY_UPDATE_IDLE: begin
                        if (history_update_valid) begin
                            update_color <= history_update_color;
                            update_address <= {history_update_from, history_update_to};
                            update_depth <= history_update_depth;
                            update_failed0 <= history_update_failed0;
                            update_failed1 <= history_update_failed1;
                            update_failed2 <= history_update_failed2;
                            update_failed_count <= history_update_failed_count;
                            update_entry <= 2'd0;
                            update_is_malus <= 1'b0;
                            history_update_state <= HISTORY_UPDATE_READ;
                        end
                    end
                    HISTORY_UPDATE_READ: begin
                        if (!update_read_blocked)
                            history_update_state <= HISTORY_UPDATE_CAPTURE;
                    end
                    HISTORY_UPDATE_CAPTURE: begin
                        update_history_value <= history_q[update_color];
                        history_update_state <= HISTORY_UPDATE_WRITE;
                    end
                    default: begin
                        if (!update_write_blocked) begin
                            if (update_entry < update_failed_count) begin
                                case (update_entry)
                                    2'd0: update_address <= update_failed0;
                                    2'd1: update_address <= update_failed1;
                                    default: update_address <= update_failed2;
                                endcase
                                update_entry <= update_entry + 2'd1;
                                update_is_malus <= 1'b1;
                                history_update_state <= HISTORY_UPDATE_READ;
                            end else begin
                                history_update_state <= HISTORY_UPDATE_IDLE;
                            end
                        end
                    end
                endcase
            end

            if (flush) begin
                state <= GEN_IDLE;
                pop_pending <= 1'b0;
                candidate_valid <= 1'b0;
            end else begin
                if (state != GEN_IDLE && ENABLE_STATS)
                    stat_generation_cycles <= stat_generation_cycles + 40'd1;

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
                                destination_mask <= generation_destination_mask(cmd_board);
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
                            automatic Position destination = first_destination(destination_mask);
                            automatic logic [15:0] next_source_mask = 16'd0;
                            destination_mask[destination] <= 1'b0;
                            for (int dir = 0; dir < 8; dir++) begin
                                automatic RayRecord ray =
                                    nearest_ray(job_board, destination, Direction'(dir));
                                automatic Tile knight =
                                    isKnightShiftOnBoard(destination, KnightDirection'(dir))
                                    ? job_board.tiles[shiftKnightPos(destination, KnightDirection'(dir))]
                                    : EMPTY_TILE;
                                next_source_mask[dir] = potential_ray_source(
                                    job_board, destination,
                                    job_board.tiles[destination], Direction'(dir), ray);
                                next_source_mask[dir + 8] = potential_knight_source(
                                    job_board, job_board.tiles[destination], knight);
                                context_ray[dir] <= ray;
                                context_knight[dir] <= knight;
                            end
                            if (ENABLE_STATS) stat_destination_count <= stat_destination_count + 40'd1;
                            if (next_source_mask != 16'd0) begin
                                context_destination <= destination;
                                context_destination_tile <= job_board.tiles[destination];
                                source_mask <= next_source_mask;
                                state <= GEN_EXPAND_SOURCE;
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
                            if (source_valid) begin
                                candidate_move <= source_move;
                                candidate_attacker <= source_attacker;
                                candidate_victim <= source_victim;
                                candidate_is_capture <= source_is_capture;
                                candidate_is_ep <= source_is_ep;
                                candidate_is_promotion <= source_is_promotion;
                                candidate_is_castle <= 1'b0;
                                candidate_is_knight <= source_is_knight;
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
                                state <= remaining_mask == 16'd0
                                    ? GEN_SELECT_DEST : GEN_EXPAND_SOURCE;
                            end else begin
                                state <= remaining_mask == 16'd0
                                    ? GEN_SELECT_DEST : GEN_EXPAND_SOURCE;
                            end
                        end
                    end

                    GEN_SCORE: begin
                        // Retained encoding for stable profiling; new commands
                        // never enter this state.
                        state <= GEN_SELECT_DEST;
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
                            // The previous castle writes on this edge, so its
                            // incremented top must be observed before response.
                            state <= GEN_FINISH;
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
                        if (!candidate_valid) begin
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

endmodule : move_generator_pipeline

// Dual-class frontend. Noisy and quiet jobs occupy independent pipelines while
// retaining the original single-command and single-pop controller contracts.
module move_generator #(
    parameter int THREAD_COUNT = 1,
    parameter int BUCKET_0_CAPACITY = 512,
    parameter int BUCKET_1_CAPACITY = 512,
    parameter int BUCKET_2_CAPACITY = 512,
    parameter int BUCKET_3_CAPACITY = 512,
    parameter int BUCKET_4_CAPACITY = 512,
    parameter int BUCKET_5_CAPACITY = 512,
    parameter int BUCKET_6_CAPACITY = 512,
    parameter int BUCKET_7_CAPACITY = 512,
    parameter bit ASSERT_ON_OVERFLOW = 1'b1,
    parameter bit ENABLE_STATS = 1'b0
) (
    input logic clk,
    input logic rst_n,
    input logic clear,
    input logic flush,
    output logic init_busy,

    input logic noisy_cmd_valid,
    output logic noisy_cmd_ready,
    input MoveGenCommand noisy_cmd,
    input ThreadID noisy_cmd_thread,
    input PlyIndex noisy_cmd_ply,
    input FullBoard noisy_cmd_board,
    input logic noisy_cmd_suppress_valid,
    input Move noisy_cmd_suppress_move,
    input MoveBucketTops noisy_cmd_bucket_tops,
    output logic noisy_resp_valid,
    output ThreadID noisy_resp_thread,
    output PlyIndex noisy_resp_ply,
    output logic noisy_resp_direct_valid,
    output Move noisy_resp_direct_move,
    output MoveBucketTops noisy_resp_bucket_tops,

    input logic quiet_cmd_valid,
    output logic quiet_cmd_ready,
    input ThreadID quiet_cmd_thread,
    input PlyIndex quiet_cmd_ply,
    input FullBoard quiet_cmd_board,
    input logic quiet_cmd_suppress_valid,
    input Move quiet_cmd_suppress_move,
    input MoveBucketTops quiet_cmd_bucket_tops,
    output logic quiet_resp_valid,
    output ThreadID quiet_resp_thread,
    output PlyIndex quiet_resp_ply,
    output MoveBucketTops quiet_resp_bucket_tops,

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
    input logic [5:0] history_update_depth,
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

    localparam MoveBucketMask NOISY_BUCKET_MASK =
        GOOD_NOISY_BUCKET_MASK | BAD_NOISY_BUCKET_MASK;

    logic noisy_init_busy, quiet_init_busy;
    logic noisy_pop_ready, quiet_pop_ready;
    logic noisy_pop_resp_valid, quiet_pop_resp_valid;
    ThreadID noisy_pop_resp_thread, quiet_pop_resp_thread;
    PlyIndex noisy_pop_resp_ply, quiet_pop_resp_ply;
    logic noisy_pop_resp_found, quiet_pop_resp_found;
    Move noisy_pop_resp_move, quiet_pop_resp_move;
    MoveBucketIndex noisy_pop_resp_bucket, quiet_pop_resp_bucket;
    MoveBucketTop noisy_pop_resp_new_top, quiet_pop_resp_new_top;
    logic quiet_history_update_ready;
    logic noisy_overflow_sticky, quiet_overflow_sticky;
    ThreadID noisy_overflow_thread, quiet_overflow_thread;
    MoveBucketIndex noisy_overflow_bucket, quiet_overflow_bucket;
    logic [15:0] noisy_overflow_count, quiet_overflow_count;
    logic [39:0] noisy_stat_noisy_count, quiet_stat_noisy_count;
    logic [39:0] noisy_stat_quiet_count, quiet_stat_quiet_count;
    logic [39:0] noisy_stat_destination_count, quiet_stat_destination_count;
    logic [39:0] noisy_stat_candidate_count, quiet_stat_candidate_count;
    logic [39:0] noisy_stat_history_lookup_count, quiet_stat_history_lookup_count;
    logic [39:0] noisy_stat_generation_cycles, quiet_stat_generation_cycles;
    logic [39:0] noisy_stat_bucket_count[MOVE_BUCKET_COUNT];
    logic [39:0] quiet_stat_bucket_count[MOVE_BUCKET_COUNT];
    MoveBucketTop noisy_stat_bucket_high_water[MOVE_BUCKET_COUNT];
    MoveBucketTop quiet_stat_bucket_high_water[MOVE_BUCKET_COUNT];

    logic pop_use_quiet;
    logic noisy_good_available, quiet_available, noisy_bad_available;

    always_comb begin
        noisy_good_available = 1'b0;
        quiet_available = 1'b0;
        noisy_bad_available = 1'b0;
        for (int bucket = 0; bucket < MOVE_BUCKET_COUNT; bucket++) begin
            automatic logic available = pop_eligible[bucket]
                && pop_current_tops[bucket] != pop_lower_tops[bucket];
            if (bucket >= int'(GOOD_NOISY_LOW_BUCKET)) noisy_good_available |= available;
            else if (bucket >= int'(QUIET_LOW_BUCKET)) quiet_available |= available;
            else noisy_bad_available |= available;
        end
        // Preserve global bucket priority even when a caller supplies ALL_BUCKET_MASK.
        pop_use_quiet = !noisy_good_available
            && (quiet_available
                || (!noisy_bad_available
                    && (pop_eligible & QUIET_BUCKET_MASK) != MoveBucketMask'(0)));
    end

    assign init_busy = noisy_init_busy || quiet_init_busy;
    assign pop_ready = pop_use_quiet ? quiet_pop_ready : noisy_pop_ready;
    assign history_update_ready = quiet_history_update_ready;

    assign pop_resp_valid = noisy_pop_resp_valid || quiet_pop_resp_valid;
    assign pop_resp_thread = noisy_pop_resp_valid ? noisy_pop_resp_thread : quiet_pop_resp_thread;
    assign pop_resp_ply = noisy_pop_resp_valid ? noisy_pop_resp_ply : quiet_pop_resp_ply;
    assign pop_resp_found = noisy_pop_resp_valid ? noisy_pop_resp_found : quiet_pop_resp_found;
    assign pop_resp_move = noisy_pop_resp_valid ? noisy_pop_resp_move : quiet_pop_resp_move;
    assign pop_resp_bucket = noisy_pop_resp_valid ? noisy_pop_resp_bucket : quiet_pop_resp_bucket;
    assign pop_resp_new_top = noisy_pop_resp_valid
        ? noisy_pop_resp_new_top : quiet_pop_resp_new_top;

    assign overflow_sticky = noisy_overflow_sticky || quiet_overflow_sticky;
    assign overflow_thread = noisy_overflow_sticky ? noisy_overflow_thread : quiet_overflow_thread;
    assign overflow_bucket = noisy_overflow_sticky ? noisy_overflow_bucket : quiet_overflow_bucket;
    assign overflow_count = noisy_overflow_count + quiet_overflow_count;
    assign stat_noisy_count = noisy_stat_noisy_count + quiet_stat_noisy_count;
    assign stat_quiet_count = noisy_stat_quiet_count + quiet_stat_quiet_count;
    assign stat_destination_count =
        noisy_stat_destination_count + quiet_stat_destination_count;
    assign stat_candidate_count = noisy_stat_candidate_count + quiet_stat_candidate_count;
    assign stat_history_lookup_count =
        noisy_stat_history_lookup_count + quiet_stat_history_lookup_count;
    assign stat_generation_cycles =
        noisy_stat_generation_cycles + quiet_stat_generation_cycles;
    always_comb begin
        for (int bucket = 0; bucket < MOVE_BUCKET_COUNT; bucket++) begin
            stat_bucket_count[bucket] = NOISY_BUCKET_MASK[bucket]
                ? noisy_stat_bucket_count[bucket] : quiet_stat_bucket_count[bucket];
            stat_bucket_high_water[bucket] = NOISY_BUCKET_MASK[bucket]
                ? noisy_stat_bucket_high_water[bucket] : quiet_stat_bucket_high_water[bucket];
        end
    end

    move_generator_pipeline #(
        .THREAD_COUNT(THREAD_COUNT),
        .BUCKET_0_CAPACITY(BUCKET_0_CAPACITY), .BUCKET_1_CAPACITY(BUCKET_1_CAPACITY),
        .BUCKET_2_CAPACITY(BUCKET_2_CAPACITY), .BUCKET_3_CAPACITY(BUCKET_3_CAPACITY),
        .BUCKET_4_CAPACITY(BUCKET_4_CAPACITY), .BUCKET_5_CAPACITY(BUCKET_5_CAPACITY),
        .BUCKET_6_CAPACITY(BUCKET_6_CAPACITY), .BUCKET_7_CAPACITY(BUCKET_7_CAPACITY),
        .GENERATION_COMMAND(MOVE_GEN_GENERATE_NOISY), .OWNED_BUCKETS(NOISY_BUCKET_MASK),
        .ASSERT_ON_OVERFLOW(ASSERT_ON_OVERFLOW), .ENABLE_STATS(ENABLE_STATS)
    ) noisy_pipeline (
        .clk, .rst_n, .clear, .flush, .init_busy(noisy_init_busy),
        .path_ready(),
        .cmd_valid(noisy_cmd_valid), .cmd_ready(noisy_cmd_ready), .cmd(noisy_cmd),
        .cmd_thread(noisy_cmd_thread), .cmd_ply(noisy_cmd_ply), .cmd_board(noisy_cmd_board),
        .cmd_suppress_valid(noisy_cmd_suppress_valid),
        .cmd_suppress_move(noisy_cmd_suppress_move),
        .cmd_bucket_tops(noisy_cmd_bucket_tops),
        .cmd_resp_valid(noisy_resp_valid), .cmd_resp_thread(noisy_resp_thread),
        .cmd_resp_ply(noisy_resp_ply), .cmd_resp_direct_valid(noisy_resp_direct_valid),
        .cmd_resp_direct_move(noisy_resp_direct_move),
        .cmd_resp_bucket_tops(noisy_resp_bucket_tops),
        .pop_valid(pop_valid && !pop_use_quiet), .pop_ready(noisy_pop_ready),
        .pop_thread, .pop_ply, .pop_eligible(pop_eligible & NOISY_BUCKET_MASK),
        .pop_current_tops, .pop_lower_tops,
        .pop_resp_valid(noisy_pop_resp_valid), .pop_resp_thread(noisy_pop_resp_thread),
        .pop_resp_ply(noisy_pop_resp_ply), .pop_resp_found(noisy_pop_resp_found),
        .pop_resp_move(noisy_pop_resp_move), .pop_resp_bucket(noisy_pop_resp_bucket),
        .pop_resp_new_top(noisy_pop_resp_new_top),
        .history_update_valid(1'b0), .history_update_ready(),
        .history_update_color, .history_update_from, .history_update_to, .history_update_depth,
        .history_update_failed0, .history_update_failed1, .history_update_failed2,
        .history_update_failed_count,
        .overflow_sticky(noisy_overflow_sticky), .overflow_thread(noisy_overflow_thread),
        .overflow_bucket(noisy_overflow_bucket), .overflow_count(noisy_overflow_count),
        .stat_noisy_count(noisy_stat_noisy_count), .stat_quiet_count(noisy_stat_quiet_count),
        .stat_destination_count(noisy_stat_destination_count),
        .stat_candidate_count(noisy_stat_candidate_count),
        .stat_history_lookup_count(noisy_stat_history_lookup_count),
        .stat_generation_cycles(noisy_stat_generation_cycles),
        .stat_bucket_count(noisy_stat_bucket_count),
        .stat_bucket_high_water(noisy_stat_bucket_high_water)
    );

    move_generator_pipeline #(
        .THREAD_COUNT(THREAD_COUNT),
        .BUCKET_0_CAPACITY(BUCKET_0_CAPACITY), .BUCKET_1_CAPACITY(BUCKET_1_CAPACITY),
        .BUCKET_2_CAPACITY(BUCKET_2_CAPACITY), .BUCKET_3_CAPACITY(BUCKET_3_CAPACITY),
        .BUCKET_4_CAPACITY(BUCKET_4_CAPACITY), .BUCKET_5_CAPACITY(BUCKET_5_CAPACITY),
        .BUCKET_6_CAPACITY(BUCKET_6_CAPACITY), .BUCKET_7_CAPACITY(BUCKET_7_CAPACITY),
        .GENERATION_COMMAND(MOVE_GEN_GENERATE_QUIET), .OWNED_BUCKETS(QUIET_BUCKET_MASK),
        .ASSERT_ON_OVERFLOW(ASSERT_ON_OVERFLOW), .ENABLE_STATS(ENABLE_STATS)
    ) quiet_pipeline (
        .clk, .rst_n, .clear, .flush, .init_busy(quiet_init_busy),
        .path_ready(),
        .cmd_valid(quiet_cmd_valid), .cmd_ready(quiet_cmd_ready),
        .cmd(MOVE_GEN_GENERATE_QUIET),
        .cmd_thread(quiet_cmd_thread), .cmd_ply(quiet_cmd_ply), .cmd_board(quiet_cmd_board),
        .cmd_suppress_valid(quiet_cmd_suppress_valid),
        .cmd_suppress_move(quiet_cmd_suppress_move),
        .cmd_bucket_tops(quiet_cmd_bucket_tops),
        .cmd_resp_valid(quiet_resp_valid), .cmd_resp_thread(quiet_resp_thread),
        .cmd_resp_ply(quiet_resp_ply), .cmd_resp_direct_valid(),
        .cmd_resp_direct_move(),
        .cmd_resp_bucket_tops(quiet_resp_bucket_tops),
        .pop_valid(pop_valid && pop_use_quiet), .pop_ready(quiet_pop_ready),
        .pop_thread, .pop_ply, .pop_eligible(pop_eligible & QUIET_BUCKET_MASK),
        .pop_current_tops, .pop_lower_tops,
        .pop_resp_valid(quiet_pop_resp_valid), .pop_resp_thread(quiet_pop_resp_thread),
        .pop_resp_ply(quiet_pop_resp_ply), .pop_resp_found(quiet_pop_resp_found),
        .pop_resp_move(quiet_pop_resp_move), .pop_resp_bucket(quiet_pop_resp_bucket),
        .pop_resp_new_top(quiet_pop_resp_new_top),
        .history_update_valid, .history_update_ready(quiet_history_update_ready),
        .history_update_color, .history_update_from, .history_update_to, .history_update_depth,
        .history_update_failed0, .history_update_failed1, .history_update_failed2,
        .history_update_failed_count,
        .overflow_sticky(quiet_overflow_sticky), .overflow_thread(quiet_overflow_thread),
        .overflow_bucket(quiet_overflow_bucket), .overflow_count(quiet_overflow_count),
        .stat_noisy_count(quiet_stat_noisy_count), .stat_quiet_count(quiet_stat_quiet_count),
        .stat_destination_count(quiet_stat_destination_count),
        .stat_candidate_count(quiet_stat_candidate_count),
        .stat_history_lookup_count(quiet_stat_history_lookup_count),
        .stat_generation_cycles(quiet_stat_generation_cycles),
        .stat_bucket_count(quiet_stat_bucket_count),
        .stat_bucket_high_water(quiet_stat_bucket_high_water)
    );

endmodule : move_generator
