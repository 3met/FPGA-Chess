// Five-FIFO TT transport and memory-domain scheduler. Cache policy stays upstream.
import tt_defs::*;

module tt_memory_cdc_bridge #(
    parameter int WAY_BITS = TT_PHYSICAL_ENTRY_BITS,
    parameter int ENTRY_COUNT = TT_EXTERNAL_ENTRY_COUNT,
    parameter int ENTRY_INDEX_BITS = $clog2(ENTRY_COUNT+1),
    parameter int READ_FIFO_DEPTH = 8,
    parameter int WRITE_FIFO_DEPTH = 8,
    parameter int RESPONSE_FIFO_DEPTH = 64
) (
    input logic req_clk, req_rst_n, mem_clk, mem_rst_n,
    input logic clear_toggle,
    output logic clear_ack,
    output logic idle,
    input logic probe_valid,
    output logic probe_ready,
    input logic [ENTRY_INDEX_BITS-1:0] probe_entry_index,
    output logic probe_response_valid,
    input logic probe_response_ready,
    output logic [TT_WORD_BITS-1:0] probe_response_data,
    input logic store_valid,
    output logic store_ready,
    input logic [ENTRY_INDEX_BITS-1:0] store_entry_index,
    output logic store_response_valid,
    input logic store_response_ready,
    output logic [TT_WORD_BITS-1:0] store_response_data,
    input logic write_valid,
    output logic write_ready,
    input logic [ENTRY_INDEX_BITS-1:0] write_entry_index,
    input logic [$clog2(TT_WAYS)-1:0] write_way_index,
    input logic [WAY_BITS-1:0] write_way,
    output logic backend_req_valid,
    input logic backend_req_ready,
    output logic backend_req_write,
    output TTWordAddress backend_req_address,
    output TTBurstLength backend_req_length,
    output logic backend_write_valid,
    input logic backend_write_ready,
    output logic [TT_WORD_BITS-1:0] backend_write_data,
    output logic backend_write_last,
    input logic backend_read_valid,
    output logic backend_read_ready,
    input logic [TT_WORD_BITS-1:0] backend_read_data,
    input logic backend_read_last,
    input logic backend_done_valid,
    output logic backend_done_ready,
    input logic backend_done_error
);
    localparam int WAY_WORDS = WAY_BITS / TT_WORD_BITS;
    localparam int ENTRY_WORDS = TT_WAYS * WAY_WORDS;
    localparam int COUNT_BITS = $clog2(ENTRY_WORDS + 1);
    localparam int WAY_INDEX_BITS = $clog2(TT_WAYS);
    typedef logic [ENTRY_INDEX_BITS-1:0] EntryIndex;
    typedef logic [WAY_INDEX_BITS-1:0] WayIndex;
    typedef struct packed { EntryIndex entry_index; WayIndex way_index; logic [WAY_BITS-1:0] data; } WayWrite;
    typedef enum logic [3:0] {
        S_IDLE, S_READ, S_READ_DONE, S_READ_PAD, S_WRITE, S_WRITE_DONE,
        S_CLEAR_REQ, S_CLEAR_DATA, S_CLEAR_DONE, S_REQUEST
    } State;
    State state;
    logic probe_full, probe_empty, probe_pop;
    logic store_full, store_empty, store_pop;
    logic write_full, write_empty, write_pop;
    EntryIndex probe_head, store_head, selected_entry_index;
    WayIndex selected_way_index;
    WayWrite write_head;
    logic probe_response_full, probe_response_empty, probe_response_push;
    logic store_response_full, store_response_empty, store_response_push;
    logic [$clog2(RESPONSE_FIFO_DEPTH):0] probe_free, store_free;
    logic selected_probe, selected_store, selected_write;
    logic probe_space_available, store_space_available;
    logic operation_probe, operation_write;
    TTWordAddress request_address;
    logic [TT_WORD_BITS-1:0] response_word;
    logic [WAY_BITS-1:0] active_way;
    logic [COUNT_BITS-1:0] word_count;
    TTWordAddress clear_address;
    logic clear_done_toggle;
    (* ASYNC_REG = "TRUE", altera_attribute = "-name SYNCHRONIZER_IDENTIFICATION FORCED" *)
    logic clear_meta, clear_sync, ack_meta, idle_meta;
    logic memory_idle, idle_sync;
    logic probe_write_empty, store_write_empty, way_write_empty;

    // Requests carry logical indices; physical word addresses are formed after CDC.
    async_fifo #(.DATA_WIDTH(ENTRY_INDEX_BITS), .DEPTH(READ_FIFO_DEPTH)) probe_read_fifo (
        .wr_clk(req_clk), .wr_rst_n(req_rst_n), .wr_en(probe_valid && probe_ready),
        .wr_data(probe_entry_index), .full(probe_full), .wr_empty(probe_write_empty), .wr_free(),
        .rd_clk(mem_clk), .rd_rst_n(mem_rst_n), .rd_en(probe_pop), .rd_data(probe_head), .empty(probe_empty));
    async_fifo #(.DATA_WIDTH(ENTRY_INDEX_BITS), .DEPTH(READ_FIFO_DEPTH)) store_read_fifo (
        .wr_clk(req_clk), .wr_rst_n(req_rst_n), .wr_en(store_valid && store_ready),
        .wr_data(store_entry_index), .full(store_full), .wr_empty(store_write_empty), .wr_free(),
        .rd_clk(mem_clk), .rd_rst_n(mem_rst_n), .rd_en(store_pop), .rd_data(store_head), .empty(store_empty));
    async_fifo #(.DATA_WIDTH($bits(WayWrite)), .DEPTH(WRITE_FIFO_DEPTH)) way_write_fifo (
        .wr_clk(req_clk), .wr_rst_n(req_rst_n), .wr_en(write_valid && write_ready),
        .wr_data({write_entry_index, write_way_index, write_way}), .full(write_full), .wr_empty(way_write_empty), .wr_free(),
        .rd_clk(mem_clk), .rd_rst_n(mem_rst_n), .rd_en(write_pop), .rd_data(write_head), .empty(write_empty));
    // These two FIFOs contain exactly one external memory word per transfer.
    async_fifo #(.DATA_WIDTH(TT_WORD_BITS), .DEPTH(RESPONSE_FIFO_DEPTH)) probe_response_fifo (
        .wr_clk(mem_clk), .wr_rst_n(mem_rst_n), .wr_en(probe_response_push),
        .wr_data(response_word), .full(probe_response_full), .wr_free(probe_free),
        .rd_clk(req_clk), .rd_rst_n(req_rst_n), .rd_en(probe_response_valid && probe_response_ready),
        .rd_data(probe_response_data), .empty(probe_response_empty));
    async_fifo #(.DATA_WIDTH(TT_WORD_BITS), .DEPTH(RESPONSE_FIFO_DEPTH)) store_response_fifo (
        .wr_clk(mem_clk), .wr_rst_n(mem_rst_n), .wr_en(store_response_push),
        .wr_data(response_word), .full(store_response_full), .wr_free(store_free),
        .rd_clk(req_clk), .rd_rst_n(req_rst_n), .rd_en(store_response_valid && store_response_ready),
        .rd_data(store_response_data), .empty(store_response_empty));

    assign probe_ready = !probe_full;
    assign store_ready = !store_full;
    assign write_ready = !write_full;
    assign probe_response_valid = !probe_response_empty;
    assign store_response_valid = !store_response_empty;
    // A synchronized idle indication alone can lag a newly queued request.
    assign idle = idle_sync && probe_write_empty && store_write_empty && way_write_empty;
    assign memory_idle = state == S_IDLE && probe_empty && store_empty && write_empty;

    // Reserve the entire response before issuing a read, using conservative CDC space.
    always_comb begin
        selected_probe = !probe_empty && probe_space_available;
        selected_store = !selected_probe && !store_empty && store_space_available;
        selected_write = !selected_probe && !selected_store && !write_empty;
        // Select before translation so all three request classes share address logic.
        selected_entry_index = selected_probe ? probe_head : selected_store ? store_head : write_head.entry_index;
        selected_way_index = selected_write ? write_head.way_index : WayIndex'(0);
        backend_req_valid = state == S_CLEAR_REQ || state == S_REQUEST;
        backend_req_write = state == S_CLEAR_REQ || operation_write;
        backend_req_address = state == S_CLEAR_REQ ? clear_address : request_address;
        backend_req_length = state == S_CLEAR_REQ ? TTBurstLength'(1)
            : operation_write ? TTBurstLength'(WAY_WORDS) : TTBurstLength'(ENTRY_WORDS);
        probe_pop = state == S_IDLE && backend_req_ready && selected_probe;
        store_pop = state == S_IDLE && backend_req_ready && selected_store;
        write_pop = state == S_IDLE && backend_req_ready && selected_write;
        backend_write_valid = state == S_WRITE || state == S_CLEAR_DATA;
        backend_write_data = state == S_CLEAR_DATA ? '0 : active_way[word_count*TT_WORD_BITS +: TT_WORD_BITS];
        backend_write_last = state == S_CLEAR_DATA || int'(word_count) == WAY_WORDS - 1;
        // Whole-burst reservation guarantees room; retain ready/valid at the interface.
        backend_read_ready = state == S_READ
            && !(operation_probe ? probe_response_full : store_response_full);
        response_word = state == S_READ_PAD || (backend_done_valid && backend_done_error)
            ? TT_WORD_BITS'(0) : backend_read_data;
        backend_done_ready = state == S_READ || state == S_READ_DONE
            || state == S_WRITE || state == S_WRITE_DONE
            || state == S_CLEAR_DONE;
        probe_response_push = operation_probe && !probe_response_full
            && (state == S_READ_PAD || (state == S_READ && backend_read_valid));
        store_response_push = !operation_probe && !store_response_full
            && (state == S_READ_PAD || (state == S_READ && backend_read_valid));
    end

    // Pipeline capacity decoding before arbitration and FIFO pointer advancement.
    // Include this edge's response push so the registered flag never overstates space.
    always_ff @(posedge mem_clk) begin
        if (!mem_rst_n) begin
            probe_space_available <= 1'b0;
            store_space_available <= 1'b0;
        end else begin
            probe_space_available <= probe_response_push
                ? int'(probe_free) > ENTRY_WORDS : int'(probe_free) >= ENTRY_WORDS;
            store_space_available <= store_response_push
                ? int'(store_free) > ENTRY_WORDS : int'(store_free) >= ENTRY_WORDS;
        end
    end

    // Stream captured words immediately; short completions pad the reserved response.
    always_ff @(posedge mem_clk) begin
        if (!mem_rst_n) begin
            state <= S_IDLE; word_count <= '0;
            clear_meta <= 1'b0; clear_sync <= 1'b0; clear_done_toggle <= 1'b0;
            clear_address <= '0; operation_probe <= 1'b0; operation_write <= 1'b0; request_address <= '0;
        end else begin
            clear_meta <= clear_toggle; clear_sync <= clear_meta;
            case (state)
                S_IDLE: begin
                    if (clear_sync != clear_done_toggle && memory_idle) begin
                        clear_address <= '0; state <= S_CLEAR_REQ;
                    end else if (probe_pop || store_pop || write_pop) begin
                        // Register scheduling before driving the SDRAM controller.
                        word_count <= '0; operation_probe <= selected_probe;
                        operation_write <= selected_write;
                        request_address <= TTWordAddress'(selected_entry_index * ENTRY_WORDS)
                            + TTWordAddress'(selected_way_index * WAY_WORDS);
                        active_way <= write_head.data;
                        state <= S_REQUEST;
                    end
                end
                S_REQUEST: if (backend_req_valid && backend_req_ready)
                    state <= operation_write ? S_WRITE : S_READ;
                S_READ: begin
                    if (backend_read_valid && backend_read_ready) begin
                        word_count <= word_count + 1'b1;
                        if (backend_read_last || int'(word_count) == ENTRY_WORDS-1)
                            state <= S_READ_DONE;
                    end
                    // Published words cannot be withdrawn. Pad only missing words so
                    // even a prematurely completed backend cannot strand engine metadata.
                    if (backend_done_valid) begin
                        if (backend_read_valid && backend_read_ready
                                && int'(word_count) == ENTRY_WORDS-1) state <= S_IDLE;
                        else state <= S_READ_PAD;
                    end
                end
                S_READ_DONE: if (backend_done_valid)
                    state <= int'(word_count) == ENTRY_WORDS ? S_IDLE : S_READ_PAD;
                S_READ_PAD: if (probe_response_push || store_response_push) begin
                    if (int'(word_count) == ENTRY_WORDS-1) state <= S_IDLE;
                    else word_count <= word_count + 1'b1;
                end
                S_WRITE: begin
                    if (backend_write_valid && backend_write_ready) begin
                        if (backend_write_last) state <= S_WRITE_DONE;
                        else word_count <= word_count + 1'b1;
                    end
                    if (backend_done_valid) state <= S_IDLE;
                end
                S_WRITE_DONE: if (backend_done_valid) state <= S_IDLE;
                S_CLEAR_REQ: if (backend_req_valid && backend_req_ready) state <= S_CLEAR_DATA;
                S_CLEAR_DATA: if (backend_write_valid && backend_write_ready) state <= S_CLEAR_DONE;
                S_CLEAR_DONE: if (backend_done_valid) begin
                    if (clear_address == TTWordAddress'((ENTRY_COUNT*TT_WAYS-1)*WAY_WORDS)) begin
                        clear_done_toggle <= clear_sync; state <= S_IDLE;
                    end else begin
                        clear_address <= clear_address + TTWordAddress'(WAY_WORDS); state <= S_CLEAR_REQ;
                    end
                end
                default: state <= S_IDLE;
            endcase
        end
    end

    // New Game uses a slow toggle handshake after all engine metadata has drained.
    always_ff @(posedge req_clk) begin
        if (!req_rst_n) begin
            ack_meta <= 1'b0; clear_ack <= 1'b0; idle_meta <= 1'b0; idle_sync <= 1'b0;
        end else begin
            ack_meta <= clear_done_toggle; clear_ack <= ack_meta;
            idle_meta <= memory_idle; idle_sync <= idle_meta;
        end
    end
`ifndef SYNTHESIS
    initial begin
        if (WAY_BITS % TT_WORD_BITS != 0 || RESPONSE_FIFO_DEPTH < ENTRY_WORDS)
            $fatal(1, "TT transport requires aligned ways and whole-response FIFO capacity");
    end
`endif
endmodule
