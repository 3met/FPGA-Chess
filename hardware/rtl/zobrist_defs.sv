// By Emet Behrendt

package zobrist_defs;

    import general_chess_defs::*;

    localparam int ZOBRIST_TURN_BLACK_ADDR = 0;
    localparam int ZOBRIST_CASTLE_BASE_ADDR = 1;
    localparam int ZOBRIST_EP_BASE_ADDR = 5;
    localparam int ZOBRIST_TILE_BASE_ADDR = 13;
    localparam int ZOBRIST_PIECE_CNT = 6;
    localparam int ZOBRIST_COLOR_CNT = 2;
    localparam int ZOBRIST_ENTRY_CNT = ZOBRIST_TILE_BASE_ADDR + (ZOBRIST_COLOR_CNT * ZOBRIST_PIECE_CNT * 64);
    localparam ZOBRIST_MEM_INIT_FILE = "hardware/data/zobrist/zobrist_values.hex";
    typedef logic [$clog2(ZOBRIST_ENTRY_CNT)-1:0] ZobristAddr;

    function automatic ZobristAddr zobrist_tile_addr(input Tile tile, input Position pos);
        automatic logic [3:0] piece_index;
        if (tile.piece_type == NULL_PIECE) begin
            return ZobristAddr'(0);
        end

        piece_index = (tile.piece_color ? 4'd6 : 4'd0)
            + {1'b0, tile.piece_type} - 4'd1;
        return ZobristAddr'(10'd13 + {piece_index, 6'b0} + {4'd0, pos});
    endfunction : zobrist_tile_addr

    function automatic ZobristAddr zobrist_castle_addr(input int castle_idx);
        return ZobristAddr'(ZOBRIST_CASTLE_BASE_ADDR + castle_idx);
    endfunction : zobrist_castle_addr

    function automatic ZobristAddr zobrist_ep_addr(input BoardFile ep_file);
        return ZobristAddr'(10'd5 + {7'd0, ep_file});
    endfunction : zobrist_ep_addr

endpackage : zobrist_defs
