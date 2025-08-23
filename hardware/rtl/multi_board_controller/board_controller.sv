
import general_chess_defs::*;
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
    logic [$clog2(6*64)-1:0] pst_start_addr, pst_end_addr, pst_killed_addr, pst_castle_rook_addr;
    logic pst_start_rd_en, pst_end_rd_en, pst_killed_rd_en, pst_castle_rook_rd_en;
    EvalScore pst_start_out, pst_end_out, pst_killed_out, pst_castle_out;

    dual_port_rom #(
        .NUM_WORDS(6 * 64),
        .WORD_SIZE($bits(EvalScore)),
        .MEM_INIT_FILE("../../data/pst_values/pst_values.mif")
    ) pst_rom_0 (
        .address_a(pst_start_addr),
        .address_b(pst_end_addr),
        .clock(clk),
        .rden_a(pst_start_rd_en),
        .rden_b(pst_end_rd_en),
        .q_a(pst_start_out),
        .q_b(pst_end_out)
    );
    dual_port_rom #(
        .NUM_WORDS(6 * 64),
        .WORD_SIZE($bits(EvalScore)),
        .MEM_INIT_FILE("../../data/pst_values/pst_values.mif")
    ) pst_rom_1 (
        .address_a(pst_killed_addr),
        .address_b(pst_castle_rook_addr),
        .clock(clk),
        .rden_a(pst_killed_rd_en),
        .rden_b(pst_castle_rook_rd_en),
        .q_a(pst_killed_out),
        .q_b(pst_castle_out)
    );
    

    // Move data down the pipeline
    always_ff @(posedge clk) begin
        ctx_pipe <= next_ctx_pipe;
    end


    // Pipeline Stage 0 (Register Initial Inputs)
    always_comb begin
        next_ctx_pipe[0].board_op   <= board_op;
        next_ctx_pipe[0].board      <= board_in;
        next_ctx_pipe[0].board_hash <= board_hash_in;
        next_ctx_pipe[0].pst_eval   <= pst_eval_in;
        next_ctx_pipe[0].move       <= move_in;
        next_ctx_pipe[0].set_data   <= set_data;
        next_ctx_pipe[0].thread_id  <= thread_id;

        move_record_rd_addr = {thread_id, search_depth};
        move_record_rd_en = (board_op == BOARD_REVERSE_MOVE_OP);
    end


    // Pipeline Stage 1-2 (Idle)
    always_comb begin
        next_ctx_pipe[1] <= ctx_pipe[0];
        next_ctx_pipe[2] <= ctx_pipe[1];
    end


    // Pipeline Stage 3 (Update Primary Tiles and Fetch PST and Zobrist Values)
    always_comb begin
        automatic BoardControllerCtx in = ctx_pipe[2];
        automatic BoardControllerCtx out = next_ctx_pipe[3];
        
        // By default nothing changes
        out = in;

        // Disable all reads by default to save power
        pst_start_rd_en = 1'b0;
        pst_end_rd_en = 1'b0;
        pst_killed_rd_en = 1'b0;
        pst_castle_rook_rd_en = 1'b0;

        // Update Main Tiles an
        case (in.board_op)
            // Forward Moves
            BOARD_PUSH_MOVE_OP, BOARD_COMMIT_MOVE_OP: begin
                automatic Position start_pos = in.move.start_pos;
                automatic Position end_pos = in.move.end_pos;

                automatic logic is_promo = (in.board.tiles[start_pos].piece_type == PAWN && (getFile(end_pos) == BoardFile'('d0) || getFile(end_pos) == BoardFile'('d7)));
                automatic logic is_castle = (in.board.tiles[start_pos].piece_type == KING && getFile(start_pos) == BoardFile'('d4) && (getFile(end_pos) == BoardFile'('d2) || end_pos == getFile(end_pos) == BoardFile'('d6)));
                automatic logic is_ep = (in.board.tiles[start_pos].piece_type == PAWN && in.board.has_ep && in.board.ep_file == getFile(end_pos) && ((in.board.turn == WHITE && getRank(end_pos) == BoardFile'('d5)) || (in.board.turn == BLACK && getRank(end_pos) == BoardFile'('d2))));

                // Set starting tile to be empty
                out.board.tiles[start_pos] = EMPTY_TILE;

                // Check for promotions and promote to new piece
                if (is_promo) begin
                    out.board.tiles[end_pos].piece_color = in.board.tiles[start_pos].piece_color; // Copy Piece Color

                    case (in.move.promo_piece)
                        PROMO_QUEEN:  out.board.tiles[end_pos].piece_type = QUEEN;
                        PROMO_KNIGHT: out.board.tiles[end_pos].piece_type = KNIGHT;
                        PROMO_ROOK:   out.board.tiles[end_pos].piece_type = ROOK;
                        PROMO_BISHOP: out.board.tiles[end_pos].piece_type = BISHOP;
                    endcase
                // Else no promotion, move piece as normal
                end else begin
                    out.board.tiles[end_pos] = in.board.tiles[start_pos];
                end

                // -- Fetch PST values --
                // Positions mirrored when moving black pieces

                // Starting tile is always cleared
                pst_start_addr = {in.board.tiles[start_pos].piece_type, (in.board.turn == BLACK ? mirrorPos(start_pos) : start_pos)};
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
                    pst_end_addr = {in.board.tiles[start_pos].piece_type, (in.board.turn == BLACK ? mirrorPos(end_pos) : end_pos)};
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
                    pst_killed_addr = {in.board.tiles[end_pos].piece_type, (in.board.turn == BLACK ? end_pos : mirrorPos(end_pos))};
                    pst_killed_rd_en = (in.board.tiles[end_pos].piece_type != NULL_PIECE);
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

                // If making a reversable move, store data about current move
                // Only need to write a full record if the move is meant to be reversable
                if (in.board_op == BOARD_PUSH_MOVE_OP) begin
                    out.move_record.start_pos = start_pos;
                    out.move_record.end_pos = end_pos;
                    out.move_record.killed_piece = in.board.tiles[end_pos].piece_type; // Correct for En Passant kills as NULL PIECE
                    out.move_record.castle_perms = in.board.castle_perms;
                    out.move_record.move_flag = (is_promo ? PROMO_MOVE : is_castle ? CASTLE_MOVE : is_ep ? EP_MOVE : NORM_MOVE);
                    out.move_record.has_ep = in.board.has_ep;
                    out.move_record.ep_file = in.board.ep_file;
                    out.move_record.halfmove_clk = in.board.halfmove_clk;
                end else begin
                    out.move_record = MoveRecord'('dx);
                    out.move_record.killed_piece = in.board.tiles[end_pos].piece_type; // Only store piece killed for later PST/Zobrist stages
                end

                // Flag special moves for later stages
                out.is_castle = is_castle;
                out.is_ep = is_ep;
            end

            // Reverse Move
            BOARD_REVERSE_MOVE_OP: begin
                automatic Position start_pos = move_record_out.start_pos;
                automatic Position end_pos = move_record_out.end_pos;
                automatic Color turn = in.board.turn;
                automatic logic is_promo  = (move_record_out.move_flag == PROMO_MOVE);
                automatic logic is_ep     = (move_record_out.move_flag == EP_MOVE);
                automatic logic is_castle = (move_record_out.move_flag == CASTLE_MOVE);

                // If move was a promotion, be sure to demote
                if (is_promo) begin
                    out.board.tiles[start_pos] = Tile'({~turn, PAWN});
                end else begin
                    out.board.tiles[start_pos] = Tile'({~turn, in.board.tiles[end_pos].piece_type});
                end

                out.board.tiles[end_pos] = Tile'({turn, move_record_out.killed_piece}); // Will write NULL_PIECE for EP kill and killed pawn will be added later


                // -- Fetch PST Values --
                // Positions mirrored when moving black pieces (by checking if turn is current WHITE)

                // Starting tille gets copied from desination tile except in the case of promotion
                if (is_promo) begin
                    pst_start_addr = {PAWN, (in.board.turn == WHITE ? mirrorPos(start_pos) : start_pos)};
                end else begin
                    pst_start_addr = {in.board.tiles[end_pos].piece_type, (in.board.turn == WHITE ? mirrorPos(start_pos) : start_pos)};
                end
                pst_start_rd_en = 1'b1;

                // Remove moving piece from ending tile
                pst_end_addr = {in.board.tiles[end_pos].piece_type, (in.board.turn == WHITE ? mirrorPos(end_pos) : end_pos)};
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
                pst_end_addr = {new_tile.piece_type, (in.board.turn == BLACK ? mirrorPos(end_pos) : end_pos)};
                pst_end_rd_en = 1'b1;

                // Remove piece killed by placement
                pst_killed_addr = {in.board.tiles[end_pos].piece_type, (in.board.turn == BLACK ? end_pos : mirrorPos(end_pos))};
                pst_killed_rd_en = (in.board.tiles[end_pos].piece_type != NULL_PIECE);

                // Set only 
                out.move_record = MoveRecord'('dx);
            end
        endcase
    end


    // Pipeline Stage 4 (Clear extra tile for en passant and castling + write move record)
    always_comb begin
        automatic BoardControllerCtx in = ctx_pipe[3];
        automatic BoardControllerCtx out = next_ctx_pipe[4];

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
                        out.board.tiles[{BoardRank'(4), getFile(in.move_record.end_pos)}] = PAWN;
                    end else begin
                        out.board.tiles[{BoardRank'(3), getFile(in.move_record.end_pos)}] = PAWN;
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

            // is_ep and is_castle should never be asserted for other operations
            default: if (in.is_ep || in.is_castle) out.board.tiles = 'dx;
        endcase

        // Write move record
        move_record_in = in.move_record;
        move_record_wr_en = (in.board_op == BOARD_PUSH_MOVE_OP);
        move_record_wr_addr = {thread_id, search_depth};
    end


    // Pipeline Stage 5 (Update placing extra rook in castle operations)
    always_comb begin
        automatic BoardControllerCtx in = ctx_pipe[4];
        automatic BoardControllerCtx out = next_ctx_pipe[5];

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
            end

            // is_castle should never be asserted for other operations
            default: if (in.is_castle) out.board.tiles = 'dx;
        endcase
    end


    // Pipeline Stage 6 (Sum PST-Value and Compute Zobrist Hash)
    always_comb begin
        automatic BoardControllerCtx in = ctx_pipe[5];
        automatic BoardControllerCtx out = next_ctx_pipe[6];

        // By default nothing changes
        out = in;

        case (in.board_op)
            // Compute the updated PST score
            BOARD_PUSH_MOVE_OP, BOARD_COMMIT_MOVE_OP: begin
                out.pst_eval -= pst_start_out;
                out.pst_eval += pst_end_out;
                if (in.is_ep || in.move_record.killed_piece != NULL_PIECE) out.pst_eval -= pst_killed_out;
                if (in.is_castle) out.pst_eval += pst_castle_out;
            end

            BOARD_REVERSE_MOVE_OP: begin
                out.pst_eval += pst_start_out;
                out.pst_eval -= pst_end_out;
                if (in.is_ep || in.move_record.killed_piece != NULL_PIECE) out.pst_eval += pst_killed_out;
                if (in.is_castle) out.pst_eval -= pst_castle_out;
            end

            BOARD_SET_TILE_OP: begin
                out.pst_eval += pst_end_out;
                if (in.move_record.killed_piece != NULL_PIECE) out.pst_eval -= pst_killed_out;
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

            // Don't care about the output in the idle case
            BOARD_IDLE_OP: begin
                out.pst_eval = EvalScore'('dx);
            end
        endcase
    end


endmodule : board_controller
