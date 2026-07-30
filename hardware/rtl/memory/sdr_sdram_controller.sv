// Vendor-neutral 16-bit JEDEC SDR SDRAM controller for random TT bursts.

import tt_defs::*;

module sdr_sdram_controller #(
    parameter int CLOCK_FREQ = 100_000_000,
    parameter int ENTRY_COUNT = TT_EXTERNAL_ENTRY_COUNT,
    parameter int CAS_LATENCY = 2,
    // Simulation profiles may skip the serial validity-word sweep when the
    // attached memory model is guaranteed to start cleared.
    parameter bit SKIP_INITIAL_CLEAR = 1'b0
) (
    input logic clk, input logic read_capture_clk, input logic rst_n,
    output logic ready, output logic error,
    input logic req_valid, output logic req_ready, input logic req_write,
    input TTWordAddress req_address, input logic [3:0] req_length,
    input logic write_valid, output logic write_ready, input logic [15:0] write_data, input logic write_last,
    output logic read_valid, input logic read_ready, output logic [15:0] read_data, output logic read_last,
    output logic done_valid, input logic done_ready, output logic done_error,
    output logic [12:0] dram_addr, output logic [1:0] dram_ba,
    output logic dram_cas_n, output logic dram_cke, output logic dram_cs_n,
    inout wire [15:0] dram_dq, output logic dram_ldqm, output logic dram_ras_n,
    output logic dram_udqm, output logic dram_we_n
);
    function automatic int cycles_ns(input int ns);
        longint clocks;
        clocks = (longint'(CLOCK_FREQ) * ns + 999_999_999) / 1_000_000_000;
        return clocks < 1 ? 1 : int'(clocks);
    endfunction
    localparam int POWERUP_CYCLES = cycles_ns(200_000);
    localparam int TRP = cycles_ns(20), TRCD = cycles_ns(20), TRFC = cycles_ns(70), TMRD = 2;
    // Start refresh service early enough that precharge/command latency still
    // keeps successive AUTO REFRESH commands within the 7.8125 us requirement.
    localparam int REFRESH_CYCLES = cycles_ns(7_200);
    localparam int WAIT_COUNT_BITS = $clog2(POWERUP_CYCLES + 1);
    localparam int REFRESH_COUNT_BITS = $clog2(REFRESH_CYCLES + 1);

    typedef enum logic [5:0] {
        S_POWERUP, S_INIT_PRE, S_INIT_PRE_WAIT, S_INIT_REF1, S_INIT_REF1_WAIT,
        S_INIT_REF2, S_INIT_REF2_WAIT, S_INIT_MODE, S_INIT_MODE_WAIT,
        S_CLEAR_CHECK, S_CLEAR_PRE, S_CLEAR_PRE_WAIT, S_CLEAR_ACT, S_CLEAR_ACT_WAIT,
        S_CLEAR_WRITE, S_CLEAR_TERM,
        S_IDLE, S_PRE, S_PRE_WAIT, S_ACT, S_ACT_WAIT, S_READ_CMD, S_READ_WAIT,
        S_READ_DATA, S_READ_SERVE, S_WRITE_COLLECT, S_WRITE_CMD, S_WRITE_DATA,
        S_BURST_TERM, S_COMPLETE,
        S_REFRESH_PRE, S_REFRESH_PRE_WAIT, S_REFRESH, S_REFRESH_WAIT
    } State;
    State state;
    // Power-up dominates the wait-counter range; right-sized counters avoid
    // carrying two general 32-bit decrementers in the memory controller.
    logic [WAIT_COUNT_BITS-1:0] wait_count;
    logic [REFRESH_COUNT_BITS-1:0] refresh_count;
    logic [24:0] clear_word;
    logic [24:0] address;
    logic [3:0] remaining, segment_remaining;
    logic transaction_write;
    logic [15:0] write_buffer[0:5];
    logic [2:0] write_collect_count, write_emit_count;
    logic [15:0] read_buffer[0:5];
    logic [2:0] read_capture_count, read_emit_count;
    logic [3:0] transaction_length;
    logic [12:0] open_row[0:3];
    logic open_valid[0:3];
    logic [15:0] dq_out;
    logic dq_oe;
    logic [12:0] dram_addr_next;
    logic [1:0] dram_ba_next;
    logic dram_cas_n_next, dram_cke_next, dram_cs_n_next;
    logic dram_ldqm_next, dram_ras_n_next, dram_udqm_next, dram_we_n_next;
    logic [15:0] dq_out_next;
    logic dq_oe_next;
    logic [15:0] dq_read_capture;
    wire [15:0] dq_in = dram_dq;
    assign dram_dq = dq_oe ? dq_out : 16'hzzzz;

    function automatic logic [1:0] bank_of(input logic [24:0] word); return word[24:23]; endfunction
    function automatic logic [12:0] row_of(input logic [24:0] word); return word[22:10]; endfunction
    function automatic logic [9:0] col_of(input logic [24:0] word); return word[9:0]; endfunction
    function automatic logic [3:0] segment_len(input logic [24:0] word, input logic [3:0] count);
        logic [10:0] room;
        room = 11'd1024 - {1'b0, col_of(word)};
        return (room < {7'd0, count}) ? room[3:0] : count;
    endfunction

    always_comb begin
        dram_addr_next = '0; dram_ba_next = bank_of(address);
        dram_cs_n_next = 1'b0; dram_cke_next = 1'b1; dram_ras_n_next = 1'b1;
        dram_cas_n_next = 1'b1; dram_we_n_next = 1'b1;
        dram_ldqm_next = 1'b0; dram_udqm_next = 1'b0; dq_out_next = '0; dq_oe_next = 1'b0;
        req_ready = ready && state == S_IDLE && !((refresh_count == 0));
        write_ready = 1'b0; read_valid = 1'b0;
        read_data = read_buffer[read_emit_count];
        read_last = read_emit_count == 3'(transaction_length - 1'b1);
        done_valid = state == S_COMPLETE; done_error = error;

        case (state)
            S_INIT_PRE, S_REFRESH_PRE: begin dram_ras_n_next = 1'b0; dram_we_n_next = 1'b0; dram_addr_next[10] = 1'b1; end
            S_CLEAR_PRE, S_PRE: begin dram_ras_n_next = 1'b0; dram_we_n_next = 1'b0; dram_addr_next[10] = 1'b0; end
            S_INIT_REF1, S_INIT_REF2, S_REFRESH: begin dram_ras_n_next = 1'b0; dram_cas_n_next = 1'b0; end
            S_INIT_MODE: begin
                dram_ras_n_next = 1'b0; dram_cas_n_next = 1'b0; dram_we_n_next = 1'b0;
                dram_ba_next = 2'b00; dram_addr_next = 13'b000_0_00_010_0_111; // BL=full page, sequential, CAS=2.
            end
            S_CLEAR_ACT, S_ACT: begin dram_ras_n_next = 1'b0; dram_addr_next = row_of(address); end
            S_CLEAR_WRITE: begin
                dram_cas_n_next = 1'b0; dram_we_n_next = 1'b0; dram_addr_next[9:0] = col_of(address);
                dram_addr_next[10] = 1'b0; dq_out_next = 16'h0000; dq_oe_next = 1'b1;
            end
            S_READ_CMD: begin dram_cas_n_next = 1'b0; dram_addr_next[9:0] = col_of(address); dram_addr_next[10] = 1'b0; end
            S_READ_SERVE: begin read_valid = 1'b1; end
            S_WRITE_COLLECT: write_ready = 1'b1;
            S_WRITE_CMD, S_WRITE_DATA: begin
                if (state == S_WRITE_CMD) begin
                    dram_cas_n_next = 1'b0; dram_we_n_next = 1'b0; dram_addr_next[9:0] = col_of(address);
                end
                // Once WRITE is issued SDR SDRAM consumes one beat per clock;
                // the complete burst was staged before reaching this state.
                dq_oe_next = 1'b1;
                dq_out_next = write_buffer[write_emit_count];
            end
            S_CLEAR_TERM, S_BURST_TERM: begin dram_we_n_next = 1'b0; end
            default: begin end
        endcase
    end

    task automatic invalidate_rows();
        for (int b = 0; b < 4; b++) open_valid[b] <= 1'b0;
    endtask

    always_ff @(posedge clk) begin
        if (!rst_n) begin
            state <= S_POWERUP; ready <= 1'b0; error <= 1'b0;
            wait_count <= WAIT_COUNT_BITS'(POWERUP_CYCLES); refresh_count <= REFRESH_COUNT_BITS'(REFRESH_CYCLES);
            clear_word <= 25'd5; address <= '0; remaining <= '0; segment_remaining <= '0;
            write_collect_count <= '0; write_emit_count <= '0;
            read_capture_count <= '0; read_emit_count <= '0; transaction_length <= '0;
            invalidate_rows();
            dram_addr <= '0; dram_ba <= '0; dram_cas_n <= 1'b1; dram_cke <= 1'b0;
            dram_cs_n <= 1'b1; dram_ldqm <= 1'b0; dram_ras_n <= 1'b1;
            dram_udqm <= 1'b0; dram_we_n <= 1'b1; dq_out <= '0; dq_oe <= 1'b0;
        end else begin
            // Register the SDRAM pins so commands and write data meet the
            // phase-shifted output clock without long state-decoder paths.
            dram_addr <= dram_addr_next; dram_ba <= dram_ba_next;
            dram_cas_n <= dram_cas_n_next; dram_cke <= dram_cke_next; dram_cs_n <= dram_cs_n_next;
            dram_ldqm <= dram_ldqm_next; dram_ras_n <= dram_ras_n_next;
            dram_udqm <= dram_udqm_next; dram_we_n <= dram_we_n_next;
            dq_out <= dq_out_next; dq_oe <= dq_oe_next;
            if ((ready || state >= S_CLEAR_CHECK) && refresh_count != 0) refresh_count <= refresh_count - 1'b1;
            case (state)
                S_POWERUP: if (wait_count == 0) state <= S_INIT_PRE; else wait_count <= wait_count - 1'b1;
                S_INIT_PRE: begin invalidate_rows(); wait_count <= WAIT_COUNT_BITS'(TRP - 1); state <= S_INIT_PRE_WAIT; end
                S_INIT_PRE_WAIT: if (wait_count == 0) state <= S_INIT_REF1; else wait_count <= wait_count - 1'b1;
                S_INIT_REF1: begin wait_count <= WAIT_COUNT_BITS'(TRFC - 1); state <= S_INIT_REF1_WAIT; end
                S_INIT_REF1_WAIT: if (wait_count == 0) state <= S_INIT_REF2; else wait_count <= wait_count - 1'b1;
                S_INIT_REF2: begin wait_count <= WAIT_COUNT_BITS'(TRFC - 1); state <= S_INIT_REF2_WAIT; end
                S_INIT_REF2_WAIT: if (wait_count == 0) state <= S_INIT_MODE; else wait_count <= wait_count - 1'b1;
                S_INIT_MODE: begin wait_count <= WAIT_COUNT_BITS'(TMRD - 1); state <= S_INIT_MODE_WAIT; end
                S_INIT_MODE_WAIT: if (wait_count == 0) begin
                    address <= clear_word;
                    refresh_count <= REFRESH_COUNT_BITS'(REFRESH_CYCLES);
                    if (SKIP_INITIAL_CLEAR) begin
                        ready <= 1'b1;
                        state <= S_IDLE;
                    end else begin
                        state <= S_CLEAR_CHECK;
                    end
                end else wait_count <= wait_count - 1'b1;
                S_CLEAR_CHECK: begin
                    address <= clear_word;
                    if (open_valid[bank_of(clear_word)] && open_row[bank_of(clear_word)] == row_of(clear_word)) state <= S_CLEAR_WRITE;
                    else if (open_valid[bank_of(clear_word)]) state <= S_CLEAR_PRE;
                    else state <= S_CLEAR_ACT;
                end
                S_CLEAR_PRE: begin open_valid[address[24:23]] <= 1'b0; wait_count <= WAIT_COUNT_BITS'(TRP - 1); state <= S_CLEAR_PRE_WAIT; end
                S_CLEAR_PRE_WAIT: if (wait_count == 0) state <= S_CLEAR_ACT; else wait_count <= wait_count - 1'b1;
                S_CLEAR_ACT: begin open_valid[address[24:23]] <= 1'b1; open_row[address[24:23]] <= row_of(address); wait_count <= WAIT_COUNT_BITS'(TRCD - 1); state <= S_CLEAR_ACT_WAIT; end
                S_CLEAR_ACT_WAIT: if (wait_count == 0) state <= S_CLEAR_WRITE; else wait_count <= wait_count - 1'b1;
                S_CLEAR_WRITE: state <= S_CLEAR_TERM;
                S_CLEAR_TERM: begin
                    if (clear_word >= 25'((ENTRY_COUNT-1)*6+5)) begin ready <= 1'b1; refresh_count <= REFRESH_COUNT_BITS'(REFRESH_CYCLES); state <= S_IDLE; end
                    else begin
                        clear_word <= clear_word + 25'd6;
                        state <= (refresh_count == 0) ? S_REFRESH_PRE : S_CLEAR_CHECK;
                    end
                end
                S_IDLE: begin
                    if (refresh_count == 0) state <= S_REFRESH_PRE;
                    else if (req_valid && req_ready) begin
                        address <= req_address; remaining <= req_length;
                        transaction_length <= req_length; transaction_write <= req_write;
                        if (req_length == 0 || req_length > 6) begin
                            error <= 1'b1;
                            state <= S_COMPLETE;
                        end else if (req_write) begin
                            segment_remaining <= segment_len(req_address, req_length);
                            write_collect_count <= '0;
                            state <= S_WRITE_COLLECT;
                        end else begin
                            segment_remaining <= segment_len(req_address, req_length);
                            read_capture_count <= '0;
                            if (open_valid[bank_of(req_address)]
                                    && open_row[bank_of(req_address)] == row_of(req_address))
                                state <= S_READ_CMD;
                            else if (open_valid[bank_of(req_address)]) state <= S_PRE;
                            else state <= S_ACT;
                        end
                    end
                end
                S_WRITE_COLLECT: if (write_valid && write_ready) begin
                    write_buffer[write_collect_count] <= write_data;
                    if (write_last != (write_collect_count == 3'(remaining - 1'b1)))
                        error <= 1'b1;
                    if (write_collect_count == 3'(remaining - 1'b1)) begin
                        write_emit_count <= '0;
                        if (open_valid[bank_of(address)] && open_row[bank_of(address)] == row_of(address))
                            state <= S_WRITE_CMD;
                        else if (open_valid[bank_of(address)]) state <= S_PRE;
                        else state <= S_ACT;
                    end else write_collect_count <= write_collect_count + 3'd1;
                end
                S_PRE: begin open_valid[address[24:23]] <= 1'b0; wait_count <= WAIT_COUNT_BITS'(TRP - 1); state <= S_PRE_WAIT; end
                S_PRE_WAIT: if (wait_count == 0) state <= S_ACT; else wait_count <= wait_count - 1'b1;
                S_ACT: begin open_valid[address[24:23]] <= 1'b1; open_row[address[24:23]] <= row_of(address); wait_count <= WAIT_COUNT_BITS'(TRCD - 1); state <= S_ACT_WAIT; end
                S_ACT_WAIT: if (wait_count == 0) state <= transaction_write ? S_WRITE_CMD : S_READ_CMD; else wait_count <= wait_count - 1'b1;
                S_READ_CMD: begin wait_count <= WAIT_COUNT_BITS'(CAS_LATENCY); state <= S_READ_WAIT; end
                S_READ_WAIT: if (wait_count == 0) state <= S_READ_DATA; else wait_count <= wait_count - 1'b1;
                S_READ_DATA: begin
                    read_buffer[read_capture_count] <= dq_read_capture;
                    read_capture_count <= read_capture_count + 3'd1;
                    address <= address + 25'd1; remaining <= remaining - 1'b1; segment_remaining <= segment_remaining - 1'b1;
                    if (remaining == 1) state <= S_BURST_TERM;
                    else if (segment_remaining == 1) state <= S_BURST_TERM;
                end
                S_READ_SERVE: if (read_valid && read_ready) begin
                    if (read_last) state <= S_COMPLETE;
                    else read_emit_count <= read_emit_count + 3'd1;
                end
                S_WRITE_CMD, S_WRITE_DATA: begin
                    address <= address + 25'd1; remaining <= remaining - 1'b1; segment_remaining <= segment_remaining - 1'b1;
                    write_emit_count <= write_emit_count + 3'd1;
                    if (remaining == 1 || segment_remaining == 1) state <= S_BURST_TERM;
                    else state <= S_WRITE_DATA;
                end
                S_BURST_TERM: begin
                    if (remaining == 0) begin
                        if (transaction_write) begin
                            state <= S_COMPLETE;
                        end else begin
                            read_emit_count <= '0;
                            state <= S_READ_SERVE;
                        end
                    end
                    else begin
                        segment_remaining <= segment_len(address, remaining);
                        if (open_valid[bank_of(address)] && open_row[bank_of(address)] == row_of(address))
                            state <= transaction_write ? S_WRITE_CMD : S_READ_CMD;
                        else if (open_valid[bank_of(address)]) state <= S_PRE;
                        else state <= S_ACT;
                    end
                end
                S_COMPLETE: if (done_valid && done_ready) state <= S_IDLE;
                S_REFRESH_PRE: begin invalidate_rows(); wait_count <= WAIT_COUNT_BITS'(TRP - 1); state <= S_REFRESH_PRE_WAIT; end
                S_REFRESH_PRE_WAIT: if (wait_count == 0) state <= S_REFRESH; else wait_count <= wait_count - 1'b1;
                S_REFRESH: begin wait_count <= WAIT_COUNT_BITS'(TRFC - 1); state <= S_REFRESH_WAIT; end
                S_REFRESH_WAIT: if (wait_count == 0) begin
                    refresh_count <= REFRESH_COUNT_BITS'(REFRESH_CYCLES);
                    state <= ready ? S_IDLE : S_CLEAR_CHECK;
                end else wait_count <= wait_count - 1'b1;
                default: state <= S_POWERUP;
            endcase
        end
    end

    // Capture near the middle of the SDRAM read-data window. The controller
    // consumes this sample on its next 100 MHz edge.
    always_ff @(posedge read_capture_clk) begin
        dq_read_capture <= dq_in;
    end
endmodule
