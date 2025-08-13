
// By Emet Behrendt

// Package for definitions relating to the move generator
package move_generator_defs;

    import general_chess_defs::*;

    localparam move_gen_delay = 11;

    // -- Define Move Generator Operations -- 
    typedef enum {
        MOVE_GEN_IDLE_OP,
        MOVE_GEN_NORMAL_OP,
        MOVE_GEN_TARGETED_OP,
        MOVE_GEN_QSEARCH_OP
    } MoveGenOp;

    typedef struct packed {
		Color piece_color;
		logic has_knight;
		logic has_king_or_major;
	} KnightBusData;

    typedef reg [2:0] MovePriority;
    localparam MovePriority NULL_MOVE_PRIORITY = MovePriority'('d0);
    localparam MovePriority UNKNOWN_MOVE_PRIORITY = MovePriority'('dx);

endpackage : move_generator_defs


import general_chess_defs::*;
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
    KnightBusData knight_data_in[64][8]; // Indexed like [layer][position][direction];

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
    MovePriority tile_move_priority[64]; // The best score a given tile can produce
    Direction tile_move_dir[64]; // Distance of best move
    logic [2:0] tile_move_dist[64]; // Direction of best move
    MovePriority overall_move_priority;  // The best score for the entire board

    logic is_best_move_knight, is_best_move_knight_wire;
    Direction best_move_direction, best_move_direction_wire;

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

    generate
        genvar i;
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

    // ========== Generate Tile PEs ==========
    generate
        for (genvar pos=0; pos<64; pos+=1) begin : gen_move_PE
            move_generator_tile_PE #(.POS(pos)) tile_PE (
                .clk(clk),

                // Move Generation Config
                .adj_piece_in(adj_piece_in[6][pos]),
                .adj_dist_in(adj_dist_in[6][pos]),
                .knight_data_in(knight_data_in[pos]),
                .adj_mask(adj_mask[0][pos]),
                .knight_mask(knight_mask[0][pos]),

                // Selecting target move
                .target_move(target_move_pipe[6]),

                // Board Data
                .tile_data(board_pipe[6][pos]),
                .turn(turn_pipe[6]),
                .castle_perms(castle_perms_pipe[6]),
                .has_ep(has_ep_pipe[6]),
                .ep_file(ep_file_pipe[6]),
                // [6:0]   halfmove_clock, // Unused?

                // Generated Output
                .best_local_move(), // The best move that ends on this tile (not overall)
                .local_move_score()
            );
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


endmodule