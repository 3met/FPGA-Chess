// Portable synchronous-read dual-port ROM.

module sync_read_dual_port_rom #(
    parameter int NUM_WORDS = 1,
    parameter int WORD_SIZE = 1,
    parameter MEM_INIT_FILE = ""
) (
    input logic clock,
    input logic [$clog2(NUM_WORDS)-1:0] address_a,
    input logic [$clog2(NUM_WORDS)-1:0] address_b,
    input logic rden_a,
    input logic rden_b,
    output logic [WORD_SIZE-1:0] q_a,
    output logic [WORD_SIZE-1:0] q_b
);

    (* ramstyle = "M10K" *)
    (* ram_style = "block" *)
    logic [WORD_SIZE-1:0] mem [0:NUM_WORDS-1];

    initial begin
        if (MEM_INIT_FILE != "") begin
            $readmemh(MEM_INIT_FILE, mem);
        end
    end

    always_ff @(posedge clock) begin
        if (rden_a) begin
            q_a <= mem[address_a];
        end
        if (rden_b) begin
            q_b <= mem[address_b];
        end
    end

endmodule : sync_read_dual_port_rom
