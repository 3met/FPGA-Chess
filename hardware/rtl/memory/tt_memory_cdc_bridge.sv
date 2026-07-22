// Clock-domain bridge for the portable TT 16-bit burst-memory protocol.

import tt_defs::*;

module tt_memory_cdc_bridge #(
    parameter int COMMAND_FIFO_DEPTH = 4,
    parameter int WRITE_FIFO_DEPTH = 4,
    parameter int READ_FIFO_DEPTH = 8,
    parameter int COMPLETION_FIFO_DEPTH = 2
) (
    input logic req_clk,
    input logic req_rst_n,
    input logic mem_clk,
    input logic mem_rst_n,
    input logic backend_ready,
    input logic backend_error,
    output logic req_memory_ready,
    output logic req_memory_error,
    input logic req_valid,
    output logic req_ready,
    input logic req_write,
    input TTWordAddress req_address,
    input logic [3:0] req_length,
    input logic write_valid,
    output logic write_ready,
    input logic [15:0] write_data,
    input logic write_last,
    output logic read_valid,
    input logic read_ready,
    output logic [15:0] read_data,
    output logic read_last,
    output logic done_valid,
    input logic done_ready,
    output logic done_error,
    output logic backend_req_valid,
    input logic backend_req_ready,
    output logic backend_req_write,
    output TTWordAddress backend_req_address,
    output logic [3:0] backend_req_length,
    output logic backend_write_valid,
    input logic backend_write_ready,
    output logic [15:0] backend_write_data,
    output logic backend_write_last,
    input logic backend_read_valid,
    output logic backend_read_ready,
    input logic [15:0] backend_read_data,
    input logic backend_read_last,
    input logic backend_done_valid,
    output logic backend_done_ready,
    input logic backend_done_error
);
    localparam int CMD_BITS = 1 + TT_EXTERNAL_WORD_ADDR_BITS + 4;
    localparam int WORD_PACKET_BITS = 17;
    logic cmd_full, cmd_empty, cmd_pop;
    logic [CMD_BITS-1:0] cmd_data;
    logic write_full, write_empty, write_pop;
    logic [WORD_PACKET_BITS-1:0] write_fifo_data;
    logic read_full, read_empty;
    logic [WORD_PACKET_BITS-1:0] read_fifo_data;
    logic done_full, done_empty;
    logic done_fifo_data;
    logic ready_meta, error_meta;

    async_fifo #(.DATA_WIDTH(CMD_BITS), .DEPTH(COMMAND_FIFO_DEPTH)) command_fifo (
        .wr_clk(req_clk), .wr_rst_n(req_rst_n), .wr_en(req_valid && req_ready),
        .wr_data({req_write, req_address, req_length}), .full(cmd_full),
        .rd_clk(mem_clk), .rd_rst_n(mem_rst_n), .rd_en(cmd_pop), .rd_data(cmd_data), .empty(cmd_empty));
    async_fifo #(.DATA_WIDTH(WORD_PACKET_BITS), .DEPTH(WRITE_FIFO_DEPTH)) write_fifo (
        .wr_clk(req_clk), .wr_rst_n(req_rst_n), .wr_en(write_valid && write_ready),
        .wr_data({write_last, write_data}), .full(write_full),
        .rd_clk(mem_clk), .rd_rst_n(mem_rst_n), .rd_en(write_pop), .rd_data(write_fifo_data), .empty(write_empty));
    // A read FIFO must hold an entire six-word SDRAM burst because SDR SDRAM
    // cannot pause a burst once it has started.
    async_fifo #(.DATA_WIDTH(WORD_PACKET_BITS), .DEPTH(READ_FIFO_DEPTH)) read_fifo (
        .wr_clk(mem_clk), .wr_rst_n(mem_rst_n), .wr_en(backend_read_valid && backend_read_ready),
        .wr_data({backend_read_last, backend_read_data}), .full(read_full),
        .rd_clk(req_clk), .rd_rst_n(req_rst_n), .rd_en(read_valid && read_ready), .rd_data(read_fifo_data), .empty(read_empty));
    async_fifo #(.DATA_WIDTH(1), .DEPTH(COMPLETION_FIFO_DEPTH)) completion_fifo (
        .wr_clk(mem_clk), .wr_rst_n(mem_rst_n), .wr_en(backend_done_valid && backend_done_ready),
        .wr_data(backend_done_error), .full(done_full),
        .rd_clk(req_clk), .rd_rst_n(req_rst_n), .rd_en(done_valid && done_ready), .rd_data(done_fifo_data), .empty(done_empty));

    assign req_ready = !cmd_full;
    assign write_ready = !write_full;
    assign read_valid = !read_empty;
    assign {read_last, read_data} = read_fifo_data;
    assign done_valid = !done_empty;
    assign done_error = done_fifo_data;
    assign backend_req_valid = !cmd_empty;
    assign {backend_req_write, backend_req_address, backend_req_length} = cmd_data;
    assign cmd_pop = backend_req_valid && backend_req_ready;
    assign backend_write_valid = !write_empty;
    assign {backend_write_last, backend_write_data} = write_fifo_data;
    assign write_pop = backend_write_valid && backend_write_ready;
    assign backend_read_ready = !read_full;
    assign backend_done_ready = !done_full;

    always_ff @(posedge req_clk) begin
        if (!req_rst_n) begin
            ready_meta <= 1'b0;
            req_memory_ready <= 1'b0;
            error_meta <= 1'b0;
            req_memory_error <= 1'b0;
        end else begin
            ready_meta <= backend_ready;
            req_memory_ready <= ready_meta;
            error_meta <= backend_error;
            req_memory_error <= error_meta;
        end
    end
endmodule
