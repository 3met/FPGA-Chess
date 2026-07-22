`timescale 1ns/1ps

module tb_async_fifo;

    logic wr_clk = 1'b0;
    logic rd_clk = 1'b0;
    logic wr_rst_n = 1'b1;
    logic rd_rst_n = 1'b1;
    logic wr_en = 1'b0;
    logic rd_en = 1'b0;
    logic [7:0] wr_data = '0;
    logic [7:0] rd_data;
    logic full;
    logic empty;

    int pass_count = 0;
    int fail_count = 0;

    always #3 wr_clk = ~wr_clk;
    always #5 rd_clk = ~rd_clk;

    async_fifo #(
        .DATA_WIDTH(8),
        .DEPTH(4)
    ) dut (
        .wr_clk(wr_clk),
        .wr_rst_n(wr_rst_n),
        .wr_en(wr_en),
        .wr_data(wr_data),
        .full(full),
        .rd_clk(rd_clk),
        .rd_rst_n(rd_rst_n),
        .rd_en(rd_en),
        .rd_data(rd_data),
        .empty(empty)
    );

    task automatic check(input logic condition, input string label);
        if (condition) begin
            pass_count += 1;
        end else begin
            fail_count += 1;
            $error("[FAIL] %s", label);
        end
    endtask : check

    task automatic reset_fifo();
        wr_rst_n = 1'b0;
        rd_rst_n = 1'b0;
        wr_en = 1'b0;
        rd_en = 1'b0;
        repeat (4) @(posedge wr_clk);
        repeat (4) @(posedge rd_clk);
        wr_rst_n = 1'b1;
        rd_rst_n = 1'b1;
        repeat (4) @(posedge wr_clk);
        repeat (4) @(posedge rd_clk);
    endtask : reset_fifo

    task automatic write_byte(input logic [7:0] value);
        @(posedge wr_clk);
        wr_data <= value;
        wr_en <= 1'b1;
        @(posedge wr_clk);
        wr_en <= 1'b0;
    endtask : write_byte

    task automatic read_byte(input logic [7:0] expected);
        wait (!empty);
        #1;
        check(rd_data === expected, $sformatf("read data 0x%02h", expected));
        @(posedge rd_clk);
        rd_en <= 1'b1;
        @(posedge rd_clk);
        rd_en <= 1'b0;
    endtask : read_byte

    initial begin
        reset_fifo();
        check(empty, "FIFO empty after reset");
        check(!full, "FIFO not full after reset");

        write_byte(8'h11);
        write_byte(8'h22);
        write_byte(8'h33);
        read_byte(8'h11);
        read_byte(8'h22);
        read_byte(8'h33);
        repeat (4) @(posedge rd_clk);
        check(empty, "FIFO empty after ordered reads");

        write_byte(8'ha0);
        write_byte(8'ha1);
        write_byte(8'ha2);
        write_byte(8'ha3);
        repeat (4) @(posedge wr_clk);
        check(full, "FIFO full after depth writes");

        read_byte(8'ha0);
        repeat (6) @(posedge wr_clk);
        check(!full, "FIFO not full after one read");
        read_byte(8'ha1);
        read_byte(8'ha2);
        read_byte(8'ha3);

        write_byte(8'ha4);
        write_byte(8'ha5);
        write_byte(8'ha6);
        write_byte(8'ha7);
        read_byte(8'ha4);
        read_byte(8'ha5);
        read_byte(8'ha6);
        read_byte(8'ha7);

        write_byte(8'h55);
        write_byte(8'h66);
        wait (!empty);
        @(posedge wr_clk);
        wr_data <= 8'h77;
        wr_en <= 1'b1;
        @(posedge rd_clk);
        rd_en <= 1'b1;
        @(posedge wr_clk);
        wr_en <= 1'b0;
        @(posedge rd_clk);
        rd_en <= 1'b0;
        read_byte(8'h66);
        read_byte(8'h77);

        reset_fifo();
        check(empty, "FIFO empty after reset recovery");
        write_byte(8'hc3);
        read_byte(8'hc3);

        $display("Pass Count: %0d", pass_count);
        $display("Fail Count: %0d", fail_count);
        if (fail_count != 0) $fatal(1, "tb_async_fifo failed");
        $finish;
    end

    initial begin
        #200_000;
        fail_count += 1;
        $fatal(1, "tb_async_fifo timed out (pass=%0d fail=%0d)", pass_count, fail_count);
    end

endmodule : tb_async_fifo
