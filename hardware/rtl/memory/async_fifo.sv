module async_fifo #(
    parameter int DATA_WIDTH = 8,
    parameter int DEPTH = 1024
) (
    input wr_clk,
    input wr_rst_n,
    input wr_en,
    input logic [DATA_WIDTH-1:0] wr_data,
    output logic full,

    input rd_clk,
    input rd_rst_n,
    input rd_en,
    output logic [DATA_WIDTH-1:0] rd_data,
    output logic empty
);

    localparam int PTR_BITS = $clog2(DEPTH);
    localparam int PTR_WIDTH = PTR_BITS + 1;

    initial begin
        if (DATA_WIDTH <= 0) begin
            $error("async_fifo DATA_WIDTH must be positive");
        end
        if (DEPTH < 2) begin
            $error("async_fifo DEPTH must be at least 2");
        end
        if ((DEPTH & (DEPTH - 1)) != 0) begin
            $error("async_fifo DEPTH must be a power of two");
        end
    end

    logic [DATA_WIDTH-1:0] mem[0:DEPTH-1];

    logic [PTR_WIDTH-1:0] wr_bin, wr_bin_next;
    logic [PTR_WIDTH-1:0] wr_gray, wr_gray_next;
    logic [PTR_WIDTH-1:0] rd_bin, rd_bin_next;
    logic [PTR_WIDTH-1:0] rd_gray, rd_gray_next;

    logic [PTR_WIDTH-1:0] rd_gray_wrclk_meta, rd_gray_wrclk_sync;
    logic [PTR_WIDTH-1:0] wr_gray_rdclk_meta, wr_gray_rdclk_sync;
    logic [PTR_WIDTH-1:0] full_compare_gray;

    wire wr_accept = wr_en && !full;
    wire rd_accept = rd_en && !empty;

    function automatic logic [PTR_WIDTH-1:0] bin_to_gray(input logic [PTR_WIDTH-1:0] value);
        bin_to_gray = (value >> 1) ^ value;
    endfunction : bin_to_gray

    always_comb begin
        wr_bin_next = wr_bin + PTR_WIDTH'(wr_accept);
        wr_gray_next = bin_to_gray(wr_bin_next);
        rd_bin_next = rd_bin + PTR_WIDTH'(rd_accept);
        rd_gray_next = bin_to_gray(rd_bin_next);

        full_compare_gray = rd_gray_wrclk_sync;
        full_compare_gray[PTR_WIDTH-1] = ~rd_gray_wrclk_sync[PTR_WIDTH-1];
        full_compare_gray[PTR_WIDTH-2] = ~rd_gray_wrclk_sync[PTR_WIDTH-2];
    end

    always_ff @(posedge wr_clk) begin
        if (!wr_rst_n) begin
            wr_bin <= '0;
            wr_gray <= '0;
            rd_gray_wrclk_meta <= '0;
            rd_gray_wrclk_sync <= '0;
        end else begin
            rd_gray_wrclk_meta <= rd_gray;
            rd_gray_wrclk_sync <= rd_gray_wrclk_meta;

            if (wr_accept) begin
                mem[wr_bin[PTR_BITS-1:0]] <= wr_data;
                wr_bin <= wr_bin_next;
                wr_gray <= wr_gray_next;
            end
        end
    end

    always_ff @(posedge rd_clk) begin
        if (!rd_rst_n) begin
            rd_bin <= '0;
            rd_gray <= '0;
            wr_gray_rdclk_meta <= '0;
            wr_gray_rdclk_sync <= '0;
        end else begin
            wr_gray_rdclk_meta <= wr_gray;
            wr_gray_rdclk_sync <= wr_gray_rdclk_meta;

            if (rd_accept) begin
                rd_bin <= rd_bin_next;
                rd_gray <= rd_gray_next;
            end
        end
    end

    assign rd_data = mem[rd_bin[PTR_BITS-1:0]];
    assign empty = (rd_gray == wr_gray_rdclk_sync);
    assign full = (wr_gray == full_compare_gray);

endmodule : async_fifo
