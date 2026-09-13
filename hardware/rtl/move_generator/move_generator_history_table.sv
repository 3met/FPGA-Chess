// One logical quiet-history RAM shared by every thread and color.

module move_generator_history_table #(
    parameter int HISTORY_ENTRY_COUNT = 8192,
    parameter int HISTORY_ENTRY_BITS = 8
) (
    input logic clk,
    input logic rd_en,
    input logic [$clog2(HISTORY_ENTRY_COUNT)-1:0] rd_addr,
    output logic signed [HISTORY_ENTRY_BITS-1:0] rd_data,
    input logic wr_en,
    input logic [$clog2(HISTORY_ENTRY_COUNT)-1:0] wr_addr,
    input logic signed [HISTORY_ENTRY_BITS-1:0] wr_data
);

    sync_read_simple_dual_port_ram #(
        .NUM_WORDS(HISTORY_ENTRY_COUNT),
        .WORD_SIZE(HISTORY_ENTRY_BITS)
    ) history_ram (
        .clock(clk),
        .data(wr_data),
        .rdaddress(rd_addr),
        .rden(rd_en),
        .wraddress(wr_addr),
        .wren(wr_en),
        .q(rd_data)
    );

endmodule : move_generator_history_table
