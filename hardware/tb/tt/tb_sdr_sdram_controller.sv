`timescale 1ns/1ns

import tt_defs::*;

module tb_sdr_sdram_controller;
    logic clk = 1'b0;
    logic rst_n = 1'b0;
    always #5 clk = ~clk;
    logic ready, error, req_valid, req_ready, req_write;
    TTWordAddress req_address; logic [3:0] req_length;
    logic write_valid, write_ready, write_last; logic [15:0] write_data;
    logic read_valid, read_ready, read_last; logic [15:0] read_data;
    logic done_valid, done_error;
    logic [12:0] dram_addr; logic [1:0] dram_ba;
    logic dram_cas_n, dram_cke, dram_cs_n, dram_ldqm, dram_ras_n, dram_udqm, dram_we_n;
    wire [15:0] dram_dq;
    logic dq_drive_enable; logic [15:0] dq_drive_data; integer read_delay, read_drive_count;
    assign dram_dq = dq_drive_enable ? dq_drive_data : 16'hzzzz;
    int precharge_count, refresh_count, mode_count, activate_count, write_count;
    logic physical_write_active;
    int physical_write_words;
    logic [15:0] physical_write_data[0:7];
    int pass_count, fail_count;

    sdr_sdram_controller #(.CLOCK_FREQ(1_000_000), .ENTRY_COUNT(2)) dut (
        .clk, .read_capture_clk(clk), .rst_n, .ready, .error, .req_valid, .req_ready, .req_write, .req_address, .req_length,
        .write_valid, .write_ready, .write_data, .write_last,
        .read_valid, .read_ready, .read_data, .read_last,
        .done_valid, .done_ready(1'b1), .done_error,
        .dram_addr, .dram_ba, .dram_cas_n, .dram_cke, .dram_cs_n, .dram_dq,
        .dram_ldqm, .dram_ras_n, .dram_udqm, .dram_we_n);

    always @(posedge clk) begin
        if (!dram_cs_n && dram_cke) begin
            case ({dram_ras_n, dram_cas_n, dram_we_n})
                3'b010: precharge_count++;
                3'b001: refresh_count++;
                3'b000: mode_count++;
                3'b011: activate_count++;
                3'b100: write_count++;
                default: begin end
            endcase
            // SDR SDRAM advances a write burst on every clock, independent of
            // gaps on the controller's upstream ready/valid interface.
            if ({dram_ras_n, dram_cas_n, dram_we_n} == 3'b100) begin
                physical_write_active <= 1'b1;
                physical_write_words <= 1;
                physical_write_data[0] <= dram_dq;
            end else if (physical_write_active) begin
                if ({dram_ras_n, dram_cas_n, dram_we_n} == 3'b110) begin
                    physical_write_active <= 1'b0;
                end else begin
                    physical_write_data[physical_write_words] <= dram_dq;
                    physical_write_words <= physical_write_words + 1;
                end
            end
            if ({dram_ras_n, dram_cas_n, dram_we_n} == 3'b101) begin
                read_delay <= 3;
                read_drive_count <= 0;
            end
        end
        if (read_delay > 0) begin
            read_delay <= read_delay - 1;
            if (read_delay == 1) begin
                dq_drive_enable <= 1'b1;
                dq_drive_data <= 16'h9abc;
                read_drive_count <= 1;
            end
        end else if (dq_drive_enable) begin
            if (read_drive_count == 1) begin dq_drive_data <= 16'hdef0; read_drive_count <= 2; end
            else dq_drive_enable <= 1'b0;
        end
    end

    task automatic check(input logic condition, input string label);
        if (condition) begin
            pass_count += 1;
        end else begin
            fail_count += 1;
            $error("[FAIL] %s", label);
        end
    endtask

    initial begin
        req_valid = 0; req_write = 0; req_address = 0; req_length = 0;
        write_valid = 0; write_data = 0; write_last = 0; read_ready = 1;
        precharge_count = 0; refresh_count = 0; mode_count = 0; activate_count = 0; write_count = 0;
        dq_drive_enable = 0; dq_drive_data = 0; read_delay = 0; read_drive_count = 0;
        physical_write_active = 0; physical_write_words = 0;
        pass_count = 0; fail_count = 0;
        repeat (3) @(posedge clk); rst_n = 1;
        do @(posedge clk); while (!ready);
        check(!error, "initialization completed without error");
        check(precharge_count >= 1, "initialization precharged SDRAM");
        check(refresh_count >= 2, "initialization issued refreshes");
        check(mode_count == 1, "mode register programmed once");
        check(write_count >= 2, "metadata sweep invalidated every test entry");

        physical_write_words = 0;
        req_write = 1; req_address = 20; req_length = 2; req_valid = 1;
        do @(posedge clk); while (!req_ready);
        req_valid = 0;
        repeat (3) @(posedge clk);
        write_valid = 1; write_data = 16'h1234; write_last = 0;
        do @(posedge clk); while (!write_ready);
        write_valid = 0;
        repeat (3) @(posedge clk);
        write_valid = 1; write_data = 16'h5678; write_last = 1;
        do @(posedge clk); while (!write_ready);
        write_valid = 0; write_last = 0;
        do @(posedge clk); while (!done_valid);
        check(!done_error, "runtime burst completed");
        check(write_count >= 3, "runtime write command issued");
        check(physical_write_words == 2, "gapped input produced exactly two physical beats");
        check(physical_write_data[0] == 16'h1234 && physical_write_data[1] == 16'h5678,
            "gapped input retained consecutive physical write data");

        req_write = 0; req_address = 20; req_length = 2; req_valid = 1;
        do @(posedge clk); while (!req_ready);
        req_valid = 0;
        do @(posedge clk); while (!read_valid);
        check(read_data == 16'h9abc && !read_last, "first read word captured on safe edge");
        @(posedge clk);
        check(read_valid && read_data == 16'hdef0 && read_last, "second read word completed burst");
        do @(posedge clk); while (!done_valid);

        repeat (20) @(posedge clk);
        check(refresh_count >= 3, "distributed refresh continued after initialization");
        $display("Pass Count: %0d", pass_count);
        $display("Fail Count: %0d", fail_count);
        if (fail_count != 0) $fatal(1, "SDRAM controller test failed");
        $finish;
    end

    // Bound ready/valid waits so a stalled controller fails promptly in CI.
    initial begin
        #1_000_000;
        $fatal(1, "SDRAM controller testbench timed out");
    end
endmodule
