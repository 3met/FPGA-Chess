// Dual-color quiet-history RAM storage.

module move_generator_history_table #(
    parameter int HISTORY_WORDS = 4096,
    parameter int HISTORY_BITS = 9
) (
    input logic clk,
    input logic rd_en[2],
    input logic [$clog2(HISTORY_WORDS)-1:0] rd_addr[2],
    output logic signed [HISTORY_BITS-1:0] rd_data[2],
    input logic wr_en[2],
    input logic [$clog2(HISTORY_WORDS)-1:0] wr_addr[2],
    input logic signed [HISTORY_BITS-1:0] wr_data[2]
);

    genvar color;
    generate
        for (color = 0; color < 2; color++) begin : gen_color
            sync_read_simple_dual_port_ram #(
                .NUM_WORDS(HISTORY_WORDS),
                .WORD_SIZE(HISTORY_BITS)
            ) history_ram (
                .clock(clk),
                .data(wr_data[color]),
                .rdaddress(rd_addr[color]),
                .rden(rd_en[color]),
                .wraddress(wr_addr[color]),
                .wren(wr_en[color]),
                .q(rd_data[color])
            );
        end
    endgenerate

endmodule : move_generator_history_table
