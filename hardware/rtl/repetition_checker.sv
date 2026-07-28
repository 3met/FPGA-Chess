// Shared full-key threefold-repetition history and lookup pipeline.
import general_chess_defs::*;

module repetition_checker #(
    parameter int SEARCH_THREAD_COUNT = THREAD_COUNT,
    parameter int SEARCH_STACK_DEPTH = MAX_PLY_COUNT,
    parameter int ACTIVE_HISTORY_DEPTH = 100,
    parameter int STATIC_TABLE_SIZE = 256,
    parameter int EPOCH_BITS = 4
) (
    input logic clk,
    input logic rst_n,
    input logic flush,
    input logic active_history_reset,
    input logic active_history_write,
    input ZobristKey active_history_key,
    input logic init_start,
    output logic init_busy,
    output logic init_done,
    output logic init_failed,
    input logic line_write_valid,
    input ThreadID line_write_thread,
    input PlyIndex line_write_ply,
    input ZobristKey line_write_key,
    input logic req_valid,
    input ThreadID req_thread,
    input PlyIndex req_ply,
    input PlyIndex req_start_ply,
    input logic [EPOCH_BITS-1:0] req_epoch,
    input ZobristKey req_key,
    output logic resp_valid,
    output ThreadID resp_thread,
    output logic [EPOCH_BITS-1:0] resp_epoch,
    output logic [1:0] resp_previous_count,
    output logic resp_is_draw
);
    localparam int LINE_BANK_COUNT = (SEARCH_STACK_DEPTH + 1) / 2;
    localparam int LINE_ADDR_WORDS = 2 * SEARCH_THREAD_COUNT;
    localparam int LINE_ADDR_BITS = (LINE_ADDR_WORDS <= 1) ? 1 : $clog2(LINE_ADDR_WORDS);
    localparam int TABLE_BITS = $clog2(STATIC_TABLE_SIZE);
    localparam int STATIC_ADDR_BITS = TABLE_BITS + 1;
    localparam int STATIC_WORD_COUNT = 2 * STATIC_TABLE_SIZE;
    localparam int HISTORY_COUNT_BITS = $clog2(ACTIVE_HISTORY_DEPTH + 1);
    localparam int HISTORY_ADDR_BITS = (ACTIVE_HISTORY_DEPTH <= 1) ? 1 : $clog2(ACTIVE_HISTORY_DEPTH);

    typedef struct packed {
        logic valid;
        ZobristKey key;
        logic [1:0] count;
    } StaticEntry;
    localparam int STATIC_ENTRY_BITS = $bits(StaticEntry);
    typedef enum logic [2:0] {
        INIT_IDLE, INIT_CLEAR, INIT_HISTORY_READ, INIT_STATIC_READ,
        INIT_STATIC_CHECK, INIT_RETRY, INIT_READY, INIT_FAIL
    } InitState;

    InitState init_state;
    logic [15:0] init_seed;
    logic [STATIC_ADDR_BITS-1:0] clear_index;
    logic [HISTORY_COUNT_BITS-1:0] active_history_count, scan_index;
    logic scan_odd_parity;

    logic active_history_rden, active_history_wren;
    logic [HISTORY_ADDR_BITS-1:0] active_history_rdaddr, active_history_wraddr;
    ZobristKey active_history_q;

    logic static_rden;
    logic [STATIC_ADDR_BITS-1:0] static_rdaddr, static_wraddr;
    logic static_wren;
    logic [STATIC_ENTRY_BITS-1:0] static_write_data, static_q_bits;
    StaticEntry static_q;

    logic [63:0] line_read_data [0:LINE_BANK_COUNT-1];
    logic [LINE_BANK_COUNT-1:0] line_wren;
    logic [LINE_ADDR_BITS-1:0] line_rdaddr, line_wraddr;

    logic valid_pipe [0:1];
    ThreadID thread_pipe [0:1];
    logic [EPOCH_BITS-1:0] epoch_pipe [0:1];
    ZobristKey request_key;
    logic [LINE_BANK_COUNT-1:0] request_mask;
    logic request_suppress_static;
    logic request_is_root;
    logic [1:0] line_count, static_count;

    // Four fixed rotations per byte provide a cheap programmable index fold;
    // full-key comparison remains authoritative.
    function automatic logic [TABLE_BITS-1:0] hash_key(input ZobristKey key, input logic [15:0] seed);
        logic [7:0] rotated [0:7];
        for (int byte_index = 0; byte_index < 8; byte_index++) begin
            automatic logic [7:0] value;
            value = key[byte_index*8 +: 8];
            case (seed[byte_index*2 +: 2])
                2'd0: rotated[byte_index] = value;
                2'd1: rotated[byte_index] = {value[0], value[7:1]};
                2'd2: rotated[byte_index] = {value[1:0], value[7:2]};
                default: rotated[byte_index] = {value[2:0], value[7:3]};
            endcase
        end
        return TABLE_BITS'(rotated[0] ^ rotated[1] ^ rotated[2] ^ rotated[3]
            ^ rotated[4] ^ rotated[5] ^ rotated[6] ^ rotated[7]);
    endfunction

    function automatic logic [1:0] sat_add(input logic [1:0] lhs, input logic [1:0] rhs);
        if (lhs >= 2 || rhs >= 2 || (lhs == 1 && rhs == 1)) return 2;
        return lhs + rhs;
    endfunction

    assign static_q = StaticEntry'(static_q_bits);
    assign scan_odd_parity = ((int'(active_history_count) - 1 - int'(scan_index)) & 1) != 0;
    assign init_busy = init_state == INIT_CLEAR || init_state == INIT_HISTORY_READ
        || init_state == INIT_STATIC_READ || init_state == INIT_STATIC_CHECK || init_state == INIT_RETRY;
    assign init_done = init_state == INIT_READY;
    assign init_failed = init_state == INIT_FAIL;
    assign resp_valid = valid_pipe[1];
    assign resp_thread = thread_pipe[1];
    assign resp_epoch = epoch_pipe[1];
    assign resp_previous_count = sat_add(line_count, static_count);
    assign resp_is_draw = resp_previous_count >= 2;

    always_comb begin
        active_history_rden = init_state == INIT_HISTORY_READ
            && scan_index < active_history_count;
        active_history_rdaddr = HISTORY_ADDR_BITS'(scan_index);
        active_history_wren = active_history_reset || (active_history_write && active_history_count < ACTIVE_HISTORY_DEPTH);
        active_history_wraddr = active_history_reset ? '0 : HISTORY_ADDR_BITS'(active_history_count);

        static_rden = (init_state == INIT_STATIC_READ) || (req_valid && init_done);
        static_rdaddr = (init_state == INIT_STATIC_READ || init_state == INIT_STATIC_CHECK)
            ? {scan_odd_parity, hash_key(active_history_q, init_seed)}
            : {req_ply[0], hash_key(req_key, init_seed)};
        static_wraddr = (init_state == INIT_CLEAR) ? clear_index : static_rdaddr;
        static_wren = init_state == INIT_CLEAR;
        static_write_data = '0;
        if (init_state == INIT_STATIC_CHECK) begin
            automatic StaticEntry entry;
            entry = static_q;
            if (!entry.valid) begin
                entry.valid = 1'b1;
                entry.key = active_history_q;
                entry.count = 2'd1;
                static_wren = 1'b1;
                static_write_data = entry;
            end else if (entry.key == active_history_q && entry.count < 3) begin
                entry.count = entry.count + 1'b1;
                static_wren = 1'b1;
                static_write_data = entry;
            end
        end

        line_rdaddr = LINE_ADDR_BITS'((int'(req_thread) << 1)
            | ((req_ply == 0) ? 0 : ((int'(req_ply) - 1) & 1)));
        line_wraddr = LINE_ADDR_BITS'((int'(line_write_thread) << 1)
            | ((int'(line_write_ply) - 1) & 1));
        line_wren = '0;
        if (line_write_valid && line_write_ply != 0)
            line_wren[(line_write_ply - 1'b1) >> 1] = 1'b1;
    end

    sync_read_simple_dual_port_ram #(.NUM_WORDS(ACTIVE_HISTORY_DEPTH), .WORD_SIZE(64)) active_history_ram (
        .clock(clk), .data(active_history_key), .rdaddress(active_history_rdaddr), .rden(active_history_rden),
        .wraddress(active_history_wraddr), .wren(active_history_wren), .q(active_history_q)
    );
    sync_read_simple_dual_port_ram #(.NUM_WORDS(STATIC_WORD_COUNT), .WORD_SIZE(STATIC_ENTRY_BITS)) static_history_ram (
        .clock(clk), .data(static_write_data), .rdaddress(static_rdaddr), .rden(static_rden),
        .wraddress(static_wraddr), .wren(static_wren), .q(static_q_bits)
    );

    genvar bank_gen;
    generate
        for (bank_gen = 0; bank_gen < LINE_BANK_COUNT; bank_gen = bank_gen + 1) begin : gen_line_bank
            sync_read_simple_dual_port_ram #(.NUM_WORDS(LINE_ADDR_WORDS), .WORD_SIZE(64)) line_ram (
                .clock(clk), .data(line_write_key), .rdaddress(line_rdaddr), .rden(req_valid),
                .wraddress(line_wraddr), .wren(line_wren[bank_gen]), .q(line_read_data[bank_gen])
            );
        end
    endgenerate

    always_ff @(posedge clk) begin
        if (!rst_n) begin
            active_history_count <= '0;
            init_state <= INIT_IDLE;
            init_seed <= 16'h1;
            clear_index <= '0;
            scan_index <= '0;
            for (int stage = 0; stage < 2; stage++) begin
                valid_pipe[stage] <= 1'b0;
            end
            line_count <= 2'd0;
            static_count <= 2'd0;
        end else begin
            if (active_history_reset) active_history_count <= 1;
            else if (active_history_write && active_history_count < ACTIVE_HISTORY_DEPTH)
                active_history_count <= active_history_count + 1'b1;

            case (init_state)
                INIT_IDLE: if (init_start) begin
                    clear_index <= '0;
                    init_seed <= 16'h1;
                    init_state <= INIT_CLEAR;
                end
                INIT_CLEAR: begin
                    if (clear_index == STATIC_WORD_COUNT-1) begin
                        scan_index <= '0;
                        init_state <= INIT_HISTORY_READ;
                    end else clear_index <= clear_index + 1'b1;
                end
                INIT_HISTORY_READ:
                    if (scan_index == active_history_count) init_state <= INIT_READY;
                    else init_state <= INIT_STATIC_READ;
                INIT_STATIC_READ: begin
                    init_state <= INIT_STATIC_CHECK;
                end
                INIT_STATIC_CHECK: begin
                    automatic StaticEntry entry;
                    entry = static_q;
                    if (!entry.valid || entry.key == active_history_q) begin
                        scan_index <= scan_index + 1'b1;
                        init_state <= INIT_HISTORY_READ;
                    end else init_state <= INIT_RETRY;
                end
                INIT_RETRY: begin
                    if (init_seed == 16'hffff) init_state <= INIT_FAIL;
                    else begin
                        init_seed <= init_seed + 1'b1;
                        clear_index <= '0;
                        init_state <= INIT_CLEAR;
                    end
                end
                INIT_READY: if (init_start) begin
                    clear_index <= '0;
                    init_seed <= 16'h1;
                    init_state <= INIT_CLEAR;
                end
                default: init_state <= INIT_FAIL;
            endcase
            if (active_history_reset || active_history_write) init_state <= INIT_IDLE;

            valid_pipe[0] <= req_valid && init_done;
            thread_pipe[0] <= req_thread;
            epoch_pipe[0] <= req_epoch;
            request_key <= req_key;
            request_suppress_static <= req_start_ply != 0;
            request_is_root <= req_ply == 0;
            request_mask <= '0;
            if (req_valid && req_ply != 0) begin
                automatic int current_bank = (int'(req_ply) - 1) >> 1;
                automatic int first_ply = int'(req_start_ply);
                if (first_ply < 1) first_ply = 1;
                if ((first_ply & 1) != (int'(req_ply) & 1)) first_ply++;
                for (int bank = 0; bank < LINE_BANK_COUNT; bank++)
                    request_mask[bank] <= bank >= ((first_ply - 1) >> 1) && bank < current_bank;
            end

            valid_pipe[1] <= valid_pipe[0];
            thread_pipe[1] <= thread_pipe[0];
            epoch_pipe[1] <= epoch_pipe[0];
            begin
                automatic logic [1:0] reduced_count = 2'd0;
                for (int bank = 0; bank < LINE_BANK_COUNT; bank++)
                    if (request_mask[bank] && line_read_data[bank] == request_key)
                        reduced_count = sat_add(reduced_count, 2'd1);
                line_count <= reduced_count;
            end
            begin
                automatic StaticEntry lookup;
                lookup = static_q;
                static_count <= 2'd0;
                if (valid_pipe[0] && !request_suppress_static
                        && lookup.valid && lookup.key == request_key) begin
                    // The table includes the root. A root request excludes its
                    // current occurrence; descendants retain it as history.
                    static_count <= request_is_root ? lookup.count - 1'b1 : lookup.count;
                end
            end
            if (flush) for (int stage = 0; stage < 2; stage++) valid_pipe[stage] <= 1'b0;

`ifndef SYNTHESIS
            if (req_valid) begin
                assert (int'(req_thread) < SEARCH_THREAD_COUNT);
                assert (int'(req_ply) < SEARCH_STACK_DEPTH);
            end
            assert ($onehot0(line_wren));
            if (init_state == INIT_READY) assert (!init_failed);
`endif
        end
    end
endmodule
