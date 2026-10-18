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
    Way incoming, candidates[TT_WAYS], updated;
    TTAge relative_age[TT_WAYS];
    logic [TT_WAYS-1:0] way_matches, first_way_match;
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
        // Compare victims in parallel, retaining the lowest index on ties.
        for (int way = 0; way < TT_WAYS; way++) begin
            automatic logic lowest = 1'b1;
            for (int other = 0; other < TT_WAYS; other++) begin
                if (other < way) lowest &= value[way] < value[other];
                else lowest &= value[way] <= value[other];
            end
            selected_way |= {$clog2(TT_WAYS){lowest}} & $clog2(TT_WAYS)'(way);
            way_matches[way] = candidates[way].bound_type != TT_BOUND_INVALID
                && candidates[way].tag == incoming.tag;
        end
        position_matches = |way_matches;
        // Replacement permission and retained hints need only the first match;
        // victim quality must not feed the publication-valid decision.
        replace = !position_matches;
        updated = incoming;
        for (int way = 0; way < TT_WAYS; way++) begin
            first_way_match[way] = way_matches[way]
                && !(|(way_matches & ((TT_WAYS'(1) << way) - TT_WAYS'(1))));
            if (first_way_match[way]) begin
                selected_way = $clog2(TT_WAYS)'(way);
                if (incoming.best_move_bits[$bits(Position) +: $bits(Position)]
                        == incoming.best_move_bits[0 +: $bits(Position)])
                    updated.best_move_bits = candidates[way].best_move_bits;
                replace |= tt_should_replace(1'b1, 1'b1,
                    candidates[way].age, candidates[way].depth, candidates[way].bound_type,
                    incoming.age, incoming.depth, incoming.bound_type, STALE_DEPTH_TOLERANCE);
            end
        end
        updated_way = WAY_BITS'(updated);
    end
endmodule
