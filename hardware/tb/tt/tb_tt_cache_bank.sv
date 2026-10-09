`timescale 1ns/1ps
module tb_tt_cache_bank;
    localparam int INDEX_BITS = 2;
    localparam int WAY_BITS = 13;
    logic clk = 0;
    always #5 clk = !clk;
    logic read_enable = 0, write_enable = 0, write_slot = 0;
    logic [INDEX_BITS-1:0] read_index = 0, write_index = 0;
    logic [WAY_BITS-1:0] write_way = 0;
    logic [1:0][WAY_BITS-1:0] read_set;
    logic read_lru, lru_write_enable = 0, lru_write_value = 0;
    logic [INDEX_BITS-1:0] lru_write_index = 0;
    int pass_count = 0, fail_count = 0;
    tt_cache_bank #(.WAY_BITS(WAY_BITS), .INDEX_BITS(INDEX_BITS)) dut (.*);
    task automatic check(input logic condition, input string label);
        if (condition) pass_count++; else begin fail_count++; $error("[FAIL] %s", label); end
    endtask
    initial begin
        // Initialize through the real write ports; no reset is imposed on the RAMs.
        for (int set_index = 0; set_index < (1 << INDEX_BITS); set_index++) begin
            for (int slot = 0; slot < 2; slot++) begin
                @(negedge clk);
                write_enable = 1; write_index = INDEX_BITS'(set_index); write_slot = 1'(slot);
                write_way = WAY_BITS'(set_index*16 + slot);
                lru_write_enable = 1; lru_write_index = INDEX_BITS'(set_index); lru_write_value = 0;
            end
        end
        @(negedge clk); write_enable = 0; lru_write_enable = 0;
        // Read results are available after a single sampling edge.
        read_enable = 1; read_index = 1;
        @(negedge clk);
        check(read_set[0] == WAY_BITS'(16) && read_set[1] == WAY_BITS'(17) && !read_lru,
            "one-cycle set read returns both candidates and replacement bit");
        // Same-set publication forwards only its slot and the simultaneous LRU touch.
        write_enable = 1; write_index = 1; write_slot = 0; write_way = WAY_BITS'(201);
        lru_write_enable = 1; lru_write_index = 1; lru_write_value = 1;
        @(negedge clk);
        check(read_set[0] == WAY_BITS'(201) && read_set[1] == WAY_BITS'(17) && read_lru,
            "same-set forwarding preserves the other way and observes new LRU state");
        write_slot = 1; write_way = WAY_BITS'(202);
        lru_write_index = 2; lru_write_value = 0;
        @(negedge clk);
        check(read_set[0] == WAY_BITS'(201) && read_set[1] == WAY_BITS'(202) && read_lru,
            "data collision and a different-set LRU touch are independent");
        write_index = 3; write_slot = 0; write_way = WAY_BITS'(203);
        lru_write_index = 1; lru_write_value = 0;
        @(negedge clk);
        check(read_set[0] == WAY_BITS'(201) && read_set[1] == WAY_BITS'(202) && !read_lru,
            "LRU collision and a different-set data publication are independent");
        write_enable = 0; lru_write_enable = 0; read_index = 3;
        @(negedge clk);
        check(read_set[0] == WAY_BITS'(203) && read_set[1] == WAY_BITS'(49),
            "published data persists after forwarding ends");
        read_index = 1;
        @(negedge clk);
        check(read_set[0] == WAY_BITS'(201) && read_set[1] == WAY_BITS'(202) && !read_lru,
            "both slot updates and LRU state persist in RAM");
        $display("Pass Count: %0d", pass_count); $display("Fail Count: %0d", fail_count);
        if (fail_count) $fatal(1, "TT cache bank test failed"); $finish;
    end
    initial begin #10_000; $fatal(1, "TT cache bank timeout"); end
endmodule
