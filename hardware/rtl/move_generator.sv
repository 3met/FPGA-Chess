
// By Emet Behrendt

import general_chess_defs::*;

// Package for definitions relating to the move generator
package move_generator_defs;

    localparam move_gen_delay = 11;

    // -- Define Move Generator Operations -- 
    typedef enum {
        MOVE_GEN_IDLE_OP,
        MOVE_GEN_NORMAL_OP,
        MOVE_GEN_TARGETED_OP,
        MOVE_GEN_QSEARCH_OP
    } MoveGenOp;

endpackage : move_generator_defs


import move_generator_defs::*;


module move_generator #(parameter MAX_PLY_COUNT, parameter THREAD_COUNT) (
    input logic clk,
    input logic rst_n,

    // Move Generation Config
    input MoveGenOp move_gen_op,
    input ThreadID thread_id,
    input DepthType ply,
    input wire Move target_move,

    // Board Data
    input wire Tile        board_tiles[64],
    input Color            turn,
    input wire CastlePerms castle_perms,
    input logic            has_ep,
    input BoardFile        ep_file,
    // input reg [6:0]   halfmove_clock, // Unused?

    // Generated Output
    output var Move best_move,
    output logic move_is_legal
);

    // Move Config Pipeline
    MoveGenOp move_gen_op_pipe[11];
    ThreadID thread_id_pipe[11];
    DepthType ply_pipe[11];
    Move target_move_pipe[9];
    logic is_target_move_knight, is_target_move_knight_wire;
    Direction target_move_direction, target_move_direction_wire;

    // Piece Propagation Pipeline Registers
    Tile board_pipe[7][64];        // Indexed like [layer][position]
    Tile adj_piece_in[7][64][8];     // Indexed like [layer][position][direction]
    reg [2:0] adj_dist_in[7][64][8]; // Indexed like [layer][position][direction]

    // Board State Pipeline
    Color       turn_pipe[8];
    CastlePerms castle_perms_pipe[8];
    reg         has_ep_pipe[8];
    BoardFile   ep_file_pipe[8];

    // Move Generation State
    DepthType prev_ply[THREAD_COUNT];

    // Board Mask Pipeline
    reg NS_cardinal_mask[4][8][7];    // Indexed like [layer][file][rank]
    reg EW_cardinal_mask[4][7][8];    // Indexed like [layer][file][rank]
    reg pos_diag_mask[4][7][7];       // Indexed like [layer][file][rank]
    reg neg_diag_mask[4][7][7];       // Indexed like [layer][file][rank]
    reg NNE_SSW_knight_mask[4][7][6]; // Indexed like [layer][file][rank]
    reg NEE_SWW_knight_mask[4][6][7]; // Indexed like [layer][file][rank]
    reg SEE_NWW_knight_mask[4][6][7]; // Indexed like [layer][file][rank]
    reg SSE_NNW_knight_mask[4][7][6]; // Indexed like [layer][file][rank]

    // Result Pipeline
    typedef reg [2:0] MovePriority;
    localparam MovePriority NULL_MOVE_PRIORITY = MovePriority'('d0);
    localparam MovePriority UNKNOWN_MOVE_PRIORITY = MovePriority'('dx);
    MovePriority tile_move_priority[64]; // The best score a given tile can produce
    Direction tile_move_dir[64]; // Distance of best move
    logic [2:0] tile_move_dist[64]; // Direction of best move
    MovePriority overall_move_priority;  // The best score for the entire board

    logic is_best_move_knight, is_best_move_knight_wire;
    Direction best_move_direction, best_move_direction_wire;

    // ---- Inter-Tile Signals ----
    typedef struct packed {
		Color piece_color;
		logic has_knight;
		logic has_king_or_major;
	} KnightBusData;

    KnightBusData knight_data_in[64][8]; // Indexed like [pos][dir]


    // ---- Intra-Tile Signals ----
    logic good_knight_target[64];
    logic good_cardinal_target[64];
    logic good_diag_target[64];
    PieceType weakest_attacker[64];
    PieceType weakest_defender[64];

    logic [2:0] attacker_count[64];
    logic [2:0] defender_count[64];

    logic has_attacker[64][7];     // Refers to unmasked attackers; index 0 is unused
    Direction attacker_dir[64][7]; // Refers to unmasked attackers; index 0 is unused

    Move best_move_pipe; // Indexed like [layer]
    Direction best_move_dir;
    logic [2:0] best_move_dist;



    // Depth of memory to allocate
    // TODO: Round up to BRAM size?
    // localparam MEM_DEPTH = $ceil(MAX_PLY_COUNT * 0.8);

    // Valid Mask Chunk BRAM
    // simple_dual_port_ram valid_mask_chunk_mem #(NUM_WORDS=(THREAD_COUNT * MAX_PLY_COUNT), WORD_SIZE=(378)) (
    //     .clock(),
    //     .data(),
    //     .rdaddress(),
    //     .rden(),
    //     .wraddress(),
    //     .wren(),
    //     .q()
    // );

    wire [378-1:0] combined_mask[4]; // Indexed like [layer]
    logic adj_mask[64][8]; // Indexed like [pos][dir]
    logic knight_mask[64][8]; // Indexed like [pos][dir]

    genvar i;
    generate
        for (i=0; i<4; i=i+1) begin : gen_combined_masks
            assign combined_mask[i] = {
            {<<{NS_cardinal_mask[i]}},
            {<<{EW_cardinal_mask[i]}},
            {<<{pos_diag_mask[i]}},
            {<<{neg_diag_mask[i]}},
            {<<{NNE_SSW_knight_mask[i]}},
            {<<{NEE_SWW_knight_mask[i]}},
            {<<{SEE_NWW_knight_mask[i]}},
            {<<{SSE_NNW_knight_mask[i]}}
            };
        end
    endgenerate
    
    // ========== Assign Adj Mask from Mask Data ==========
    always_comb begin
        for (int pos=0; pos<64; pos++) begin
            automatic BoardRank RANK = getRank(pos);
            automatic BoardRank FILE = getFile(pos);

            adj_mask[pos] = '{default:1'd0};

            if (RANK < 7) adj_mask[pos][NORTH] = NS_cardinal_mask[0][FILE][RANK];
            if (RANK > 0) adj_mask[pos][SOUTH] = NS_cardinal_mask[0][FILE][RANK-1];
            if (FILE < 7) adj_mask[pos][EAST] = EW_cardinal_mask[0][FILE][RANK];
            if (FILE > 0) adj_mask[pos][WEST] = EW_cardinal_mask[0][FILE-1][RANK];
            if (RANK < 7 && FILE < 7) adj_mask[pos][NORTH_EAST] = pos_diag_mask[0][FILE][RANK];
            if (RANK > 0 && FILE > 0) adj_mask[pos][SOUTH_WEST] = pos_diag_mask[0][FILE-1][RANK-1];
            if (RANK < 7 && FILE > 0) adj_mask[pos][NORTH_WEST] = neg_diag_mask[0][FILE-1][RANK];
            if (RANK > 0 && FILE < 7) adj_mask[pos][SOUTH_EAST] = neg_diag_mask[0][FILE][RANK-1];

            knight_mask[pos] = '{default:1'd0};

            if (RANK < 6 && FILE < 7) knight_mask[pos][NNE] = NNE_SSW_knight_mask[0][FILE][RANK];
            if (RANK > 1 && FILE > 0) knight_mask[pos][SSW] = NNE_SSW_knight_mask[0][FILE-1][RANK-2];
            if (RANK < 7 && FILE < 6) knight_mask[pos][NEE] = NEE_SWW_knight_mask[0][FILE][RANK];
            if (RANK > 0 && FILE > 1) knight_mask[pos][SWW] = NEE_SWW_knight_mask[0][FILE-2][RANK-1];
            if (RANK > 0 && FILE < 6) knight_mask[pos][SEE] = SEE_NWW_knight_mask[0][FILE][RANK-1];
            if (RANK < 7 && FILE > 1) knight_mask[pos][NWW] = SEE_NWW_knight_mask[0][FILE-2][RANK];
            if (RANK > 1 && FILE < 7) knight_mask[pos][SSE] = SSE_NNW_knight_mask[0][FILE][RANK-2];
            if (RANK < 6 && FILE > 0) knight_mask[pos][NNW] = SSE_NNW_knight_mask[0][FILE-1][RANK];
        end
    end



    simple_dual_port_ram #(.NUM_WORDS(THREAD_COUNT * MAX_PLY_COUNT), .WORD_SIZE(378)) mask_mem (
        .clock(clk),
        .data(combined_mask[3]),
        .rdaddress({thread_id_pipe[2], ply_pipe[2]}),
        .rden(move_gen_op_pipe[2] != MOVE_GEN_IDLE_OP),
        .wraddress({thread_id_pipe[9], ply_pipe[9]}),
        .wren(move_gen_op_pipe[9] != MOVE_GEN_IDLE_OP),
        .q(combined_mask[0])
    );


    // ========== Propagate Pieces ==========
    always_ff @(posedge clk) begin
        for (int pos=0; pos < 64; pos++) begin
            automatic BoardRank RANK = getRank(pos);
            automatic BoardFile FILE = getFile(pos);

            for (int layer=0; layer < 7; layer++) begin
                // Copy the board down pipeline
                board_pipe[layer] <= (layer==0 ? board_tiles : board_pipe[layer-1]);

                for (Direction dir=Direction'(0); dir < 8; dir=Direction'(dir+1)) begin
                    // Xs by default for first layer, copy previous value for later layers
                    adj_piece_in[layer][pos][dir] = (layer==0 ? UNKNOWN_PIECE : adj_piece_in[layer-1][pos][dir]);
                    adj_dist_in[layer][pos][dir] = (layer==0 ? 3'dx : adj_dist_in[layer-1][pos][dir]);

                    // TODO: Optimize such that pawns cannot be cardinal pieces from the first and last rank

                    // Check directly next to edge of board
                    if (!isShiftOnBoard(pos, dir, 1)) begin
                        adj_piece_in[layer][pos][dir] = NULL_PIECE; // TODO: ensure this does not actually synthesize a register
                        adj_dist_in[layer][pos][dir] = 3'd0;

                    // Check for special first comparison
                    end else if (layer == 0 && !isShiftOnBoard(pos, dir, 2)) begin
                        adj_piece_in[layer][pos][dir] = board_pipe[layer][shiftPos(pos, dir, 1)]; // TODO: Optimize this? It just duplicates a register
                        adj_dist_in[layer][pos][dir] = (board_pipe[layer][shiftPos(pos, dir, 1)].piece_type == NULL_PIECE ? 3'd1 : 3'd0);

                    // Otherwise compare only as late as possible to avoid duplicate comparisons
                    end else if (layer > 0 && isShiftOnBoard(pos, dir, 2+layer-1) && !isShiftOnBoard(pos, dir, 2+layer)) begin
                        // If no piece exists, relay previous signal
                        if (board_pipe[layer][shiftPos(pos, dir, 1)].piece_type == NULL_PIECE) begin
                            adj_piece_in[layer][pos][dir] = adj_piece_in[layer-1][shiftPos(pos, dir, 1)][dir];
                            adj_dist_in[layer][pos][dir] = adj_dist_in[layer-1][pos][dir] + 3'd1;
                        // else piece exists, so relay that piece
                        end else begin
                            adj_piece_in[layer][pos][dir] = board_pipe[layer][shiftPos(pos, dir, 1)];
                            adj_dist_in[layer][pos][dir] = 3'd0;
                        end
                    end
                end
            end
        end
    end


    // ========== Move Data Down Pipeline ==========
    always_ff @(posedge clk) begin

        // Move Gen Configurations
        move_gen_op_pipe[0] <= move_gen_op;
        thread_id_pipe[0] <= thread_id;
        ply_pipe[0] <= ply;
        target_move_pipe[0] <= target_move;

        for (int i=1; i<11; i++) move_gen_op_pipe[i] <= move_gen_op_pipe[i-1];
        for (int i=1; i<11; i++) thread_id_pipe[i] <= thread_id_pipe[i-1];
        for (int i=1; i<11; i++) ply_pipe[i] <= ply_pipe[i-1];
        for (int i=1; i<9 ; i++) target_move_pipe[i] <= target_move_pipe[i-1];

        // Board State
        turn_pipe[0] <= turn;
        castle_perms_pipe[0] <= castle_perms;
        has_ep_pipe[0] <= has_ep;
        ep_file_pipe[0] <= ep_file;

        for (int i=1; i<8; i++) turn_pipe[i] <= turn_pipe[i-1];
        for (int i=1; i<8; i++) castle_perms_pipe[i] <= castle_perms_pipe[i-1];
        for (int i=1; i<8; i++) has_ep_pipe[i] <= has_ep_pipe[i-1];
        for (int i=1; i<8; i++) ep_file_pipe[i] <= ep_file_pipe[i-1];
    end

    
    // ========== Move Mask Down Pipeline ==========
    always_ff @(posedge clk) begin

        for (int i=1; i<4; i++) begin
            NS_cardinal_mask[i] = NS_cardinal_mask[i-1];
            EW_cardinal_mask[i] = EW_cardinal_mask[i-1];
            pos_diag_mask[i] = pos_diag_mask[i-1];
            neg_diag_mask[i] = neg_diag_mask[i-1];
            NNE_SSW_knight_mask[i] = NNE_SSW_knight_mask[i-1];
            NEE_SWW_knight_mask[i] = NEE_SWW_knight_mask[i-1];
            SEE_NWW_knight_mask[i] = SEE_NWW_knight_mask[i-1];
            SSE_NNW_knight_mask[i] = SSE_NNW_knight_mask[i-1];
        end

        unique case ({is_best_move_knight, best_move_direction})
            {1'b0, NORTH}: NS_cardinal_mask[3][getFile(best_move_pipe.end_pos)][getRank(best_move_pipe.end_pos)-1] = 1'b0;
            {1'b0, SOUTH}: NS_cardinal_mask[3][getFile(best_move_pipe.end_pos)][getRank(best_move_pipe.end_pos)] = 1'b0;
            {1'b0, EAST}: EW_cardinal_mask[3][getFile(best_move_pipe.end_pos)-1][getRank(best_move_pipe.end_pos)] = 1'b0;
            {1'b0, WEST}: EW_cardinal_mask[3][getFile(best_move_pipe.end_pos)][getRank(best_move_pipe.end_pos)] = 1'b0;
            {1'b0, NORTH_EAST}: pos_diag_mask[3][getFile(best_move_pipe.end_pos)-1][getRank(best_move_pipe.end_pos)-1] = 1'b0;
            {1'b0, SOUTH_WEST}: pos_diag_mask[3][getFile(best_move_pipe.end_pos)][getRank(best_move_pipe.end_pos)] = 1'b0;
            {1'b0, SOUTH_EAST}: neg_diag_mask[3][getFile(best_move_pipe.end_pos)-1][getRank(best_move_pipe.end_pos)] = 1'b0;
            {1'b0, NORTH_WEST}: neg_diag_mask[3][getFile(best_move_pipe.end_pos)][getRank(best_move_pipe.end_pos)-1] = 1'b0;

            {1'b1, NNE}: NNE_SSW_knight_mask[3][getFile(best_move_pipe.start_pos)][getRank(best_move_pipe.start_pos)] = 1'b0;
            {1'b1, SSW}: NNE_SSW_knight_mask[3][getFile(best_move_pipe.end_pos)][getRank(best_move_pipe.end_pos)] = 1'b0;
            {1'b1, NEE}: NEE_SWW_knight_mask[3][getFile(best_move_pipe.start_pos)][getRank(best_move_pipe.start_pos)] = 1'b0;
            {1'b1, SWW}: NEE_SWW_knight_mask[3][getFile(best_move_pipe.end_pos)][getRank(best_move_pipe.end_pos)] = 1'b0;
            {1'b1, SEE}: SEE_NWW_knight_mask[3][getFile(best_move_pipe.start_pos)][getRank(best_move_pipe.end_pos)] = 1'b0;
            {1'b1, NWW}: SEE_NWW_knight_mask[3][getFile(best_move_pipe.end_pos)][getRank(best_move_pipe.start_pos)] = 1'b0;
            {1'b1, SSE}: SSE_NNW_knight_mask[3][getFile(best_move_pipe.start_pos)][getRank(best_move_pipe.end_pos)] = 1'b0;
            {1'b1, NNW}: SSE_NNW_knight_mask[3][getFile(best_move_pipe.end_pos)][getRank(best_move_pipe.start_pos)] = 1'b0;

            // If the move is NULL or UNKNOWN, we shouldn't care about mask update as it won't be written
            default: begin
                NS_cardinal_mask[3] = '{default: 1'bx};
                EW_cardinal_mask[3] = '{default: 1'bx};
                pos_diag_mask[3] = '{default: 1'bx};
                neg_diag_mask[3] = '{default: 1'bx};
                NNE_SSW_knight_mask[3] = '{default: 1'bx};
                NEE_SWW_knight_mask[3] = '{default: 1'bx};
                SEE_NWW_knight_mask[3] = '{default: 1'bx};
                SSE_NNW_knight_mask[3] = '{default: 1'bx};
            end
        endcase
    end


    // ========== Update Move Gen State ==========
    always_ff @(posedge clk) begin
        if (move_gen_op_pipe[6])
            prev_ply[thread_id_pipe[6]] = ply_pipe[thread_id_pipe[6]];
    end


    // ========== Compute best_move and move_is_illegal ==========
    always_ff @(posedge clk) begin
        best_move <= (overall_move_priority == NULL_MOVE_PRIORITY ? NULL_MOVE : best_move_pipe);
        // best_move_pipe <= ;
    end


    // ========== Compute Direction of Target Move and Best Move ==========
    get_move_dir get_target_move_dir(target_move_pipe[5], is_target_move_knight_wire, target_move_direction_wire);
    always_ff @(posedge clk) {is_target_move_knight, target_move_direction} <= {is_target_move_knight_wire, target_move_direction_wire};

    get_move_dir get_best_move_dir(best_move_pipe[5], is_best_move_knight_wire, best_move_direction_wire);
    always_ff @(posedge clk) {is_best_move_knight, best_move_direction} <= {is_best_move_knight_wire, best_move_direction_wire};


    // ========== Compute Per-Tile Priorities (tile_move_priority) ==========
    always_comb begin
        for (int pos=0; pos < 64; pos++) begin

            automatic BoardRank RANK = getRank(pos);
            automatic BoardFile FILE = getFile(pos);

            automatic Tile occupant = board_pipe[6][pos];
            automatic Tile moving_color = turn_pipe[6];
            automatic Tile curr_piece_in[8] = adj_piece_in[6][pos];
            automatic logic [2:0] curr_dist[8] = adj_dist_in[6][pos];

            for (int layer=0; layer < 7; layer++) begin
                automatic Tile occupant = board_pipe[layer][pos];
                automatic Tile curr_piece_in[8] = adj_piece_in[layer][pos];
                automatic logic [2:0] curr_dist[8] = adj_dist_in[layer][pos];

                // TODO: Evaluate certain tiles at earlier layers to save resources

                // Assert a Pawn is never on the first or last rank
                if (RANK == 0 || RANK == 7) begin
                    assert(occupant.piece_type !== PAWN) else $fatal("Pawn on first/last rank!");

                    if (occupant.piece_type == PAWN) begin
                        tile_move_priority[pos] = UNKNOWN_MOVE_PRIORITY;
                    end
                end

                // Assert that Kings never touch
                if (occupant.piece_type == KING) begin
                    for (Direction dir=Direction'(0); dir < 8; dir=Direction'(dir+1)) begin
                        if (curr_piece_in[dir]==KING && curr_dist[dir]==3'd0) begin
                            $fatal("King Attacking King!");
                            tile_move_priority[pos] = UNKNOWN_MOVE_PRIORITY;
                        end
                    end
                end

                // Assert that SPARE_PIECE type is not used
                if (occupant.piece_type == SPARE_PIECE) begin
                    $fatal("Unknown \"SPARE_PIECE\" found...");
                    tile_move_priority[pos] = UNKNOWN_MOVE_PRIORITY;
                end
            end

            // NULL score if occupied by a friendly piece
            if (occupant.piece_color==moving_color && occupant.piece_type!=NULL_PIECE) begin
                tile_move_priority[pos] = NULL_MOVE_PRIORITY;
                tile_move_dir[pos] = Direction'('dx);
                tile_move_dist[pos] = 3'dx;

            // NULL score for no attackers and pawn moves
            end else if (   ~has_attacker[pos][PAWN] && ~has_attacker[pos][KNIGHT] && ~has_attacker[pos][BISHOP]
                         && ~has_attacker[pos][ROOK] && ~has_attacker[pos][QUEEN] && ~has_attacker[pos][KING]) begin
                tile_move_priority[pos] = NULL_MOVE_PRIORITY;
                tile_move_dir[pos] = Direction'('dx);
                tile_move_dist[pos] = 3'dx;

            // Normal move
            end else begin
                // Initial score set such that final scores is >0 (non-null)
                // and will never overflow given its size
                tile_move_priority[pos] = MovePriority'(3'd3);

                // - Score based on possible material trades -
                // Bonus for killing a more valuable piece
                if (PIECE_VALS_1[occupant.piece_type] > PIECE_VALS_1[weakest_attacker[pos]]) begin
                    tile_move_priority[pos] += 3'd2;

                // Bonus for killing a piece of equal value when you have
                // attacker count advantage
                end else if (PIECE_VALS_1[occupant.piece_type] == PIECE_VALS_1[weakest_attacker[pos]]) begin
                    if (attacker_count[pos] > defender_count[pos]) begin
                        tile_move_priority[pos] += 3'd1;
                    end

                // No kill or kill less valuable than attacker
                end else begin
                    // Attacker advantage
                    if (attacker_count[pos] > defender_count[pos]) begin
                        if (defender_count[pos] == 3'd0) begin
                            tile_move_priority[pos] += 3'd1;

                        end else if (PIECE_VALS_1[weakest_defender[pos]] + PIECE_VALS_1[occupant.piece_type] < PIECE_VALS_1[weakest_attacker[pos]]) begin
                            tile_move_priority[pos] -= 3'd1;
                        end

                    // And defender has advantage
                    end else begin
                        tile_move_priority[pos] -= 3'd2;
                    end
                end

                // - Apply flags and choose attacker -
                // Go by flags if there are no defenders
                if (defender_count[pos] == 0) begin
                    if (good_knight_target[pos] && has_attacker[pos][KNIGHT]) begin
                        tile_move_dir[pos] = attacker_dir[pos][KNIGHT];
                        tile_move_dist[pos] = 3'd0; // Distance is zero for knights
                        tile_move_priority[pos] += 2;

                    end else if (good_diag_target[pos] && has_attacker[pos][BISHOP]) begin
                        tile_move_dir[pos] = attacker_dir[pos][BISHOP];
                        tile_move_dist[pos] = adj_dist_in[6][pos][tile_move_dir[pos]];
                        tile_move_priority[pos] += 2;

                    end else if (good_cardinal_target[pos] && has_attacker[pos][ROOK]) begin
                        tile_move_dir[pos] = attacker_dir[pos][ROOK];
                        tile_move_dist[pos] = adj_dist_in[6][pos][tile_move_dir[pos]];
                        tile_move_priority[pos] += 2;

                    end else if (good_cardinal_target[pos] && has_attacker[pos][QUEEN]) begin
                        tile_move_dir[pos] = attacker_dir[pos][QUEEN];
                        tile_move_dist[pos] = adj_dist_in[6][pos][tile_move_dir[pos]];
                        tile_move_priority[pos] += 1;

                    end else if (good_diag_target[pos] && has_attacker[pos][QUEEN]) begin
                        tile_move_dir[pos] = attacker_dir[pos][QUEEN];
                        tile_move_dist[pos] = adj_dist_in[6][pos][tile_move_dir[pos]];
                        tile_move_priority[pos] += 1;

                    end else if (has_attacker[pos][PAWN]) begin
                        tile_move_dir[pos] = attacker_dir[pos][PAWN];
                        tile_move_dist[pos] = adj_dist_in[6][pos][tile_move_dir[pos]];

                    end else if (has_attacker[pos][KNIGHT]) begin
                        tile_move_dir[pos] = attacker_dir[pos][KNIGHT];
                        tile_move_dist[pos] = 3'd0; // Distance is zero for knights

                    end else if (has_attacker[pos][BISHOP]) begin
                        tile_move_dir[pos] = attacker_dir[pos][BISHOP];
                        tile_move_dist[pos] = adj_dist_in[6][pos][tile_move_dir[pos]];

                    end else if (has_attacker[pos][ROOK]) begin
                        tile_move_dir[pos] = attacker_dir[pos][ROOK];
                        tile_move_dist[pos] = adj_dist_in[6][pos][tile_move_dir[pos]];

                    end else if (has_attacker[pos][QUEEN]) begin
                        tile_move_dir[pos] = attacker_dir[pos][QUEEN];
                        tile_move_dist[pos] = adj_dist_in[6][pos][tile_move_dir[pos]];

                    end else if (has_attacker[pos][KING]) begin
                        tile_move_dir[pos] = attacker_dir[pos][KING];
                        tile_move_dist[pos] = adj_dist_in[6][pos][tile_move_dir[pos]];

                    // Should never reach here
                    end else begin
                        tile_move_dir[pos] = Direction'('dx);
                        tile_move_dist[pos] = 3'dx;
                        tile_move_priority[pos] = MovePriority'('dx);
                    end

                // If there are defenders, use weakest attacker
                end else begin
                    // Special case to deal with pawn forward moves
                    if (has_attacker[pos][PAWN]) begin
                        tile_move_dir[pos] = attacker_dir[pos][PAWN];
                    end else begin
                        tile_move_dir[pos] = attacker_dir[pos][weakest_attacker[pos]];
                    end

                    if (weakest_attacker[pos] == KNIGHT) begin
                        tile_move_dist[pos] = 3'd0; // Distance is zero for knights
                    end else begin
                        tile_move_dist[pos] = adj_dist_in[6][pos][tile_move_dir[pos]];
                    end

                    if (weakest_attacker[pos] == QUEEN && (good_diag_target[pos] || good_cardinal_target[pos])) begin
                        tile_move_priority[pos] += 1;
                    end else if (weakest_attacker[pos] == KNIGHT && good_knight_target[pos]) begin
                        tile_move_priority[pos] += 2;
                    end else if (weakest_attacker[pos] == ROOK && good_cardinal_target[pos]) begin
                        tile_move_priority[pos] += 2;
                    end else if (weakest_attacker[pos] == BISHOP && good_diag_target[pos]) begin
                        tile_move_priority[pos] += 2;
                    end

                    // Should never happen
                    if (weakest_attacker[pos] == SPARE_PIECE || weakest_attacker[pos] == NULL_PIECE) begin
                        tile_move_dir[pos] = Direction'('dx);
                        tile_move_dist[pos] = 3'dx;
                        tile_move_priority[pos] = MovePriority'('dx);
                    end
                end
            end


            // TODO: Should this be on the next pipeline stage?
            // if (move_gen_op_pipe[6] == MOVE_GEN_TARGETED_OP && /*TODO: check not masked*/ && /*TODO: check legal*/) begin
            //     tile_move_priority[pos] = /*TODO: max priority*/;
            // end
        end
    end


    // ========== Compute Tile Flags (good_knight_target, good_cardinal_target, good_diag_target) ==========
	always_comb begin
        for (int pos=0; pos<64; pos++) begin
            good_knight_target[pos] = 1'b0;
            for (Direction dir=Direction'(0); dir<8; dir=Direction'(dir+1)) begin
                good_knight_target[pos] |= (   knight_data_in[pos][dir].has_king_or_major
                                            && knight_data_in[pos][dir].piece_color == ~turn_pipe[6]);
            end
            
            good_cardinal_target[pos] = 1'b0;
            good_diag_target[pos] = 1'b0;
            for (int i=0; i<4; i+=1) begin
                good_cardinal_target[pos] |= (adj_piece_in[6][pos][CARDINAL_DIR[i]] == Tile'({~turn_pipe[6], KING}));
                good_cardinal_target[pos] |= (adj_piece_in[6][pos][CARDINAL_DIR[i]] == Tile'({~turn_pipe[6], QUEEN}));

                good_diag_target[pos] |= (adj_piece_in[6][pos][DIAG_DIR[i]] == Tile'({~turn_pipe[6], KING}));
                good_diag_target[pos] |= (adj_piece_in[6][pos][DIAG_DIR[i]] == Tile'({~turn_pipe[6], QUEEN}));
                good_diag_target[pos] |= (adj_piece_in[6][pos][DIAG_DIR[i]] == Tile'({~turn_pipe[6], ROOK}));
            end
        end
	end


    // --- Compute weakest_attacker and weakest_defender --- 
	// --- Compute attacker_count and defender_count --- 
	// --- Compute has_attacker and attacker_dir --- 
	localparam Direction b_pawn_dir[2] = '{NORTH_WEST, NORTH_EAST};
	localparam Direction w_pawn_dir[2] = '{SOUTH_WEST, SOUTH_EAST};
	always_comb begin
        for (int pos=0; pos<64; pos++) begin
            automatic BoardRank RANK = getRank(pos);
            automatic BoardFile FILE = getFile(pos);

            // Set default values
            weakest_attacker[pos] = KING;
            weakest_defender[pos] = KING;
            attacker_count[pos] = 'd0;
            defender_count[pos] = 'd0;
            for (int p=PAWN; p<=KING; p+=1) begin
                has_attacker[pos][p] = 1'd0;
                attacker_dir[pos][p] = Direction'('dx);
            end

            // - Update king, queen, rook, and bishop influences -
            for (Direction dir=Direction'(0); dir<8; dir=Direction'(dir+1)) begin
                if (   (adj_piece_in[6][pos][dir]==QUEEN)
                    || (adj_piece_in[6][pos][dir]==ROOK && isDirCardinal(Direction'(dir)))
                    || (adj_piece_in[6][pos][dir]==BISHOP && isDirDiag(Direction'(dir)))
                    || (adj_piece_in[6][pos][dir]==KING && adj_dist_in[6][pos][dir]==3'd1)) begin
                    
                    // Attackers
                    if (adj_piece_in[6][pos][dir].piece_color==turn_pipe[6]) begin
                        attacker_count[pos] += 'd1;

                        if (weakest_attacker[pos] > adj_piece_in[6][pos][dir]) begin
                            weakest_attacker[pos] = adj_piece_in[6][pos][dir].piece_type;
                        end

                        if (adj_mask[pos][dir]) begin
                            has_attacker[pos][adj_piece_in[6][pos][dir]] = 1'b1;
                            attacker_dir[pos][adj_piece_in[6][pos][dir]] = Direction'(dir);
                        end

                    // Defenders
                    end else begin
                        defender_count[pos] += 'd1;

                        if (weakest_defender[pos] > adj_piece_in[6][pos][dir]) begin
                            weakest_defender[pos] = adj_piece_in[6][pos][dir].piece_type;
                        end
                    end
                end
            end


            // - Pawn Influences -
            // White pawn normal moves
            if (turn_pipe[6] == WHITE && adj_piece_in[6][pos][SOUTH] == Tile'({WHITE, PAWN}) && adj_mask[pos][SOUTH]) begin
                if (adj_dist_in[6][pos][SOUTH] == 3'd1 || adj_dist_in[6][pos][SOUTH] == 3'd2) begin
                    has_attacker[pos][PAWN] = 1'd1;
                    attacker_dir[pos][PAWN] = SOUTH;
                end
            end
            // Black pawn normal moves
            if (turn_pipe[6] == BLACK && adj_piece_in[6][pos][NORTH] == Tile'({BLACK, PAWN}) && adj_mask[pos][NORTH]) begin
                if (adj_dist_in[6][pos][NORTH] == 3'd1 || adj_dist_in[6][pos][NORTH] == 3'd2) begin
                    has_attacker[pos][PAWN] = 1'd1;
                    attacker_dir[pos][PAWN] = NORTH;
                end
            end
            for (int i=0; i<=1; i+=1) begin
                // White pawn diag attacks
                if (RANK>1 && adj_piece_in[6][pos][w_pawn_dir[i]] == Tile'({WHITE, PAWN})
                    && adj_dist_in[6][pos][w_pawn_dir[i]] == 3'd1) begin

                    if (turn_pipe[6]==WHITE) begin
                        attacker_count[pos] += 'd1;
                        weakest_attacker[pos] = PAWN;

                        if (adj_mask[pos][w_pawn_dir[i]] && board_pipe[6][pos]!=NULL_PIECE) begin
                            has_attacker[pos][PAWN] = 1'b1;
                            attacker_dir[pos][PAWN] = Direction'(w_pawn_dir[i]);
                        end
                    end else begin
                        defender_count[pos] += 'd1;
                        weakest_defender[pos] = PAWN;
                    end
                end

                // Black pawn diag attacks
                if (RANK<6 && adj_piece_in[6][pos][b_pawn_dir[i]] == Tile'({BLACK, PAWN})
                    && adj_dist_in[6][pos][b_pawn_dir[i]] == 3'd1) begin

                    if (turn_pipe[6]==BLACK) begin
                        attacker_count[pos] += 'd1;
                        weakest_attacker[pos] = PAWN;

                        if (adj_mask[pos][b_pawn_dir[i]] && board_pipe[6][pos]!=NULL_PIECE) begin
                            has_attacker[pos][PAWN] = 1'b1;
                            attacker_dir[pos][PAWN] = Direction'(b_pawn_dir[i]);
                        end
                    end else begin
                        defender_count[pos] += 'd1;
                        weakest_defender[pos] = PAWN;
                    end
                end
            end


            // - Knight Directions -
            for (Direction dir=Direction'(0); dir<8; dir=Direction'(dir+1)) begin
                if (knight_data_in[pos][dir].has_knight) begin
                    if (knight_data_in[pos][dir].piece_color == turn_pipe[6]) begin
                        weakest_attacker[pos] = (weakest_attacker[pos] > KNIGHT) ? KNIGHT : weakest_attacker[pos];
                        attacker_count[pos] += 'd1;

                        if (knight_mask[pos][dir]) begin
                            has_attacker[pos][KNIGHT] = 1'b1;
                            attacker_dir[pos][KNIGHT] = Direction'(dir);
                        end

                    end else begin
                        weakest_defender[pos] = (weakest_defender[pos] > KNIGHT) ? KNIGHT : weakest_defender[pos];
                        defender_count[pos] += 'd1;
                    end
                end
            end
        end
	end


endmodule