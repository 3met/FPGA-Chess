// One shared three-way victim selector and same-position replacement datapath.
import chess_defs::*;
import tt_defs::*;
module tt_replacement #(
    parameter int TAG_BITS = TT_DEFAULT_TAG_BITS,
    parameter int WAY_BITS = ((TAG_BITS + TT_ENTRY_PAYLOAD_BITS + TT_WORD_BITS-1)/TT_WORD_BITS)*TT_WORD_BITS,
    parameter int unsigned STALE_DEPTH_TOLERANCE = 4
) (
    input logic [TT_WAYS*WAY_BITS-1:0] old_entry,
    input logic [WAY_BITS-1:0] new_way,
    output logic position_matches,
    output logic replace,
    output logic [$clog2(TT_WAYS)-1:0] selected_way,
    output logic [WAY_BITS-1:0] updated_way
);
    typedef struct packed {
        TTAge age;
        TTDepth depth;
        EvalScore score;
        TTMoveBits best_move_bits;
        logic [TAG_BITS-1:0] tag;
        TTBoundType bound_type;
    } Way;
    Way incoming, candidates[TT_WAYS], victim, updated;
    TTAge relative_age[TT_WAYS];
    // Signed depth-minus-eight-times-age follows Stockfish's general policy.
    localparam int VALUE_BITS = (($bits(TTDepth) > TT_AGE_BITS+3) ? $bits(TTDepth) : TT_AGE_BITS+3) + 2;
    logic signed [VALUE_BITS-1:0] value[TT_WAYS];
    always_comb begin
        incoming = Way'(new_way);
        selected_way = '0;
        position_matches = 1'b0;
        for (int way = 0; way < TT_WAYS; way++) begin
            candidates[way] = Way'(old_entry[way*WAY_BITS +: WAY_BITS]);
            relative_age[way] = incoming.age - candidates[way].age;
            value[way] = VALUE_BITS'(candidates[way].depth) - (VALUE_BITS'(relative_age[way]) <<< 3);
            // Empty ways win before any occupied victim, including very old ones.
            if (candidates[way].bound_type == TT_BOUND_INVALID)
                value[way] = {1'b1, {(VALUE_BITS-1){1'b0}}};
        end
        for (int way = 1; way < TT_WAYS; way++)
            if (value[way] < value[selected_way]) selected_way = $clog2(TT_WAYS)'(way);
        // Prefer the first matching way and never touch either other way.
        for (int way = 0; way < TT_WAYS; way++) begin
            if (!position_matches && candidates[way].bound_type != TT_BOUND_INVALID
                    && candidates[way].tag == incoming.tag) begin
                selected_way = $clog2(TT_WAYS)'(way);
                position_matches = 1'b1;
            end
        end
        victim = candidates[selected_way];
        // Equal squares encode no move; retain the hint only for the same position.
        updated = incoming;
        if (position_matches && incoming.best_move_bits[$bits(Position) +: $bits(Position)]
                == incoming.best_move_bits[0 +: $bits(Position)])
            updated.best_move_bits = victim.best_move_bits;
        updated_way = WAY_BITS'(updated);
        replace = tt_should_replace(victim.bound_type != TT_BOUND_INVALID,
            position_matches, victim.age, victim.depth, victim.bound_type,
            incoming.age, incoming.depth, incoming.bound_type, STALE_DEPTH_TOLERANCE);
    end
endmodule
