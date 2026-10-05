// Portable complete-line cache bank with explicit read-after-write forwarding.
module tt_cache_bank #(
    parameter int LINE_BITS = 1,
    parameter int INDEX_BITS = 1
) (
    input logic clk,
    input logic read_enable,
    input logic [INDEX_BITS-1:0] read_index,
    output logic [LINE_BITS-1:0] read_line,
    input logic write_enable,
    input logic [INDEX_BITS-1:0] write_index,
    input logic [LINE_BITS-1:0] write_line
);
    logic [LINE_BITS-1:0] ram_line, forwarded_line;
    logic forward;
    // Keep the RAM's synchronous read unconditional on collision detection.
    sync_read_simple_dual_port_ram #(.NUM_WORDS(1 << INDEX_BITS), .WORD_SIZE(LINE_BITS)) ram (
        .clock(clk), .rden(read_enable), .rdaddress(read_index), .q(ram_line),
        .wren(write_enable), .wraddress(write_index), .data(write_line));
    always_ff @(posedge clk) if (read_enable) begin
        forward <= write_enable && read_index == write_index;
        forwarded_line <= write_line;
    end
    assign read_line = forward ? forwarded_line : ram_line;
endmodule
