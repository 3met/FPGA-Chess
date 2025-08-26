
// By Emet Behrendt

import general_chess_defs::*;
import chess_helper_funcs::*;
import board_controller_defs::*;

module board_controller (
    input wire clk,
    input BoardOp board_op,
    input wire FullBoard board_in,
    input BoardHash board_hash_in,
    input EvalScore pst_eval_in,
    input wire Move move_in,
    input logic [3:0] set_data, // Either a tile, turn, castle perms, or en passant info depending on the set operation.
    input ThreadID thread_id,
    input DepthType search_depth,

    output FullBoard board_out,
    output BoardHash board_hash_out,
    output EvalScore pst_eval_out
);

    BoardControllerCtx ctx_pipe[7];
    BoardControllerCtx next_ctx_pipe[7];

    logic [$clog2(MAX_PLY_COUNT*THREAD_COUNT)-1:0] move_hist_rd_addr;

    // --- Memory Block storing Move Records ---
    MoveRecord move_record_in, move_record_out;
    logic [$clog2(THREAD_COUNT)+$clog2(MAX_PLY_COUNT)-1:0] move_record_rd_addr, move_record_wr_addr;
    logic move_record_rd_en, move_record_wr_en;

    simple_dual_port_ram #(.NUM_WORDS(THREAD_COUNT * MAX_PLY_COUNT), .WORD_SIZE($bits(MoveRecord))) move_hist_mem (
        .clock(clk),
        .data(move_record_in),
        .rdaddress(move_record_rd_addr),
        .rden(move_record_rd_en),
        .wraddress(move_record_wr_addr),
        .wren(move_record_wr_en),
        .q(move_record_out)
    );

    // --- ROM BRAM storing Zobrist Hashes ---



    // --- Extra Zobrist Hashes for Turn, En Passant, and Castle Perms ---
    BoardHash zobrist_turn = BoardHash'(32'h57304564);
    BoardHash zobrist_ep_file[8] = {
        BoardHash'(32'h57304564 * 3),
        BoardHash'(32'h57304564 * 5),
        BoardHash'(32'h57304564 * 7),
        BoardHash'(32'h57304564 * 11),
        BoardHash'(32'h57304564 * 13),
        BoardHash'(32'h57304564 * 17),
        BoardHash'(32'h57304564 * 19),
        BoardHash'(32'h57304564 * 23)
    };
    BoardHash zobrist_castle_perms[4] = {
        BoardHash'(32'h57304564 * 27),
        BoardHash'(32'h57304564 * 31),
        BoardHash'(32'h57304564 * 37),
        BoardHash'(32'h57304564 * 41)
    };

    // --- Piece-Square Table ROM ---
    logic [3+6-1:0] pst_start_addr, pst_end_addr, pst_killed_addr, pst_castle_rook_addr;
    logic pst_start_rd_en, pst_end_rd_en, pst_killed_rd_en, pst_castle_rook_rd_en;
    EvalScore pst_start_out, pst_end_out, pst_killed_out, pst_castle_out;

    dual_port_rom #(
        .NUM_WORDS(6 * 64),
        .WORD_SIZE($bits(EvalScore)),
        .MEM_INIT_FILE("./hardware/data/pst_values/pst_values.mif")
    ) pst_rom_0 (
        .address_a({pst_start_addr[8:6]-3'd1, pst_start_addr[5:0]}),
        .address_b({pst_end_addr[8:6]-3'd1, pst_end_addr[5:0]}),
        .clock(clk),
        .rden_a(pst_start_rd_en),
        .rden_b(pst_end_rd_en),
        .q_a(pst_start_out),
        .q_b(pst_end_out)
    );
    dual_port_rom #(
        .NUM_WORDS(6 * 64),
        .WORD_SIZE($bits(EvalScore)),
        .MEM_INIT_FILE("./hardware/data/pst_values/pst_values.mif")
    ) pst_rom_1 (
        .address_a({pst_killed_addr[8:6]-3'd1, pst_killed_addr[5:0]}),
        .address_b({pst_castle_rook_addr[8:6]-3'd1, pst_castle_rook_addr[5:0]}),
        .clock(clk),
        .rden_a(pst_killed_rd_en),
        .rden_b(pst_castle_rook_rd_en),
        .q_a(pst_killed_out),
        .q_b(pst_castle_out)
    );
    

    // Assign Outputs
    assign board_out = ctx_pipe[6].board;
    assign board_hash_out = ctx_pipe[6].board_hash;
    assign pst_eval_out = ctx_pipe[6].pst_eval;

    // Move data down the pipeline
    always_ff @(posedge clk) begin
        ctx_pipe = next_ctx_pipe;
    end


    // Pipeline Stage 0 (Register Initial Inputs)
    always_comb begin
        next_ctx_pipe[0].board_op   = board_op;
        next_ctx_pipe[0].board      = board_in;
        next_ctx_pipe[0].board_hash = board_hash_in;
        next_ctx_pipe[0].pst_eval   = pst_eval_in;
        next_ctx_pipe[0].move       = move_in;
        next_ctx_pipe[0].set_data   = set_data;
        next_ctx_pipe[0].thread_id  = thread_id;

        move_record_rd_addr = {thread_id, search_depth - DepthType'('d1)};
        move_record_rd_en = (board_op == BOARD_REVERSE_MOVE_OP);
    end


    // Pipeline Stage 1 (Invert the PST score when the color to play is changing)
    always_comb begin
        automatic BoardControllerCtx in = ctx_pipe[0];
        automatic BoardControllerCtx out;

        // By default nothing changes
        out = in;

        case (ctx_pipe[0].board_op)
            BOARD_PUSH_MOVE_OP, BOARD_COMMIT_MOVE_OP, BOARD_REVERSE_MOVE_OP: begin
                out.pst_eval = -(in.pst_eval);
            end

            // Only invert PST if color turn actually changes
            BOARD_SET_TURN_OP: begin
                if (in.board.turn != in.set_data[0]) begin
                    out.pst_eval = -(in.pst_eval);
                end
            end

            // Don't care about idle operation
            BOARD_IDLE_OP: begin
                out = BoardControllerCtx'('dx);
                out.board_op = in.board_op;
            end
        endcase

        next_ctx_pipe[1] = out;
    end

    // Pipeline Stage 2 (Idle)
    always_comb begin
        next_ctx_pipe[2] = ctx_pipe[1];
    end


    // Pipeline Stage 3 (Update Primary Tiles and Fetch PST and Zobrist Values)
    always_comb begin
        automatic BoardControllerCtx in = ctx_pipe[2];
        automatic BoardControllerCtx out;
        
        // By default nothing changes
        out = in;

        // Disable all reads by default to save power
        pst_start_rd_en = 1'b0;
        pst_end_rd_en = 1'b0;
        pst_killed_rd_en = 1'b0;
        pst_castle_rook_rd_en = 1'b0;

        // Default to not caring is these values are set
        out.is_ep = 1'bx;
        out.is_castle = 1'bx;
        out.is_pawn_move = 1'bx;

        case (in.board_op)
            // Forward Moves
            BOARD_PUSH_MOVE_OP, BOARD_COMMIT_MOVE_OP: begin
                automatic Position start_pos = in.move.start_pos;
                automatic Position end_pos = in.move.end_pos;
                automatic Tile start_tile = in.board.tiles[start_pos];
                automatic Tile end_tile = in.board.tiles[end_pos];

                automatic logic is_promo = (start_tile.piece_type == PAWN && (getRank(end_pos) == BoardFile'('d0) || getRank(end_pos) == BoardFile'('d7)));
                automatic logic is_castle = (start_tile.piece_type == KING && getFile(start_pos) == BoardFile'('d4) && (getFile(end_pos) == BoardFile'('d2) || getFile(end_pos) == BoardFile'('d6)));
                automatic logic is_ep = (start_tile.piece_type == PAWN && in.board.has_ep && in.board.ep_file == getFile(end_pos) && ((in.board.turn == WHITE && getRank(end_pos) == BoardRank'('d5)) || (in.board.turn == BLACK && getRank(end_pos) == BoardRank'('d2))));

                // Set starting tile to be empty
                out.board.tiles[start_pos] = EMPTY_TILE;

                // Check for promotions and promote to new piece
                if (is_promo) begin
                    out.board.tiles[end_pos].piece_color = start_tile.piece_color; // Copy Piece Color

                    case (in.move.promo_piece)
                        PROMO_QUEEN:  out.board.tiles[end_pos].piece_type = QUEEN;
                        PROMO_KNIGHT: out.board.tiles[end_pos].piece_type = KNIGHT;
                        PROMO_ROOK:   out.board.tiles[end_pos].piece_type = ROOK;
                        PROMO_BISHOP: out.board.tiles[end_pos].piece_type = BISHOP;
                    endcase
                // Else no promotion, move piece as normal
                end else begin
                    out.board.tiles[end_pos] = start_tile;
                end

                // --- Fetch PST values ---
                // Positions mirrored when moving black pieces

                // Starting tile is always cleared
                pst_start_addr = {start_tile.piece_type, (in.board.turn == BLACK ? mirrorPos(start_pos) : start_pos)};
                pst_start_rd_en = 1'b1;

                // Ending tile matches starting tile expect in case of en passant
                if (is_promo) begin
                    case (in.move.promo_piece)
                        PROMO_QUEEN:  pst_end_addr = {QUEEN,  (in.board.turn == BLACK ? mirrorPos(end_pos) : end_pos)};
                        PROMO_KNIGHT: pst_end_addr = {KNIGHT, (in.board.turn == BLACK ? mirrorPos(end_pos) : end_pos)};
                        PROMO_ROOK:   pst_end_addr = {ROOK,   (in.board.turn == BLACK ? mirrorPos(end_pos) : end_pos)};
                        PROMO_BISHOP: pst_end_addr = {BISHOP, (in.board.turn == BLACK ? mirrorPos(end_pos) : end_pos)};
                    endcase
                end else begin
                    pst_end_addr = {start_tile.piece_type, (in.board.turn == BLACK ? mirrorPos(end_pos) : end_pos)};
                end
                pst_end_rd_en = 1'b1;

                // Remove killed piece or in the case of a castle the rook starting position
                if (is_ep) begin
                    pst_killed_addr = {PAWN, (in.board.turn == BLACK ? Position'({getRank(start_pos), getFile(end_pos)}) : mirrorPos({getRank(start_pos), getFile(end_pos)}))};
                    pst_killed_rd_en = 1'b1;
                end else if (is_castle) begin
                    case (in.move.end_pos)
                        Position'('d2):  pst_killed_addr = {ROOK, Position'('d0 )};
                        Position'('d6):  pst_killed_addr = {ROOK, Position'('d7 )};
                        Position'('d62): pst_killed_addr = {ROOK, mirrorPos('d63)};
                        Position'('d58): pst_killed_addr = {ROOK, mirrorPos('d56)};
                        default: pst_killed_addr = 'dx;
                    endcase
                    pst_killed_rd_en = 1'b1;
                end else begin
                    pst_killed_addr = {end_tile.piece_type, (in.board.turn == BLACK ? end_pos : mirrorPos(end_pos))};
                    pst_killed_rd_en = (end_tile.piece_type != NULL_PIECE);
                end

                // Place rook in new position in case of castle
                if (is_castle) begin
                    case (in.move.end_pos)
                        Position'('d2):  pst_castle_rook_addr = {ROOK, Position'('d3 )};
                        Position'('d6):  pst_castle_rook_addr = {ROOK, Position'('d5 )};
                        Position'('d62): pst_castle_rook_addr = {ROOK, mirrorPos('d61)};
                        Position'('d58): pst_castle_rook_addr = {ROOK, mirrorPos('d59)};
                        default: pst_castle_rook_addr = 'dx;
                    endcase
                    pst_castle_rook_rd_en = 1'b1;
                end else begin
                    pst_castle_rook_addr = 'dx;
                end

                // --- Update Move Record ---
                // If making a reversable move, store data about current move
                // Stored record only written back if the move is meant to be reversable
                out.move_record.start_pos = start_pos;
                out.move_record.end_pos = end_pos;
                out.move_record.killed_piece = end_tile.piece_type; // Correct for En Passant kills as NULL PIECE
                out.move_record.castle_perms = in.board.castle_perms;
                out.move_record.move_flag = (is_promo ? PROMO_MOVE : is_castle ? CASTLE_MOVE : is_ep ? EP_MOVE : NORM_MOVE);
                out.move_record.has_ep = in.board.has_ep;
                out.move_record.ep_file = in.board.ep_file;
                out.move_record.halfmove_clk = in.board.halfmove_clk;

                // Flag special moves for later stages
                out.is_castle = is_castle;
                out.is_ep = is_ep;
                out.is_pawn_move = (start_tile.piece_type == PAWN);
            end

            // Reverse Move
            BOARD_REVERSE_MOVE_OP: begin
                automatic Position start_pos = move_record_out.start_pos;
                automatic Position end_pos = move_record_out.end_pos;
                automatic Tile end_tile = in.board.tiles[end_pos];
                automatic Color turn = in.board.turn;
                automatic logic is_promo  = (move_record_out.move_flag == PROMO_MOVE);
                automatic logic is_ep     = (move_record_out.move_flag == EP_MOVE);
                automatic logic is_castle = (move_record_out.move_flag == CASTLE_MOVE);

                // If move was a promotion, be sure to demote
                if (is_promo) begin
                    out.board.tiles[start_pos] = Tile'({~turn, PAWN});
                end else begin
                    out.board.tiles[start_pos] = Tile'({~turn, end_tile.piece_type});
                end

                out.board.tiles[end_pos] = Tile'({turn, move_record_out.killed_piece}); // Will write NULL_PIECE for EP kill and killed pawn will be added later


                // -- Fetch PST Values --
                // Positions mirrored when moving black pieces (by checking if turn is current WHITE)

                // Starting tille gets copied from desination tile except in the case of promotion
                if (is_promo) begin
                    pst_start_addr = {PAWN, (in.board.turn == WHITE ? mirrorPos(start_pos) : start_pos)};
                end else begin
                    pst_start_addr = {end_tile.piece_type, (in.board.turn == WHITE ? mirrorPos(start_pos) : start_pos)};
                end
                pst_start_rd_en = 1'b1;

                // Remove moving piece from ending tile
                pst_end_addr = {end_tile.piece_type, (in.board.turn == WHITE ? mirrorPos(end_pos) : end_pos)};
                pst_end_rd_en = 1'b1;

                // Add previously killed piece or in the case of a castle the rook on the starting position
                if (is_ep) begin
                    pst_killed_addr = {PAWN, (in.board.turn == WHITE ? Position'({getRank(start_pos), getFile(end_pos)}) : mirrorPos({getRank(start_pos), getFile(end_pos)}))};
                    pst_killed_rd_en = 1'b1;
                end else if (is_castle) begin
                    case (move_record_out.end_pos)
                        Position'('d2):  pst_killed_addr = {ROOK, Position'('d0 )};
                        Position'('d6):  pst_killed_addr = {ROOK, Position'('d7 )};
                        Position'('d62): pst_killed_addr = {ROOK, mirrorPos('d63)};
                        Position'('d58): pst_killed_addr = {ROOK, mirrorPos('d56)};
                        default: pst_killed_addr = 'dx;
                    endcase
                    pst_killed_rd_en = 1'b1;
                end else begin
                    pst_killed_addr = {move_record_out.killed_piece, (in.board.turn == WHITE ? end_pos : mirrorPos(end_pos))};
                    pst_killed_rd_en = (move_record_out.killed_piece != NULL_PIECE);
                end

                // Remove rook placed during castle operation
                if (is_castle) begin
                    case (move_record_out.end_pos)
                        Position'('d2):  pst_castle_rook_addr = {ROOK, Position'('d3 )};
                        Position'('d6):  pst_castle_rook_addr = {ROOK, Position'('d5 )};
                        Position'('d62): pst_castle_rook_addr = {ROOK, mirrorPos('d61)};
                        Position'('d58): pst_castle_rook_addr = {ROOK, mirrorPos('d59)};
                        default: pst_castle_rook_addr = 'dx;
                    endcase
                    pst_castle_rook_rd_en = 1'b1;
                end else begin
                    pst_castle_rook_addr = 'dx;
                end

                // Store move record
                out.move_record = move_record_out;

                // Flag special moves for later stages
                out.is_castle = is_castle;
                out.is_ep = is_ep;
            end

            // Place Piece
            BOARD_SET_TILE_OP: begin
                automatic Position end_pos = in.move.end_pos;
                automatic Tile new_tile = Tile'(in.set_data);

                out.board.tiles[end_pos] = new_tile;

                // Place piece on the board
                pst_end_addr = {new_tile.piece_type, (new_tile.piece_color == BLACK ? mirrorPos(end_pos) : end_pos)};
                pst_end_rd_en = (new_tile.piece_type != NULL_PIECE);

                // Remove piece killed by placement
                pst_killed_addr = {in.board.tiles[end_pos].piece_type, (in.board.tiles[end_pos].piece_color == BLACK ? mirrorPos(end_pos) : end_pos)};
                pst_killed_rd_en = (in.board.tiles[end_pos].piece_type != NULL_PIECE);

                // Set only killed piece in move record
                out.move_record = MoveRecord'('dx);
                out.move_record.killed_piece = in.board.tiles[end_pos].piece_type; // Correct for En Passant kills as NULL PIECE

                // Set flag
                out.overwritten_color_has_turn = (in.board.tiles[end_pos].piece_color == in.board.turn);
            end

            // Don't care about idle operation
            BOARD_IDLE_OP: begin
                out = BoardControllerCtx'('dx);
                out.board_op = in.board_op;
            end
        endcase

        // Write all changes down pipeline
        next_ctx_pipe[3] = out;
    end


    // Pipeline Stage 4 (Clear extra tile for en passant and castling + write move record)
    always_comb begin
        automatic BoardControllerCtx in = ctx_pipe[3];
        automatic BoardControllerCtx out;

        // By default nothing changes
        out = in;

        case (in.board_op)
            // Clear extra tile with forward move
            BOARD_PUSH_MOVE_OP, BOARD_COMMIT_MOVE_OP: begin
                if (in.is_ep) begin
                    if (in.board.turn == WHITE) begin
                        out.board.tiles[{BoardRank'(4), getFile(in.move.end_pos)}] = EMPTY_TILE;
                    end else begin
                        out.board.tiles[{BoardRank'(3), getFile(in.move.end_pos)}] = EMPTY_TILE;
                    end
                end 
                
                if (in.is_castle) begin
                    case (in.move.end_pos)
                        Position'('d2):  out.board.tiles['d0] = EMPTY_TILE;
                        Position'('d6):  out.board.tiles['d7] = EMPTY_TILE;
                        Position'('d62): out.board.tiles['d63] = EMPTY_TILE;
                        Position'('d58): out.board.tiles['d56] = EMPTY_TILE;
                        default: out.board.tiles = 'dx;
                    endcase
                end 
                
                // is_ep and is_castle should never both be asserted
                if (in.is_ep && in.is_castle) begin
                    out.board.tiles = 'dx;
                end
            end

            // Undo cleared extra tile for reverse move
            BOARD_REVERSE_MOVE_OP: begin
                if (in.is_ep) begin
                    if (in.board.turn == BLACK) begin
                        out.board.tiles[{BoardRank'(4), getFile(in.move_record.end_pos)}] = BLACK_PAWN;
                    end else begin
                        out.board.tiles[{BoardRank'(3), getFile(in.move_record.end_pos)}] = WHITE_PAWN;
                    end
                end

                if (in.is_castle) begin
                    case (in.move_record.end_pos)
                        Position'('d2):  out.board.tiles['d0]  = WHITE_ROOK;
                        Position'('d6):  out.board.tiles['d7]  = WHITE_ROOK;
                        Position'('d62): out.board.tiles['d63] = BLACK_ROOK;
                        Position'('d58): out.board.tiles['d56] = BLACK_ROOK;
                        default: out.board.tiles = 'dx;
                    endcase
                end

                // is_ep and is_castle should never both be asserted
                if (in.is_ep && in.is_castle) begin
                    out.board.tiles = 'dx;
                end
            end

            // Don't care about idle operation
            BOARD_IDLE_OP: begin
                out = BoardControllerCtx'('dx);
                out.board_op = in.board_op;
            end
        endcase

        // Write move record
        move_record_in = in.move_record;
        move_record_wr_en = (in.board_op == BOARD_PUSH_MOVE_OP);
        move_record_wr_addr = {thread_id, search_depth};
        
        // Write all changes down pipeline
        next_ctx_pipe[4] = out;
    end


    // Pipeline Stage 5 (Update placing extra rook in castle operations and update)
    always_comb begin
        automatic BoardControllerCtx in = ctx_pipe[4];
        automatic BoardControllerCtx out;

        // By default nothing changes
        out = in;

        case (in.board_op)
            // In the case of a castle, place an extra rook on the board
            BOARD_PUSH_MOVE_OP, BOARD_COMMIT_MOVE_OP: begin
                if (in.is_castle) begin
                    case (in.move.end_pos)
                        Position'('d2):  out.board.tiles['d3 ] = WHITE_ROOK;
                        Position'('d6):  out.board.tiles['d5 ] = WHITE_ROOK;
                        Position'('d62): out.board.tiles['d61] = BLACK_ROOK;
                        Position'('d58): out.board.tiles['d59] = BLACK_ROOK;
                        default: out.board.tiles = 'dx;
                    endcase
                end

                // --- Add killed piece to PST score ---
                if (in.is_ep) begin
                    out.pst_eval -= PIECE_VALS_128[PAWN];
                end else begin
                    out.pst_eval -= PIECE_VALS_128[in.move_record.killed_piece];
                    if (in.move_record.killed_piece == KING) out.pst_eval = EvalScore'('dx); // Killed piece should never be a king
                end
            end

            // Remove extra castle placed on the board
            BOARD_REVERSE_MOVE_OP: begin
                if (in.is_castle) begin
                    case (in.move_record.end_pos)
                        Position'('d2):  out.board.tiles['d3 ] = EMPTY_TILE;
                        Position'('d6):  out.board.tiles['d5 ] = EMPTY_TILE;
                        Position'('d62): out.board.tiles['d61] = EMPTY_TILE;
                        Position'('d58): out.board.tiles['d59] = EMPTY_TILE;
                        default: out.board.tiles = 'dx;
                    endcase
                end

                // --- Subtract revived piece from killed piece to PST score ---
                if (in.is_ep) begin
                    out.pst_eval -= PIECE_VALS_128[PAWN];
                end else begin
                    out.pst_eval -= PIECE_VALS_128[in.move_record.killed_piece];
                    if (in.move_record.killed_piece == KING) out.pst_eval = EvalScore'('dx); // Killed piece should never be a king
                end
            end

            BOARD_SET_TILE_OP: begin
                automatic Tile new_tile = Tile'(in.set_data);

                // --- Add new piece and remove killed piece ---
                out.pst_eval += (new_tile.piece_color == in.board.turn ? PIECE_VALS_128[new_tile.piece_type] : -PIECE_VALS_128[new_tile.piece_type]);
                out.pst_eval += (in.overwritten_color_has_turn ? -PIECE_VALS_128[in.move_record.killed_piece] : PIECE_VALS_128[in.move_record.killed_piece]);
            end

            // Don't care about idle operation
            BOARD_IDLE_OP: begin
                out = BoardControllerCtx'('dx);
                out.board_op = in.board_op;
            end
        endcase

        // Write all changes down pipeline
        next_ctx_pipe[5] = out;
    end


    // Pipeline Stage 6 (Sum PST-Value and Compute Zobrist Hash)
    always_comb begin
        automatic BoardControllerCtx in = ctx_pipe[5];
        automatic BoardControllerCtx out;

        // By default nothing changes
        out = in;

        case (in.board_op)
            BOARD_PUSH_MOVE_OP, BOARD_COMMIT_MOVE_OP: begin
                automatic Position start_pos = in.move_record.start_pos;
                automatic Position end_pos = in.move_record.end_pos;

                // Compute the updated PST score
                out.pst_eval += pst_start_out;
                out.pst_eval -= pst_end_out;
                if (in.is_ep || in.move_record.killed_piece != NULL_PIECE) out.pst_eval -= pst_killed_out;
                if (in.is_castle) begin
                    out.pst_eval += pst_killed_out; // Remove rook "killed" during castle
                    out.pst_eval -= pst_castle_out; // Add rook to new position
                end
                if ((in.is_ep || in.move_record.killed_piece != NULL_PIECE) && in.is_castle) out.pst_eval = EvalScore'('dx); // Kill and castle cannot happen at the same tiem

                // Update board state
                out.board.turn = Color'(~in.board.turn);

                if (start_pos == 'd4  || start_pos == 'd7  || end_pos == 'd7 ) out.board.castle_perms.whiteKingside  = 1'b0;
                if (start_pos == 'd4  || start_pos == 'd0  || end_pos == 'd0 ) out.board.castle_perms.whiteQueenside = 1'b0;
                if (start_pos == 'd60 || start_pos == 'd63 || end_pos == 'd63) out.board.castle_perms.blackKingside  = 1'b0;
                if (start_pos == 'd60 || start_pos == 'd56 || end_pos == 'd56) out.board.castle_perms.blackQueenside = 1'b0;

                // Check if pawn move forward two tiles
                out.board.has_ep = (in.is_pawn_move && (getRank(start_pos) == 'd1 || getRank(start_pos) == 'd6) && (getRank(end_pos) == 'd3 || getRank(end_pos) == 'd4));
                out.board.ep_file = getFile(end_pos);

                if (in.is_ep || in.move_record.killed_piece != NULL_PIECE || in.is_pawn_move) begin
                    out.board.halfmove_clk = HalfMoveClk'('d0);
                end else begin
                    out.board.halfmove_clk = in.board.halfmove_clk + HalfMoveClk'('d1);
                end
            end

            BOARD_REVERSE_MOVE_OP: begin
                // Compute the updated PST score
                out.pst_eval += pst_start_out;
                out.pst_eval -= pst_end_out;
                if (in.is_ep || in.move_record.killed_piece != NULL_PIECE) out.pst_eval -= pst_killed_out;
                if (in.is_castle) begin
                    out.pst_eval += pst_killed_out; // Add rook that was "killed" during castle
                    out.pst_eval -= pst_castle_out; // Remove rook added during forward move
                end
                if ((in.is_ep || in.move_record.killed_piece != NULL_PIECE) && in.is_castle) out.pst_eval = EvalScore'('dx); // Kill and castle cannot happen at the same tiem

                // Update board state
                out.board.turn = Color'(~in.board.turn);
                out.board.castle_perms = in.move_record.castle_perms;
                out.board.has_ep = in.move_record.has_ep;
                out.board.ep_file = in.move_record.ep_file;
                out.board.halfmove_clk = in.move_record.halfmove_clk;
            end

            BOARD_SET_TILE_OP: begin
                automatic Tile new_tile = Tile'(in.set_data);
                // Add new piece to board with PST accounting for turn POV
                if (new_tile.piece_type != NULL_PIECE) begin
                    if (new_tile.piece_color == in.board.turn) out.pst_eval += pst_end_out;
                    else                                       out.pst_eval -= pst_end_out;
                end
                // Remove old piece from the board with sign depending on piece color and turn POV
                if (in.move_record.killed_piece != NULL_PIECE) begin
                    if (in.overwritten_color_has_turn) out.pst_eval -= pst_killed_out;
                    else                               out.pst_eval += pst_killed_out;
                end
            end

            BOARD_SET_TURN_OP: begin
                out.board.turn = Color'(in.set_data[0]);
            end

            BOARD_SET_CASTLE_PERMS_OP: begin
                out.board.castle_perms = CastlePerms'(in.set_data);
            end

            BOARD_SET_EN_PASSANT_OP: begin
                out.board.has_ep = in.set_data[0];
                out.board.ep_file = BoardFile'(in.set_data[3:1]);
            end

            // Don't care about idle operation
            BOARD_IDLE_OP: begin
                out = BoardControllerCtx'('dx);
                out.board_op = in.board_op;
            end
        endcase

        // Write all changes down pipeline
        next_ctx_pipe[6] = out;
    end


endmodule : board_controller
