// By Emet Behrendt

package zobrist_defs;

    import general_chess_defs::*;

    localparam int ZOBRIST_PIECE_CNT = 6;
    localparam int ZOBRIST_COLOR_CNT = 2;
    localparam int ZOBRIST_TILE_ENTRY_CNT = ZOBRIST_COLOR_CNT * ZOBRIST_PIECE_CNT * 64;
    localparam int ZOBRIST_EP_ENTRY_CNT = 8;
    localparam ZOBRIST_TILE_MEM_INIT_FILE =
        "hardware/data/zobrist/zobrist_tile_values.hex";
    localparam ZOBRIST_EP_MEM_INIT_FILE =
        "hardware/data/zobrist/zobrist_ep_values.hex";
    typedef logic [$clog2(ZOBRIST_TILE_ENTRY_CNT)-1:0] ZobristTileAddr;

    // The table is laid out as color, piece type, then square. Empty tiles
    // never issue a read, so their address is only a harmless default.
    function automatic ZobristTileAddr zobrist_tile_addr(input Tile tile, input Position pos);
        automatic logic [3:0] piece_index;
        if (tile.piece_type == NULL_PIECE) begin
            return ZobristTileAddr'(0);
        end

        piece_index = (tile.piece_color ? 4'd6 : 4'd0)
            + {1'b0, tile.piece_type} - 4'd1;
        return ZobristTileAddr'({piece_index, 6'b0} + {4'd0, pos});
    endfunction : zobrist_tile_addr

endpackage : zobrist_defs
