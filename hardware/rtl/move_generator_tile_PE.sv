
// By Emet Behrendt

import general_chess_defs::*;
import move_generator_defs::*;

module move_generator_tile_PE #(parameter POS) (
    input logic clk,

    // Tile 
    input wire Tile adj_piece_in[8],
    input wire [2:0] adj_dist_in[8],
    input wire KnightBusData knight_data_in[8],
    input wire adj_mask[8],
    input wire knight_mask[8],

    // Selecting target move
    input wire is_target_move_destination,
    input wire is_target_move_knight,
    input Direction target_move_dir, 

    // Board Data
    input wire Tile        tile_data,
    input Color            turn,
    input wire CastlePerms castle_perms,
    input logic            has_ep,
    input BoardFile        ep_file,
    // input reg [6:0]   halfmove_clock, // Unused?

    // Generated Output
    output var logic [2:0] best_move_dist, // Distance the best move travels (0 for knight)
    output var Direction best_move_dir, // Direction the best move originates from
    output logic local_move_score
);

    localparam BoardRank RANK = getRank(POS);
    localparam BoardFile FILE = getFile(POS);


    // ========== Intra-Tile Signals ==========
    logic good_knight_target;
    logic good_cardinal_target;
    logic good_diag_target;
    PieceType weakest_attacker;
    PieceType weakest_defender;

    logic [2:0] attacker_count;
    logic [2:0] defender_count;

    logic has_attacker[7];     // Refers to unmasked attackers; indexed like [piece_type]; index 0 is unused
    Direction attacker_dir[7]; // Refers to unmasked attackers; indexed like [piece_type]; index 0 is unused

    Direction tile_move_dir; // Distance of best move
    logic [2:0] tile_move_dist; // Direction of best move


    // ========== Compute Tile Priority (local_move_score) ==========
    always_comb begin
        // Assert a Pawn is never on the first or last rank
        if (RANK == 0 || RANK == 7) begin
            assert(tile_data.piece_type !== PAWN) else $fatal("Pawn on first/last rank!");

            if (tile_data.piece_type == PAWN) begin
                local_move_score = UNKNOWN_MOVE_PRIORITY;
            end
        end

        // Assert that Kings never touch
        if (tile_data.piece_type == KING) begin
            for (Direction dir=Direction'(0); dir < 8; dir=Direction'(dir+1)) begin
                if (adj_piece_in[dir]==KING && adj_dist_in[dir]==3'd0) begin
                    $fatal("King Attacking King!");
                    local_move_score = UNKNOWN_MOVE_PRIORITY;
                end
            end
        end

        // Assert that SPARE_PIECE type is not used
        if (tile_data.piece_type == SPARE_PIECE) begin
            $fatal("Unknown \"SPARE_PIECE\" found...");
            local_move_score = UNKNOWN_MOVE_PRIORITY;
        end

        // NULL score if occupied by a friendly piece
        if (tile_data.piece_color==turn && tile_data.piece_type!=NULL_PIECE) begin
            local_move_score = NULL_MOVE_PRIORITY;
            tile_move_dir = Direction'('dx);
            tile_move_dist = 3'dx;

        // Return target move if applicable
        end else if (is_target_move_destination
            && (    ( is_target_move_knight && knight_mask[dir])
                 || (~is_target_move_knight && adj_mask[dir]))) begin
            
            local_move_score = MAX_MOVE_PRIORITY;
            tile_move_dir = target_move_dir;
            tile_move_dist = (is_target_move_knight ? 'd0 : adj_dist_in[target_move_dir]);

        // NULL score for no attackers and pawn moves
        end else if (   ~has_attacker[PAWN] && ~has_attacker[KNIGHT] && ~has_attacker[BISHOP]
                     && ~has_attacker[ROOK] && ~has_attacker[QUEEN] && ~has_attacker[KING]) begin
            local_move_score = NULL_MOVE_PRIORITY;
            tile_move_dir = Direction'('dx);
            tile_move_dist = 3'dx;

        // Normal move
        end else begin
            // Initial score set such that final scores is >0 (non-null)
            // and will never overflow given its size
            local_move_score = MovePriority'(4'd3);

            // - Score based on possible material trades -
            // Bonus for killing a more valuable piece
            if (PIECE_VALS_1[tile_data.piece_type] > PIECE_VALS_1[weakest_attacker]) begin
                local_move_score += 4'd2;

            // Bonus for killing a piece of equal value when you have
            // attacker count advantage
            end else if (PIECE_VALS_1[tile_data.piece_type] == PIECE_VALS_1[weakest_attacker]) begin
                if (attacker_count > defender_count) begin
                    local_move_score += 4'd1;
                end

            // No kill or kill less valuable than attacker
            end else begin
                // Attacker advantage
                if (attacker_count > defender_count) begin
                    if (defender_count == 3'd0) begin
                        local_move_score += 3'd1;

                    end else if (PIECE_VALS_1[weakest_defender] + PIECE_VALS_1[tile_data.piece_type] < PIECE_VALS_1[weakest_attacker]) begin
                        local_move_score -= 4'd1;
                    end

                // And defender has advantage
                end else begin
                    local_move_score -= 4'd2;
                end
            end

            // - Apply flags and choose attacker -
            // Go by flags if there are no defenders
            if (defender_count == 0) begin
                if (good_knight_target && has_attacker[KNIGHT]) begin
                    tile_move_dir = attacker_dir[KNIGHT];
                    tile_move_dist = 3'd0; // Distance is zero for knights
                    local_move_score += 2;

                end else if (good_diag_target && has_attacker[BISHOP]) begin
                    tile_move_dir = attacker_dir[BISHOP];
                    tile_move_dist = adj_dist_in[tile_move_dir];
                    local_move_score += 2;

                end else if (good_cardinal_target && has_attacker[ROOK]) begin
                    tile_move_dir = attacker_dir[ROOK];
                    tile_move_dist = adj_dist_in[tile_move_dir];
                    local_move_score += 2;

                end else if (good_cardinal_target && has_attacker[QUEEN]) begin
                    tile_move_dir = attacker_dir[QUEEN];
                    tile_move_dist = adj_dist_in[tile_move_dir];
                    local_move_score += 1;

                end else if (good_diag_target && has_attacker[QUEEN]) begin
                    tile_move_dir = attacker_dir[QUEEN];
                    tile_move_dist = adj_dist_in[tile_move_dir];
                    local_move_score += 1;

                end else if (has_attacker[PAWN]) begin
                    tile_move_dir = attacker_dir[PAWN];
                    tile_move_dist = adj_dist_in[tile_move_dir];

                end else if (has_attacker[KNIGHT]) begin
                    tile_move_dir = attacker_dir[KNIGHT];
                    tile_move_dist = 3'd0; // Distance is zero for knights

                end else if (has_attacker[BISHOP]) begin
                    tile_move_dir = attacker_dir[BISHOP];
                    tile_move_dist = adj_dist_in[tile_move_dir];

                end else if (has_attacker[ROOK]) begin
                    tile_move_dir = attacker_dir[ROOK];
                    tile_move_dist = adj_dist_in[tile_move_dir];

                end else if (has_attacker[QUEEN]) begin
                    tile_move_dir = attacker_dir[QUEEN];
                    tile_move_dist = adj_dist_in[tile_move_dir];

                end else if (has_attacker[KING]) begin
                    tile_move_dir = attacker_dir[KING];
                    tile_move_dist = adj_dist_in[tile_move_dir];

                // Should never reach here
                end else begin
                    tile_move_dir = Direction'('dx);
                    tile_move_dist = 3'dx;
                    local_move_score = MovePriority'('dx);
                end

            // If there are defenders, use weakest attacker
            end else begin
                // Special case to deal with pawn forward moves
                if (has_attacker[PAWN]) begin
                    tile_move_dir = attacker_dir[PAWN];
                end else begin
                    tile_move_dir = attacker_dir[weakest_attacker];
                end

                if (weakest_attacker == KNIGHT) begin
                    tile_move_dist = 3'd0; // Distance is zero for knights
                end else begin
                    tile_move_dist = adj_dist_in[tile_move_dir];
                end

                if (weakest_attacker == QUEEN && (good_diag_target || good_cardinal_target)) begin
                    local_move_score += 1;
                end else if (weakest_attacker == KNIGHT && good_knight_target) begin
                    local_move_score += 2;
                end else if (weakest_attacker == ROOK && good_cardinal_target) begin
                    local_move_score += 2;
                end else if (weakest_attacker == BISHOP && good_diag_target) begin
                    local_move_score += 2;
                end

                // Should never happen
                if (weakest_attacker == SPARE_PIECE || weakest_attacker == NULL_PIECE) begin
                    tile_move_dir = Direction'('dx);
                    tile_move_dist = 3'dx;
                    local_move_score = MovePriority'('dx);
                end
            end
        end
    end


    // ========== Compute Tile Flags (good_knight_target, good_cardinal_target, good_diag_target) ==========
	always_comb begin
        good_knight_target = 1'b0;
        for (Direction dir=Direction'(0); dir<8; dir=Direction'(dir+1)) begin
            good_knight_target |= (   knight_data_in[dir].has_king_or_major
                                   && knight_data_in[dir].piece_color == ~turn);
        end
        
        good_cardinal_target = 1'b0;
        good_diag_target = 1'b0;
        for (int i=0; i<4; i+=1) begin
            good_cardinal_target |= (adj_piece_in[CARDINAL_DIR[i]] == Tile'({~turn, KING}));
            good_cardinal_target |= (adj_piece_in[CARDINAL_DIR[i]] == Tile'({~turn, QUEEN}));

            good_diag_target |= (adj_piece_in[DIAG_DIR[i]] == Tile'({~turn, KING}));
            good_diag_target |= (adj_piece_in[DIAG_DIR[i]] == Tile'({~turn, QUEEN}));
            good_diag_target |= (adj_piece_in[DIAG_DIR[i]] == Tile'({~turn, ROOK}));
        end
	end


    // --- Compute weakest_attacker and weakest_defender --- 
	// --- Compute attacker_count and defender_count --- 
	// --- Compute has_attacker and attacker_dir --- 
	localparam Direction b_pawn_dir[2] = '{NORTH_WEST, NORTH_EAST};
	localparam Direction w_pawn_dir[2] = '{SOUTH_WEST, SOUTH_EAST};
	always_comb begin
        automatic BoardRank RANK = getRank(POS);
        automatic BoardFile FILE = getFile(POS);

        // Set default values
        weakest_attacker = KING;
        weakest_defender = KING;
        attacker_count = 'd0;
        defender_count = 'd0;
        for (int p=PAWN; p<=KING; p+=1) begin
            has_attacker[p] = 1'd0;
            attacker_dir[p] = Direction'('dx);
        end

        // - Update king, queen, rook, and bishop influences -
        for (Direction dir=Direction'(0); dir<8; dir=Direction'(dir+1)) begin
            if (   (adj_piece_in[dir]==QUEEN)
                || (adj_piece_in[dir]==ROOK && isDirCardinal(Direction'(dir)))
                || (adj_piece_in[dir]==BISHOP && isDirDiag(Direction'(dir)))
                || (adj_piece_in[dir]==KING && adj_dist_in[dir]==3'd1)) begin
                
                // Attackers
                if (adj_piece_in[dir].piece_color==turn) begin
                    attacker_count += 'd1;

                    if (weakest_attacker > adj_piece_in[dir]) begin
                        weakest_attacker = adj_piece_in[dir].piece_type;
                    end

                    if (adj_mask[dir]) begin
                        has_attacker[adj_piece_in[dir]] = 1'b1;
                        attacker_dir[adj_piece_in[dir]] = Direction'(dir);
                    end

                // Defenders
                end else begin
                    defender_count += 'd1;

                    if (weakest_defender > adj_piece_in[dir]) begin
                        weakest_defender = adj_piece_in[dir].piece_type;
                    end
                end
            end
        end


        // - Pawn Influences -
        // White pawn normal moves
        if (turn == WHITE && adj_piece_in[SOUTH] == Tile'({WHITE, PAWN}) && adj_mask[SOUTH]) begin
            if (adj_dist_in[SOUTH] == 3'd1 || adj_dist_in[SOUTH] == 3'd2) begin
                has_attacker[PAWN] = 1'd1;
                attacker_dir[PAWN] = SOUTH;
            end
        end
        // Black pawn normal moves
        if (turn == BLACK && adj_piece_in[NORTH] == Tile'({BLACK, PAWN}) && adj_mask[NORTH]) begin
            if (adj_dist_in[NORTH] == 3'd1 || adj_dist_in[NORTH] == 3'd2) begin
                has_attacker[PAWN] = 1'd1;
                attacker_dir[PAWN] = NORTH;
            end
        end
        for (int i=0; i<=1; i+=1) begin
            // White pawn diag attacks
            if (RANK>1 && adj_piece_in[w_pawn_dir[i]] == Tile'({WHITE, PAWN})
                && adj_dist_in[w_pawn_dir[i]] == 3'd1) begin

                if (turn==WHITE) begin
                    attacker_count += 'd1;
                    weakest_attacker = PAWN;

                    if (adj_mask[w_pawn_dir[i]] && tile_data!=NULL_PIECE) begin
                        has_attacker[PAWN] = 1'b1;
                        attacker_dir[PAWN] = Direction'(w_pawn_dir[i]);
                    end
                end else begin
                    defender_count += 'd1;
                    weakest_defender = PAWN;
                end
            end

            // Black pawn diag attacks
            if (RANK<6 && adj_piece_in[b_pawn_dir[i]] == Tile'({BLACK, PAWN})
                && adj_dist_in[b_pawn_dir[i]] == 3'd1) begin

                if (turn==BLACK) begin
                    attacker_count += 'd1;
                    weakest_attacker = PAWN;

                    if (adj_mask[b_pawn_dir[i]] && tile_data!=NULL_PIECE) begin
                        has_attacker[PAWN] = 1'b1;
                        attacker_dir[PAWN] = Direction'(b_pawn_dir[i]);
                    end
                end else begin
                    defender_count += 'd1;
                    weakest_defender = PAWN;
                end
            end
        end


        // - Knight Directions -
        for (Direction dir=Direction'(0); dir<8; dir=Direction'(dir+1)) begin
            if (knight_data_in[dir].has_knight) begin
                if (knight_data_in[dir].piece_color == turn) begin
                    weakest_attacker = (weakest_attacker > KNIGHT) ? KNIGHT : weakest_attacker;
                    attacker_count += 'd1;

                    if (knight_mask[dir]) begin
                        has_attacker[KNIGHT] = 1'b1;
                        attacker_dir[KNIGHT] = Direction'(dir);
                    end

                end else begin
                    weakest_defender = (weakest_defender > KNIGHT) ? KNIGHT : weakest_defender;
                    defender_count += 'd1;
                end
            end
        end
	end


endmodule : move_generator_tile_PE
