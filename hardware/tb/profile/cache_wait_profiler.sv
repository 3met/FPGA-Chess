`timescale 1ns/1ps

// Testbench-only timing of accepted requests until their cache-bank read issues.
module cache_wait_profiler #(parameter int QUEUE_DEPTH = 1) (
    input logic clk, rst_n, enable, accept, access,
    output longint unsigned wait_cycles, accesses,
    output int pending
);
    longint unsigned cycle_count;
    longint unsigned accepted_at[QUEUE_DEPTH];
    int read_index, write_index;

    // Retire before enqueue so overlapping accesses and accepts preserve FIFO order.
    always @(posedge clk) begin
        if (!rst_n) begin
            cycle_count = 0;
            read_index = 0;
            write_index = 0;
            pending = 0;
            wait_cycles = 0;
            accesses = 0;
        end else begin
            if (enable) begin
                if (access) begin
                    if (pending == 0) $fatal(1, "cache access has no accepted request timestamp");
                    wait_cycles += cycle_count - accepted_at[read_index];
                    accesses++;
                    read_index = (read_index + 1) % QUEUE_DEPTH;
                    pending--;
                end
                if (accept) begin
                    if (pending == QUEUE_DEPTH) $fatal(1, "cache request timestamp queue overflow");
                    accepted_at[write_index] = cycle_count;
                    write_index = (write_index + 1) % QUEUE_DEPTH;
                    pending++;
                end
            end
            cycle_count++;
        end
    end
endmodule
