import chess_defs::*;
import tt_defs::*;

// Verify shared request fields at the selected configuration boundaries.
module tb_rtl_types;
    TTLookupRequest request_value;
    logic [$bits(TTLookupRequest)-1:0] wire_value;
    TTLookupRequest decoded_value;
    initial begin
        // Shared request fields must preserve the highest configured routing and depth values.
        request_value = '0;
        request_value.thread_id = ThreadID'(THREAD_COUNT-1);
        request_value.ply = PlyIndex'(MAX_PLY_COUNT-1);
        request_value.depth = TTDepth'(MAX_PLY_COUNT-1);
        wire_value = request_value;
        decoded_value = TTLookupRequest'(wire_value);
        if (int'(decoded_value.thread_id) != THREAD_COUNT-1
                || int'(decoded_value.ply) != MAX_PLY_COUNT-1
                || int'(decoded_value.depth) != MAX_PLY_COUNT-1)
            $fatal(1, "Configured capacities do not fit shared request types");
        $display("Pass Count: 1");
        $display("Fail Count: 0");
        $finish;
    end
endmodule
