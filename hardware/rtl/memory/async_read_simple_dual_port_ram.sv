// Portable combinational-read, synchronous-write dual-port RAM.

module async_read_simple_dual_port_ram #(
    parameter int NUM_WORDS = 1,
    parameter int WORD_SIZE = 1
) (
    input logic clock,
    input logic [WORD_SIZE-1:0] data,
    input logic [$clog2(NUM_WORDS)-1:0] rdaddress,
    input logic rden,
    input logic [$clog2(NUM_WORDS)-1:0] wraddress,
    input logic wren,
    output logic [WORD_SIZE-1:0] q
);

    logic [WORD_SIZE-1:0] mem [0:NUM_WORDS-1];

    assign q = rden ? mem[rdaddress] : 'x;

    always_ff @(posedge clock) begin
        if (wren) begin
            mem[wraddress] <= data;
        end
    end

endmodule : async_read_simple_dual_port_ram
