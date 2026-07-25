// Sparse behavioral model of the DE1-SoC 32M x 16 SDR SDRAM.
//
// The production controller remains responsible for JEDEC timing, banking,
// refresh, and burst termination. This model supplies persistent storage and
// the pin-level command/data behavior needed by engine profiling.

module sdram_chip_model #(
    parameter int CAS_LATENCY = 2,
    parameter int TRCD_CYCLES = 2,
    parameter int TRP_CYCLES = 2,
    parameter int TRAS_CYCLES = 5,
    parameter int TRC_CYCLES = 8,
    parameter int TDPL_CYCLES = 2,
    parameter int REFRESH_MAX_CYCLES = 781
) (
    input logic clk,
    input logic [12:0] addr,
    input logic [1:0] ba,
    input logic cas_n,
    input logic cke,
    input logic cs_n,
    inout wire [15:0] dq,
    input logic ldqm,
    input logic ras_n,
    input logic udqm,
    input logic we_n
);
    typedef logic [24:0] WordAddress;
    logic [12:0] open_row[0:3];
    logic open_valid[0:3];
    logic read_active;
    logic [9:0] read_col;
    logic [1:0] read_bank;
    logic [3:0] read_delay;
    logic write_active;
    logic [9:0] write_col;
    logic [1:0] write_bank;
    logic [15:0] dq_out;
    logic dq_oe;
    logic [15:0] memory[WordAddress];
    longint unsigned cycle_count;
    longint signed cke_start_cycle;
    longint signed last_activate[0:3];
    longint signed last_precharge[0:3];
    longint signed last_write[0:3];
    longint signed last_refresh;
    int initialization_refreshes;
    logic precharged_all;
    logic mode_loaded;

    assign dq = dq_oe ? dq_out : 16'hzzzz;

    function automatic WordAddress word_address(
        input logic [1:0] bank,
        input logic [12:0] row,
        input logic [9:0] col
    );
        return WordAddress'({bank, row, col});
    endfunction

    function automatic logic [15:0] read_word(input WordAddress word);
        if (memory.exists(word)) return memory[word];
        return 16'h0000;
    endfunction

    initial begin
        read_active = 1'b0;
        write_active = 1'b0;
        read_delay = '0;
        dq_out = '0;
        dq_oe = 1'b0;
        cycle_count = 0;
        cke_start_cycle = -1;
        last_refresh = -1;
        initialization_refreshes = 0;
        precharged_all = 1'b0;
        mode_loaded = 1'b0;
        for (int bank = 0; bank < 4; bank++) begin
            open_row[bank] = '0;
            open_valid[bank] = 1'b0;
            last_activate[bank] = -100_000;
            last_precharge[bank] = -100_000;
            last_write[bank] = -100_000;
        end
    end

    always @(posedge clk) begin
        cycle_count <= cycle_count + 1;
        if (cke && cke_start_cycle < 0) cke_start_cycle <= longint'(cycle_count);
        if (mode_loaded && last_refresh >= 0
                && longint'(cycle_count) - last_refresh > REFRESH_MAX_CYCLES)
            $fatal(1, "SDRAM refresh deadline exceeded");
        dq_oe <= 1'b0;
        if (cke && !cs_n) begin
            // ACTIVE
            if (!ras_n && cas_n && we_n) begin
                if (!mode_loaded)
                    $fatal(1, "SDRAM ACTIVE issued before initialization completed");
                if (open_valid[ba])
                    $fatal(1, "SDRAM ACTIVE issued to an already-open bank");
                if (longint'(cycle_count) - last_precharge[ba] < TRP_CYCLES)
                    $fatal(1, "SDRAM tRP violation");
                if (longint'(cycle_count) - last_activate[ba] < TRC_CYCLES)
                    $fatal(1, "SDRAM tRC violation");
                open_row[ba] <= addr;
                open_valid[ba] <= 1'b1;
                last_activate[ba] <= longint'(cycle_count);
            // PRECHARGE
            end else if (!ras_n && cas_n && !we_n) begin
                if (cke_start_cycle >= 0 && !precharged_all
                        && longint'(cycle_count) - cke_start_cycle < 10_000)
                    $fatal(1, "SDRAM power-up delay shorter than 100 us");
                if (addr[10]) begin
                    for (int bank = 0; bank < 4; bank++) begin
                        if (open_valid[bank]
                                && longint'(cycle_count) - last_activate[bank] < TRAS_CYCLES)
                            $fatal(1, "SDRAM tRAS violation before all-bank precharge");
                        if (longint'(cycle_count) - last_write[bank] < TDPL_CYCLES)
                            $fatal(1, "SDRAM tDPL violation before all-bank precharge");
                        open_valid[bank] <= 1'b0;
                        last_precharge[bank] <= longint'(cycle_count);
                    end
                    precharged_all <= 1'b1;
                end else begin
                    if (open_valid[ba]
                            && longint'(cycle_count) - last_activate[ba] < TRAS_CYCLES)
                        $fatal(1, "SDRAM tRAS violation");
                    if (longint'(cycle_count) - last_write[ba] < TDPL_CYCLES)
                        $fatal(1, "SDRAM tDPL violation");
                    open_valid[ba] <= 1'b0;
                    last_precharge[ba] <= longint'(cycle_count);
                end
            // AUTO REFRESH invalidates the model's open-row bookkeeping.
            end else if (!ras_n && !cas_n && we_n) begin
                for (int bank = 0; bank < 4; bank++)
                    if (open_valid[bank])
                        $fatal(1, "SDRAM AUTO REFRESH issued with an open bank");
                if (last_refresh >= 0
                        && longint'(cycle_count) - last_refresh < TRC_CYCLES)
                    $fatal(1, "SDRAM tRC violation between refresh commands");
                if (!mode_loaded) initialization_refreshes <= initialization_refreshes + 1;
                last_refresh <= longint'(cycle_count);
                for (int bank = 0; bank < 4; bank++) open_valid[bank] <= 1'b0;
            // LOAD MODE REGISTER
            end else if (!ras_n && !cas_n && !we_n) begin
                if (!precharged_all || initialization_refreshes < 2)
                    $fatal(1, "SDRAM mode register loaded before initialization refreshes");
                if (ba != 0 || addr[12:10] != 0 || addr[9] != 0
                        || addr[8:7] != 0 || addr[6:4] != 3'(CAS_LATENCY)
                        || addr[3] != 0 || addr[2:0] != 3'b111)
                    $fatal(1, "SDRAM mode register does not select full-page sequential CAS-2 bursts");
                mode_loaded <= 1'b1;
            // READ
            end else if (ras_n && !cas_n && we_n && open_valid[ba]) begin
                if (!mode_loaded) $fatal(1, "SDRAM READ before mode register load");
                if (longint'(cycle_count) - last_activate[ba] < TRCD_CYCLES)
                    $fatal(1, "SDRAM tRCD violation on READ");
                read_active <= 1'b1;
                read_bank <= ba;
                read_col <= addr[9:0];
                // CAS latency counts from the READ command edge to the first
                // data edge; this process observes the command as edge zero.
                read_delay <= 4'(CAS_LATENCY - 1);
            // WRITE. The controller presents one consecutive word each cycle.
            end else if (ras_n && !cas_n && !we_n && open_valid[ba]) begin
                automatic WordAddress write_address = word_address(ba, open_row[ba], addr[9:0]);
                automatic logic [15:0] old_word = read_word(write_address);
                if (!mode_loaded) $fatal(1, "SDRAM WRITE before mode register load");
                if (longint'(cycle_count) - last_activate[ba] < TRCD_CYCLES)
                    $fatal(1, "SDRAM tRCD violation on WRITE");
                memory[write_address] = {
                    udqm ? old_word[15:8] : dq[15:8],
                    ldqm ? old_word[7:0] : dq[7:0]
                };
                write_active <= 1'b1;
                write_bank <= ba;
                write_col <= addr[9:0] + 1'b1;
                last_write[ba] <= longint'(cycle_count);
            // BURST TERMINATE
            end else if (ras_n && cas_n && !we_n) begin
                read_active <= 1'b0;
                write_active <= 1'b0;
            end
        end

        if (read_active) begin
            if (read_delay != 0) begin
                read_delay <= read_delay - 1'b1;
            end else begin
                dq_out <= read_word(word_address(read_bank, open_row[read_bank], read_col));
                dq_oe <= 1'b1;
                read_col <= read_col + 1'b1;
            end
        end

        // WRITE data after the first command word continues without CAS.
        if (write_active && cke && !cs_n && ras_n && cas_n && we_n) begin
            automatic WordAddress write_address =
                word_address(write_bank, open_row[write_bank], write_col);
            automatic logic [15:0] old_word = read_word(write_address);
            memory[write_address] = {
                udqm ? old_word[15:8] : dq[15:8],
                ldqm ? old_word[7:0] : dq[7:0]
            };
            write_col <= write_col + 1'b1;
            last_write[write_bank] <= longint'(cycle_count);
        end
    end
endmodule
