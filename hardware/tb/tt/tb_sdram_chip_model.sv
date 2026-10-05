`timescale 1ns/1ns

// Anchor the profiling model's first output beat to JEDEC CAS timing,
// independently of the controller's configurable capture pipeline.
module tb_sdram_chip_model #(parameter int CAS_LATENCY = 2);
    logic clk = 0;
    logic [12:0] addr = 0;
    logic [2:0] command = 3'b111;
    logic drive = 0;
    logic [15:0] write_data = 0;
    wire [15:0] dq;
    int pass_count = 0, fail_count = 0;
    logic burst_matches;
    localparam int WORDS = 4;
    logic [15:0] expected [0:WORDS-1] = '{16'h91e3, 16'h2b74, 16'hc058, 16'h6da2};
    always #5 clk = ~clk;
    assign dq = drive ? write_data : 16'hzzzz;

    sdram_chip_model #(.CAS_LATENCY(CAS_LATENCY), .READ_ACCESS_NS(2.0)) dut (
        .clk, .addr, .ba(2'b00), .cas_n(command[1]), .cke(1'b1), .cs_n(1'b0),
        .dq, .ldqm(1'b0), .ras_n(command[2]), .udqm(1'b0), .we_n(command[0])
    );

    task automatic check(input logic condition, input string message);
        if (condition) begin pass_count++; $display("[PASS] %s", message); end
        else begin fail_count++; $error("[FAIL] %s", message); end
    endtask

    // Present commands before their registering edge and restore NOP after it.
    task automatic issue(input logic [2:0] cmd, input logic [12:0] address);
        @(negedge clk); command = cmd; addr = address;
        @(posedge clk); #1;
        @(negedge clk); command = 3'b111;
    endtask

    initial begin
        // The model checks the device's power-up, refresh, and mode sequence.
        repeat (10_001) @(posedge clk);
        issue(3'b010, 13'h400);
        repeat (3) @(posedge clk);
        issue(3'b001, 0);
        repeat (8) @(posedge clk);
        issue(3'b001, 0);
        repeat (8) @(posedge clk);
        issue(3'b000, 13'((CAS_LATENCY << 4) | 7));
        repeat (3) @(posedge clk);
        issue(3'b011, 13'd7);
        repeat (3) @(posedge clk);

        drive = 1; write_data = expected[0];
        issue(3'b100, 13'd15);
        for (int word = 1; word < WORDS; word++) begin
            write_data = expected[word];
            @(posedge clk); #1;
            @(negedge clk);
        end
        command = 3'b110;
        @(posedge clk); #1;
        @(negedge clk); command = 3'b111; drive = 0;
        repeat (3) @(posedge clk);

        issue(3'b101, 13'd15);
        // Data starts after n + CAS - 1, and is valid by n + CAS.
        for (int edge_index = 1; edge_index < CAS_LATENCY; edge_index++) begin
            @(posedge clk); #3;
            if (edge_index < CAS_LATENCY - 1)
                check(dq === 16'hzzzz, "no output before the CAS driving edge");
            else check(dq === expected[0], "first word appears at the CAS driving edge");
        end
        burst_matches = 1;
        for (int word = 1; word < WORDS; word++) begin
            @(posedge clk); #3;
            burst_matches &= dq === expected[word];
        end
        check(burst_matches, "every subsequent burst word has the correct address");
        issue(3'b110, 0);
        $display("Pass Count: %0d", pass_count);
        $display("Fail Count: %0d", fail_count);
        if (fail_count != 0) $fatal(1, "SDRAM model test failed");
        $finish;
    end
    initial begin #200_000; $fatal(1, "SDRAM model test timed out"); end
endmodule

module tb_sdram_chip_model_cas3;
    tb_sdram_chip_model #(.CAS_LATENCY(3)) test();
endmodule
