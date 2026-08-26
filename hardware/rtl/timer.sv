// By Emet Behrendt

import chess_defs::*;

module timer #(
    parameter int CLOCK_FREQ = 100_000_000
) (
    input logic clk,
    input logic rst,
    input logic run,
    output TimeType time_ms
);

    localparam int CLKS_PER_MS = CLOCK_FREQ / 1000;
    localparam int COUNTER_BITS = (CLKS_PER_MS <= 1) ? 1 : $clog2(CLKS_PER_MS);

    logic [COUNTER_BITS-1:0] clk_count;
    TimeType time_ms_reg;

    assign time_ms = time_ms_reg;

    // The timer deliberately holds its partial millisecond count while paused.
    always_ff @(posedge clk) begin
        if (rst) begin
            clk_count <= '0;
            time_ms_reg <= TimeType'(0);
        end else if (run) begin
            if (clk_count == COUNTER_BITS'(CLKS_PER_MS - 1)) begin
                clk_count <= '0;
                if (time_ms_reg != TimeType'('1)) begin
                    time_ms_reg <= time_ms_reg + TimeType'(1);
                end
            end else begin
                clk_count <= clk_count + COUNTER_BITS'(1);
            end
        end
    end

endmodule : timer
