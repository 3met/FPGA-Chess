// Portable combinational-read dual-port ROM.

module inferred_dual_port_rom #(
    parameter int NUM_WORDS = 1,
    parameter int WORD_SIZE = 1,
    parameter MEM_INIT_FILE = ""
) (
    input logic [$clog2(NUM_WORDS)-1:0] address_a,
    input logic [$clog2(NUM_WORDS)-1:0] address_b,
    input logic clock,
    input logic rden_a,
    input logic rden_b,
    output logic [WORD_SIZE-1:0] q_a,
    output logic [WORD_SIZE-1:0] q_b
);

    logic [WORD_SIZE-1:0] mem [0:NUM_WORDS-1];

    initial begin
        if (MEM_INIT_FILE != "") begin
            $readmemh(MEM_INIT_FILE, mem);
        end
    end

    assign q_a = rden_a ? mem[address_a] : '0;
    assign q_b = rden_b ? mem[address_b] : '0;

endmodule : inferred_dual_port_rom
