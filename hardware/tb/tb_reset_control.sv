`timescale 1ns/1ps

module tb_reset_control;

    localparam real CLK_NS = 10.0;

    logic clk = 1'b0;
    logic reset_n = 1'b1;
    logic restart_n = 1'b1;
    logic pll_locked = 1'b0;
    logic pll_reset;
    logic clocks_ready;
    logic async_reset_n = 1'b0;
    logic released_reset_n;

    int pass_count = 0;
    int fail_count = 0;

    always #(CLK_NS / 2.0) clk = ~clk;

    reset_release release_dut (
        .clk,
        .async_reset_n,
        .reset_n(released_reset_n)
    );

    pll_startup_controller #(
        .DELAY_BITS(5),
        .FEEDBACK_TAP(2)
    ) pll_dut (
        .clk,
        .reset_n,
        .restart_n,
        .pll_locked,
        .pll_reset,
        .clocks_ready
    );

    task automatic check(input logic condition, input string label);
        if (condition) begin
            pass_count += 1;
        end else begin
            fail_count += 1;
            $error("[FAIL] %s", label);
        end
    endtask : check

    task automatic wait_for_pll_release();
        do @(posedge clk); while (pll_reset);
        #1;
    endtask : wait_for_pll_release

    task automatic wait_for_clocks_ready();
        do @(posedge clk); while (!clocks_ready);
        #1;
    endtask : wait_for_clocks_ready

    initial begin
        #1;
        check(pll_reset && !clocks_ready, "PLL begins safely held in reset without a button press");
        wait_for_pll_release();
        check(!pll_reset && !clocks_ready, "PLL reset releases after the shared LFSR delay");

        pll_locked = 1'b1;
        wait_for_clocks_ready();
        check(clocks_ready && !pll_reset, "stable PLL lock releases downstream clocks");

        // Any synchronized loss fails closed and automatically restarts.
        pll_locked = 1'b0;
        wait (!clocks_ready);
        #1;
        check(pll_reset, "lock loss immediately restarts the PLL");
        wait_for_pll_release();
        repeat (32) @(posedge clk);
        #1;
        check(pll_reset && !clocks_ready, "lock timeout automatically retries");

        restart_n = 1'b0;
        @(posedge clk);
        #1;
        check(pll_reset && !clocks_ready, "manual restart returns to the safe state");
        restart_n = 1'b1;

        // Reset release asserts immediately but deasserts only after two local edges.
        async_reset_n = 1'b1;
        @(posedge clk);
        #1;
        check(!released_reset_n, "reset remains active through first synchronization edge");
        @(posedge clk);
        #1;
        check(released_reset_n, "reset releases after two synchronization edges");
        #(CLK_NS / 4.0);
        async_reset_n = 1'b0;
        #1;
        check(!released_reset_n, "reset assertion is asynchronous");

        $display("Pass Count: %0d", pass_count);
        $display("Fail Count: %0d", fail_count);
        if (fail_count != 0) $fatal(1, "tb_reset_control failed");
        $finish;
    end

    initial begin
        #10_000;
        $fatal(1, "tb_reset_control timed out (pass=%0d fail=%0d)", pass_count, fail_count);
    end

endmodule : tb_reset_control
