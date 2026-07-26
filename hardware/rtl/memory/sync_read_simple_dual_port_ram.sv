// By Emet Behrendt

module sync_read_simple_dual_port_ram #(
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

    // These attributes are ignored by tools that do not recognize them. The
    // synchronous-read template is the portable part that enables block-RAM
    // inference on both Intel/Altera and Xilinx devices.
    (* ramstyle = "M10K, no_rw_check" *)
    (* ram_style = "block" *)
    logic [WORD_SIZE-1:0] mem [0:NUM_WORDS-1];

    always_ff @(posedge clock) begin
        if (rden) begin
            q <= mem[rdaddress];
        end

        if (wren) begin
            mem[wraddress] <= data;
        end
    end

endmodule : sync_read_simple_dual_port_ram
