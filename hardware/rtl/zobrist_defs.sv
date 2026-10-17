// By Emet Behrendt

package zobrist_defs;

    import chess_defs::*;
    import chess_helpers::*;

    typedef logic [$bits(Tile)+$bits(Position)-1:0] ZobristFeature;

    // Concatenation avoids arithmetic in every hash lane. Empty and spare
    // piece encodings never enable a hash lane.
    function automatic ZobristFeature zobrist_tile_feature(input Tile tile, input Position pos);
        if (~valid_piece_type(tile.piece_type)) begin
            return ZobristFeature'('x);
        end

        return ZobristFeature'({tile, pos});
    endfunction : zobrist_tile_feature

endpackage : zobrist_defs
