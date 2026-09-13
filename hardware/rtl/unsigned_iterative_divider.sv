// By Emet Behrendt

// Small restoring divider for infrequent control-plane arithmetic. One result
// takes WIDTH cycles, avoiding a full-width combinational divider in the engine.
module unsigned_iterative_divider #(
    parameter int WIDTH = 32
) (
    input logic clk,
    input logic rst_n,
    input logic cancel,
    input logic start,
    input logic [WIDTH-1:0] numerator,
    input logic [WIDTH-1:0] denominator,
    output logic busy,
    output logic done,
    output logic [WIDTH-1:0] quotient
);

    localparam int COUNT_BITS = (WIDTH <= 1) ? 1 : $clog2(WIDTH + 1);

    logic [WIDTH-1:0] dividend;
    logic [WIDTH-1:0] divisor;
    logic [WIDTH:0] remainder;
    logic [COUNT_BITS-1:0] bits_left;

    always_ff @(posedge clk) begin
        if (!rst_n) begin
            busy <= 1'b0;
            done <= 1'b0;
            quotient <= '0;
            dividend <= '0;
            divisor <= '0;
            remainder <= '0;
            bits_left <= '0;
        end else if (cancel) begin
            busy <= 1'b0;
            done <= 1'b0;
            bits_left <= '0;
        end else begin
            done <= 1'b0;
            if (start && !busy) begin
                busy <= 1'b1;
                quotient <= '0;
                dividend <= numerator;
                divisor <= denominator;
                remainder <= '0;
                bits_left <= COUNT_BITS'(WIDTH);
            end else if (busy) begin
                automatic logic [WIDTH:0] shifted_remainder;
                shifted_remainder = {remainder[WIDTH-1:0], dividend[WIDTH-1]};
                dividend <= {dividend[WIDTH-2:0], 1'b0};
                quotient <= {quotient[WIDTH-2:0], 1'b0};
                if (shifted_remainder >= {1'b0, divisor}) begin
                    remainder <= shifted_remainder - {1'b0, divisor};
                    quotient[0] <= 1'b1;
                end else begin
                    remainder <= shifted_remainder;
                end
                bits_left <= bits_left - COUNT_BITS'(1);
                if (bits_left == COUNT_BITS'(1)) begin
                    busy <= 1'b0;
                    done <= 1'b1;
                end
            end
        end
    end

`ifndef SYNTHESIS
    always_ff @(posedge clk) begin
        if (rst_n && start)
            assert (denominator != '0) else $fatal(1, "divider denominator is zero");
    end
`endif

endmodule : unsigned_iterative_divider
