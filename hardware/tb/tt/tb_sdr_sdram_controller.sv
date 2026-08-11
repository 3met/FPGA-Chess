`timescale 1ns/1ns

import tt_defs::*;

module tb_sdr_sdram_controller;

    logic clk = 1'b0;
    logic rst_n = 1'b0;
    logic ready;
    logic error;
    logic req_valid;
    logic req_ready;
    logic req_write;
    TTWordAddress req_address;
    logic [3:0] req_length;
    logic write_valid;
    logic write_ready;
    logic write_last;
    logic [15:0] write_data;
    logic read_valid;
    logic read_ready;
    logic read_last;
    logic [15:0] read_data;
    logic done_valid;
    logic done_error;
    logic [12:0] dram_addr;
    logic [1:0] dram_ba;
    logic dram_cas_n;
    logic dram_cke;
    logic dram_cs_n;
    logic dram_ldqm;
    logic dram_ras_n;
    logic dram_udqm;
    logic dram_we_n;
    wire [15:0] dram_dq;

    logic dq_drive_enable;
    logic [15:0] dq_drive_data;
    int read_delay;
    int read_drive_count;
    int precharge_count;
    int refresh_count;
    int mode_count;
    int write_count;
    logic [12:0] mode_address;
    logic [9:0] write_columns[0:15];
    logic physical_write_active;
    int physical_write_words;
    logic [15:0] physical_write_data[0:7];
    int pass_count = 0;
    int fail_count = 0;

    always #5 clk = ~clk;

    assign dram_dq = dq_drive_enable ? dq_drive_data : 16'hzzzz;

    sdr_sdram_controller #(
        .CLOCK_FREQ(1_000_000),
        .ENTRY_COUNT(2)
    ) dut (
        .clk,
        .read_capture_clk(clk),
        .rst_n,
        .ready,
        .error,
        .req_valid,
        .req_ready,
        .req_write,
        .req_address,
        .req_length,
        .write_valid,
        .write_ready,
        .write_data,
        .write_last,
        .read_valid,
        .read_ready,
        .read_data,
        .read_last,
        .done_valid,
        .done_ready(1'b1),
        .done_error,
        .dram_addr,
        .dram_ba,
        .dram_cas_n,
        .dram_cke,
        .dram_cs_n,
        .dram_dq,
        .dram_ldqm,
        .dram_ras_n,
        .dram_udqm,
        .dram_we_n
    );

    // Observe physical commands and provide a minimal two-word read response.
    always @(posedge clk) begin
        if (!dram_cs_n && dram_cke) begin
            case ({dram_ras_n, dram_cas_n, dram_we_n})
                3'b010: precharge_count++;
                3'b001: refresh_count++;
                3'b000: begin
                    mode_count++;
                    mode_address <= dram_addr;
                end
                3'b100: begin
                    write_columns[write_count] <= dram_addr[9:0];
                    write_count++;
                end
                default: begin end
            endcase

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
                read_delay <= 1;
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
            if (read_drive_count == 1) begin
                dq_drive_data <= 16'hdef0;
                read_drive_count <= 2;
            end else begin
                dq_drive_enable <= 1'b0;
            end
        end
    end

    task automatic check(input logic condition, input string label);
        if (condition) begin
            pass_count += 1;
        end else begin
            fail_count += 1;
            $error("[FAIL] %s", label);
        end
    endtask : check

    task automatic reset_dut();
        req_valid = 1'b0;
        req_write = 1'b0;
        req_address = '0;
        req_length = '0;
        write_valid = 1'b0;
        write_data = '0;
        write_last = 1'b0;
        read_ready = 1'b1;
        precharge_count = 0;
        refresh_count = 0;
        mode_count = 0;
        write_count = 0;
        dq_drive_enable = 1'b0;
        dq_drive_data = '0;
        read_delay = 0;
        read_drive_count = 0;
        physical_write_active = 1'b0;
        physical_write_words = 0;
        repeat (3) @(negedge clk);
        rst_n = 1'b1;
    endtask : reset_dut

    task automatic issue_request(
        input logic is_write,
        input TTWordAddress address,
        input logic [3:0] length
    );
        @(negedge clk);
        while (!req_ready) @(negedge clk);
        req_write = is_write;
        req_address = address;
        req_length = length;
        req_valid = 1'b1;
        @(negedge clk);
        req_valid = 1'b0;
    endtask : issue_request

    task automatic send_write_word(
        input logic [15:0] data,
        input logic last,
        input int gap_cycles = 0
    );
        repeat (gap_cycles) @(negedge clk);
        while (!write_ready) @(negedge clk);
        write_data = data;
        write_last = last;
        write_valid = 1'b1;
        @(negedge clk);
        write_valid = 1'b0;
        write_last = 1'b0;
    endtask : send_write_word

    task automatic wait_for_completion();
        while (!done_valid) @(negedge clk);
    endtask : wait_for_completion

    task automatic test_initialization();
        while (!ready) @(negedge clk);
        check(!error, "initialization completed without error");
        check(precharge_count >= 1, "initialization precharged SDRAM");
        check(refresh_count >= 2, "initialization issued refreshes");
        check(mode_count == 1, "mode register programmed once");
        check(mode_address == 13'b000_0_00_010_0_111,
            "mode register selected full-page sequential CAS-2 bursts");
        check(write_count >= 2, "metadata sweep invalidated every test entry");
    endtask : test_initialization

    task automatic test_buffered_write();
        physical_write_words = 0;
        issue_request(1'b1, TTWordAddress'(20), 4'd2);
        send_write_word(16'h1234, 1'b0, 3);
        send_write_word(16'h5678, 1'b1, 3);
        wait_for_completion();
        check(!done_error, "runtime burst completed");
        check(write_count >= 3, "runtime write command issued");
        check(physical_write_words == 2, "gapped input produced exactly two physical beats");
        check(physical_write_data[0] == 16'h1234
                && physical_write_data[1] == 16'h5678,
            "gapped input retained consecutive physical write data");
    endtask : test_buffered_write

    task automatic test_read_backpressure();
        automatic bit first_word_stable = 1'b1;

        read_ready = 1'b0;
        issue_request(1'b0, TTWordAddress'(20), 4'd2);
        while (!read_valid) @(negedge clk);
        check(read_data == 16'h9abc && !read_last,
            "first read word captured on safe edge");
        repeat (3) begin
            @(negedge clk);
            first_word_stable &= read_valid && read_data == 16'h9abc && !read_last;
        end
        check(first_word_stable, "staged read data remained stable under backpressure");
        read_ready = 1'b1;
        @(negedge clk);
        check(read_valid && read_data == 16'hdef0 && read_last,
            "second read word completed burst");
        wait_for_completion();
    endtask : test_read_backpressure

    task automatic test_row_crossing_write();
        automatic int crossing_write_base = write_count;

        issue_request(1'b1, TTWordAddress'(1022), 4'd6);
        for (int word = 0; word < 6; word++) begin
            send_write_word(16'(16'h8000 + word), word == 5);
        end
        wait_for_completion();
        check(write_count == crossing_write_base + 2,
            "row-crossing write split into two physical bursts");
        check(write_columns[crossing_write_base] == 10'd1022
                && write_columns[crossing_write_base + 1] == 10'd0,
            "row-crossing write restarted at column zero of the next row");
    endtask : test_row_crossing_write

    task automatic test_invalid_length();
        issue_request(1'b0, TTWordAddress'(0), 4'd0);
        wait_for_completion();
        check(error && done_error, "zero-length request reports a persistent protocol error");
    endtask : test_invalid_length

    initial begin
        reset_dut();
        test_initialization();
        test_buffered_write();
        test_read_backpressure();
        test_row_crossing_write();
        repeat (20) @(posedge clk);
        check(refresh_count >= 3, "distributed refresh continued after initialization");
        test_invalid_length();

        $display("Pass Count: %0d", pass_count);
        $display("Fail Count: %0d", fail_count);
        if (fail_count != 0) $fatal(1, "SDRAM controller test failed");
        $finish;
    end

    initial begin
        #1_000_000;
        $fatal(1, "SDRAM controller testbench timed out");
    end

endmodule : tb_sdr_sdram_controller
