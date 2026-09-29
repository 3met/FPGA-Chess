`timescale 1ns/1ps

module tb_synchronous_fifo;
    logic clk = 1'b0;
    logic rst_n = 1'b0;
    logic clear = 1'b0;
    logic push_valid = 1'b0;
    logic push_ready;
    logic [7:0] push_data = '0;
    logic pop_valid;
    logic pop_ready = 1'b0;
    logic [7:0] pop_data;
    logic [1:0] count;
    int pass_count = 0;
    int fail_count = 0;

    always #5 clk = ~clk;

    synchronous_fifo #(.DATA_WIDTH(8), .DEPTH(3)) dut (
        .clk, .rst_n, .clear, .push_valid, .push_ready, .push_data,
        .pop_valid, .pop_ready, .pop_data, .count
    );

    task automatic check(input logic condition, input string label);
        if (condition) pass_count++;
        else begin
            fail_count++;
            $error("[FAIL] %s", label);
        end
    endtask

    // Drive ready/valid at falling edges and accept exactly one word.
    task automatic push_word(input logic [7:0] word);
        @(negedge clk);
        while (!push_ready) @(negedge clk);
        push_data = word;
        push_valid = 1'b1;
        @(negedge clk);
        push_valid = 1'b0;
    endtask

    task automatic pop_word(input logic [7:0] expected);
        @(negedge clk);
        while (!pop_valid) @(negedge clk);
        check(pop_data === expected, $sformatf("ordered pop %02h", expected));
        pop_ready = 1'b1;
        @(negedge clk);
        pop_ready = 1'b0;
    endtask

    initial begin
        repeat (3) @(negedge clk);
        rst_n = 1'b1;
        check(count == 0 && !pop_valid, "empty after reset");

        push_word(8'h11);
        push_word(8'h22);
        push_word(8'h33);
        check(count == 3 && !push_ready, "non-power-of-two FIFO reaches capacity");
        while (!pop_valid) @(negedge clk);
        repeat (4) @(negedge clk);
        check(pop_valid && pop_data == 8'h11 && count == 3,
            "output stays stable under backpressure");

        pop_word(8'h11);
        push_word(8'h44);
        pop_word(8'h22);
        pop_word(8'h33);
        pop_word(8'h44);
        repeat (3) @(negedge clk);
        check(count == 0 && !pop_valid, "empty after wraparound drain");

        push_word(8'h55);
        push_word(8'h66);
        @(negedge clk);
        clear = 1'b1;
        @(negedge clk);
        clear = 1'b0;
        check(count == 0 && !pop_valid && push_ready, "clear discards queued words");
        push_word(8'h77);
        pop_word(8'h77);

        $display("Pass Count: %0d", pass_count);
        $display("Fail Count: %0d", fail_count);
        if (fail_count != 0) $fatal(1, "synchronous FIFO test failed");
        $finish;
    end

    initial begin
        #100_000;
        $fatal(1, "synchronous FIFO test timed out");
    end
endmodule : tb_synchronous_fifo
