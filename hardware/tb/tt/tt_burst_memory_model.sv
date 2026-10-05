// Portable simulation backend for the same external-memory burst protocol as SDRAM.
import tt_defs::*;
module tt_burst_memory_model #(
    parameter int WORD_COUNT = 1024,
    parameter int READ_DELAY = 2
) (
    input logic clk, rst_n,
    input logic req_valid,
    output logic req_ready,
    input logic req_write,
    input TTWordAddress req_address,
    input TTBurstLength req_length,
    input logic write_valid,
    output logic write_ready,
    input logic [TT_WORD_BITS-1:0] write_data,
    input logic write_last,
    output logic read_valid,
    input logic read_ready,
    output logic [TT_WORD_BITS-1:0] read_data,
    output logic read_last,
    output logic done_valid,
    input logic done_ready,
    output logic done_error,
    // Directed transport faults: rejected read, truncated read, completed read error.
    input logic [1:0] read_fault = 2'd0
);
    logic [TT_WORD_BITS-1:0] memory[0:WORD_COUNT-1];
    TTWordAddress address;
    TTBurstLength remaining;
    logic busy, writing;
    int delay_count;
    int read_count, write_count;
    assign req_ready = !busy && !done_valid;
    assign write_ready = busy && writing;
    assign read_valid = busy && !writing && delay_count == 0;
    assign read_data = memory[address];
    assign read_last = remaining == 1;
    initial for (int i = 0; i < WORD_COUNT; i++) memory[i] = '0;
    // Hold every response until accepted, including terminal completion.
    always_ff @(posedge clk) begin
        if (!rst_n) begin
            busy <= 0; done_valid <= 0; read_count <= 0; write_count <= 0;
            delay_count <= 0; writing <= 0; address <= '0; remaining <= '0;
            done_error <= 0;
        end else begin
            if (done_valid && done_ready) done_valid <= 0;
            if (req_valid && req_ready) begin
                if (int'(req_address) + int'(req_length) > WORD_COUNT || req_length == 0)
                    $fatal(1, "TT memory model request exceeds capacity");
                busy <= 1; writing <= req_write; address <= req_address; remaining <= req_length;
                done_error <= !req_write && (read_fault == 1 || read_fault == 3);
                if (!req_write && read_fault == 1) begin busy <= 0; done_valid <= 1; end
                if (!req_write && read_fault == 2) remaining <= req_length / 2;
                delay_count <= READ_DELAY;
                if (req_write) write_count <= write_count+1; else read_count <= read_count+1;
            end
            if (busy && !writing && delay_count > 0) delay_count <= delay_count-1;
            if ((read_valid && read_ready) || (write_valid && write_ready)) begin
                if (writing) memory[address] <= write_data;
                address <= address+1'b1; remaining <= remaining-1'b1;
                if (remaining == 1) begin busy <= 0; done_valid <= 1; end
            end
        end
    end
endmodule
