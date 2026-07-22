// Assert reset immediately and release it only after several local clock edges.
module reset_release #(
    parameter int RELEASE_CYCLES = 8
) (
    input logic clk,
    input logic async_reset_n,
    output logic reset_n
);

    localparam int COUNTER_BITS = $clog2(RELEASE_CYCLES + 1);

    logic [COUNTER_BITS-1:0] release_count = '0;

    initial begin
        if (RELEASE_CYCLES < 2) begin
            $error("reset_release RELEASE_CYCLES must be at least two");
        end
    end

    always_ff @(posedge clk or negedge async_reset_n) begin
        if (!async_reset_n) begin
            release_count <= '0;
        end else if (release_count != COUNTER_BITS'(RELEASE_CYCLES)) begin
            release_count <= release_count + COUNTER_BITS'(1);
        end
    end

    assign reset_n = release_count == COUNTER_BITS'(RELEASE_CYCLES);

endmodule : reset_release
