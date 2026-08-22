// Portable cached TT frontend for a 16-bit burst-memory backend.

import general_chess_defs::*;
import tt_defs::*;

module tt_external_load_store #(
    parameter int CACHE_INDEX_BITS = 10,
    parameter int TAG_BITS = TT_DEFAULT_TAG_BITS,
    parameter int ENTRY_COUNT = TT_EXTERNAL_WORD_COUNT
        / ((TAG_BITS + TT_ENTRY_PAYLOAD_BITS + TT_WORD_BITS - 1) / TT_WORD_BITS),
    parameter int STORE_FIFO_DEPTH = 256,
    parameter int unsigned STALE_DEPTH_TOLERANCE = 4
) (
    input logic clk,
    input logic rst_n,
    input logic memory_ready,
    input logic memory_error,
    input logic clear,
    output logic clear_busy,
    input logic lookup_req_valid,
    output logic lookup_req_ready,
    input TTLookupRequest lookup_req,
    output logic lookup_resp_valid,
    output TTLookupResponse lookup_resp,
    output logic cache_access,
    output logic cache_hit,
    output logic cache_access_is_store,
    input logic store_req_valid,
    output logic store_req_ready,
    input TTStoreRequest store_req,
    output logic mem_req_valid,
    input logic mem_req_ready,
    output logic mem_req_write,
    output TTWordAddress mem_req_address,
    output logic [3:0] mem_req_length,
    output logic mem_write_valid,
    input logic mem_write_ready,
    output logic [15:0] mem_write_data,
    output logic mem_write_last,
    input logic mem_read_valid,
    output logic mem_read_ready,
    input logic [15:0] mem_read_data,
    input logic mem_read_last,
    input logic mem_done_valid,
    output logic mem_done_ready,
    input logic mem_done_error
);

    localparam int CACHE_COUNT = 1 << CACHE_INDEX_BITS;
    localparam int ENTRY_INDEX_BITS = $clog2(ENTRY_COUNT);
    localparam int SELECTOR_BITS = $bits(ZobristKey) - TAG_BITS;
    localparam int HASH_ENTROPY_BITS = SELECTOR_BITS < TT_HASH_BITS
        ? SELECTOR_BITS : TT_HASH_BITS;
    localparam int COMPACT_ENTRY_BITS = TAG_BITS + TT_ENTRY_PAYLOAD_BITS;
    localparam int PHYSICAL_ENTRY_BITS =
        ((COMPACT_ENTRY_BITS + TT_WORD_BITS - 1) / TT_WORD_BITS) * TT_WORD_BITS;
    localparam int WORDS_PER_ENTRY = PHYSICAL_ENTRY_BITS / TT_WORD_BITS;
    localparam int WORD_COUNT_BITS = $clog2(WORDS_PER_ENTRY);
    typedef logic [ENTRY_INDEX_BITS-1:0] EntryIndex;
    typedef logic [CACHE_INDEX_BITS-1:0] CacheIndex;
    typedef logic [TAG_BITS-1:0] EntryTag;
    typedef logic [PHYSICAL_ENTRY_BITS-1:0] PhysicalEntry;
    typedef struct packed {
        TTAge age;
        TTBoundType bound_type;
        TTDepth depth;
        EvalScore score;
        TTMoveBits best_move_bits;
        EntryTag tag;
    } CompactEntry;
    typedef logic [$clog2(STORE_FIFO_DEPTH + 1)-1:0] StoreFifoCount;
    typedef struct packed {
        logic valid;
        EntryIndex tag;
        PhysicalEntry data;
    } CacheLine;

    typedef enum logic [3:0] {
        S_IDLE, S_READ_REQ, S_READ_DATA, S_WRITE_REQ, S_WRITE_DATA, S_WRITE_DONE,
        S_CLEAR_REQ, S_CLEAR_DATA, S_CLEAR_DONE, S_CACHE_CLEAR, S_CACHE_READ,
        S_READ_DONE
    } State;

    State state;
    logic operation_store;
    TTLookupRequest active_lookup;
    TTStoreRequest active_store;
    PhysicalEntry transfer_entry;
    PhysicalEntry write_entry;
    logic [WORD_COUNT_BITS-1:0] word_count;
    EntryIndex active_index;
    EntryIndex clear_index;
    CacheIndex cache_clear_index;
    TTAge generation;
    logic clear_prev;
    logic clear_pending;
    EntryIndex cache_request_index;
    EntryIndex lookup_request_index;
    EntryIndex store_request_index;
    StoreFifoCount store_fifo_count;
    TTStoreRequest store_fifo_data;
    logic store_fifo_valid;
    logic store_fifo_push_ready;
    logic store_accept;
    logic store_pop;
    logic lookup_probe_valid;
    TTLookupRequest lookup_probe_req;
    EntryIndex lookup_probe_index;
    logic lookup_miss_valid;
    TTLookupRequest lookup_miss_req;
    EntryIndex lookup_miss_index;
    logic store_write_pending;
    EntryIndex store_write_index;
    PhysicalEntry store_write_data;
    logic backend_lookup_response;
    logic cache_read_enable;
    CacheIndex cache_read_index;

`ifndef SYNTHESIS
    initial begin
        if (STORE_FIFO_DEPTH < 2) $error("tt_external_load_store STORE_FIFO_DEPTH must be at least two");
        if (TAG_BITS < 1 || TAG_BITS >= $bits(ZobristKey))
            $error("tt_external_load_store TAG_BITS must be between 1 and 63");
        if (ENTRY_INDEX_BITS > HASH_ENTROPY_BITS)
            $error("tt_external_load_store has more TT entries than untagged hash entropy can address");
        else if (ENTRY_INDEX_BITS + 8 > HASH_ENTROPY_BITS)
            $warning("tt_external_load_store TT entry count is large relative to untagged hash entropy");
        if (WORDS_PER_ENTRY > 15)
            $error("tt_external_load_store entry does not fit the four-bit burst length");
    end
`endif

    // Packing the complete line into one RAM avoids separately rounding the
    // data, tag, and validity arrays to physical block-RAM boundaries.
    (* ramstyle = "M10K" *) (* ram_style = "block" *) CacheLine cache[0:CACHE_COUNT-1];
    CacheLine cache_read_line;

    function automatic EntryIndex entry_index(input ZobristKey key);
        logic [TT_HASH_BITS + ENTRY_INDEX_BITS-1:0] product;
        product = tt_index_hash(key, TAG_BITS) * ENTRY_COUNT;
        return EntryIndex'(product >> TT_HASH_BITS);
    endfunction

    function automatic TTWordAddress word_address(input EntryIndex index);
        return TTWordAddress'(index * WORDS_PER_ENTRY);
    endfunction

    function automatic EntryTag entry_tag(input ZobristKey key);
        return EntryTag'(key);
    endfunction

    function automatic CompactEntry unpack_entry(input PhysicalEntry physical);
        return CompactEntry'(physical[COMPACT_ENTRY_BITS-1:0]);
    endfunction

    function automatic TTAge physical_age(input PhysicalEntry physical);
        automatic CompactEntry entry = unpack_entry(physical);
        return entry.age;
    endfunction

    function automatic logic entry_hit(input CompactEntry entry, input ZobristKey key);
        return entry.bound_type != TT_BOUND_INVALID && entry.age == generation
            && entry.tag == entry_tag(key);
    endfunction

    function automatic logic should_replace(input CompactEntry old_entry, input TTStoreRequest req);
        return tt_should_replace(
            old_entry.bound_type != TT_BOUND_INVALID,
            old_entry.tag == entry_tag(req.zobrist_key),
            old_entry.age,
            old_entry.depth,
            old_entry.bound_type,
            generation,
            req.depth,
            req.bound_type,
            STALE_DEPTH_TOLERANCE
        );
    endfunction

    function automatic PhysicalEntry make_store_entry(input TTStoreRequest req);
        CompactEntry entry;
        PhysicalEntry physical;

        entry.tag = entry_tag(req.zobrist_key);
        entry.best_move_bits = tt_encode_move(req.best_move);
        entry.score = tt_normalize_mate_score(req.score, req.ply);
        entry.depth = req.depth;
        entry.bound_type = req.bound_type;
        entry.age = generation;
        physical = '0;
        physical[COMPACT_ENTRY_BITS-1:0] = entry;
        return physical;
    endfunction

    task automatic drive_lookup_response(input TTLookupRequest req, input PhysicalEntry physical);
        CompactEntry entry;
        logic hit;
        entry = unpack_entry(physical);
        hit = entry_hit(entry, req.zobrist_key);
        lookup_resp.thread_id <= req.thread_id;
        lookup_resp.hit <= hit;
        lookup_resp.score <= hit ? tt_restore_mate_score(entry.score, req.ply) : UNKNOWN_EVAL_SCORE;
        lookup_resp.bound_type <= hit ? entry.bound_type : TT_BOUND_INVALID;
        lookup_resp.depth <= hit ? entry.depth : TTDepth'(0);
        lookup_resp.best_move <= hit ? tt_decode_move(entry.best_move_bits) : NULL_MOVE;
        lookup_resp_valid <= 1'b1;
    endtask

    always_comb begin
        // Reduce both hashes before arbitration so lookup validity controls
        // only a compact index mux rather than feeding the range multiplier.
        lookup_request_index = entry_index(lookup_req.zobrist_key);
        store_request_index = entry_index(store_fifo_data.zobrist_key);
        cache_request_index = lookup_req_valid
            ? lookup_request_index : store_request_index;
        // One buffered probe is sufficient to serve cache hits while an
        // unrelated SDRAM transaction is active. Cache-fill/write cycles are
        // excluded so inferred single-port RAM read-during-write behavior is
        // never part of the frontend contract.
        lookup_req_ready = memory_ready && !memory_error && !clear && !clear_busy
            && !lookup_probe_valid && !lookup_miss_valid
            && state != S_READ_DONE && state != S_WRITE_DONE;
        // A full queue drops the incoming best-effort publication rather than
        // stalling its search thread.
        store_req_ready = !clear && !clear_busy;
        store_accept = store_req_valid && store_req_ready;
        store_pop = state == S_IDLE && !clear_pending && !lookup_req_valid
            && !lookup_probe_valid && !lookup_miss_valid && !store_write_pending
            && store_fifo_valid;
        cache_read_enable = (lookup_req_valid && lookup_req_ready) || store_pop;
        cache_read_index = CacheIndex'(cache_request_index);
        clear_busy = clear || clear_pending || state == S_CACHE_CLEAR
            || state == S_CLEAR_REQ || state == S_CLEAR_DATA || state == S_CLEAR_DONE;
        mem_req_valid = state == S_READ_REQ || state == S_WRITE_REQ || state == S_CLEAR_REQ;
        mem_req_write = state != S_READ_REQ;
        mem_req_address = (state == S_CLEAR_REQ || state == S_CLEAR_DATA || state == S_CLEAR_DONE)
            ? word_address(clear_index) + TTWordAddress'(WORDS_PER_ENTRY - 1) : word_address(active_index);
        mem_req_length = (state == S_CLEAR_REQ || state == S_CLEAR_DATA || state == S_CLEAR_DONE)
            ? 4'd1 : 4'(WORDS_PER_ENTRY);
        mem_write_valid = state == S_WRITE_DATA || state == S_CLEAR_DATA;
        mem_write_data = (state == S_CLEAR_DATA) ? 16'h0000
            : write_entry[word_count*TT_WORD_BITS +: TT_WORD_BITS];
        mem_write_last = state == S_CLEAR_DATA
            || word_count == WORD_COUNT_BITS'(WORDS_PER_ENTRY - 1);
        mem_read_ready = state == S_READ_DATA;
        // Every backend request, including reads, has a completion token. Do
        // not allow the backend to remain blocked after delivering read data.
        mem_done_ready = state == S_READ_DONE || state == S_WRITE_DONE || state == S_CLEAR_DONE;
        backend_lookup_response = (!operation_store && state == S_READ_DONE && mem_done_valid)
            || (!operation_store && memory_error && state != S_IDLE);
    end

    always_ff @(posedge clk) begin
        if (!rst_n) begin
            state <= S_CACHE_CLEAR;
            generation <= TTAge'(1);
            clear_prev <= 1'b0;
            clear_pending <= 1'b0;
            lookup_resp_valid <= 1'b0;
            cache_access <= 1'b0;
            cache_hit <= 1'b0;
            cache_access_is_store <= 1'b0;
            lookup_resp <= TTLookupResponse'('0);
            word_count <= '0;
            clear_index <= '0;
            cache_clear_index <= '0;
            lookup_probe_valid <= 1'b0;
            lookup_miss_valid <= 1'b0;
            store_write_pending <= 1'b0;
        end else begin
            lookup_resp_valid <= 1'b0;
            cache_access <= 1'b0;
            cache_hit <= 1'b0;
            cache_access_is_store <= 1'b0;
            clear_prev <= clear;
            if (clear && !clear_prev) clear_pending <= 1'b1;
            if (cache_read_enable) cache_read_line <= cache[cache_read_index];

            if (lookup_req_valid && lookup_req_ready) begin
                lookup_probe_req <= lookup_req;
                lookup_probe_index <= cache_request_index;
                lookup_probe_valid <= 1'b1;
            end

            // Lookup cache probes are independent of the external-memory state
            // machine. A response from the active backend operation wins the
            // single response port; a buffered probe remains held for one more
            // cycle in that rare collision.
            if (lookup_probe_valid && !backend_lookup_response) begin
                cache_access <= 1'b1;
                cache_hit <= cache_read_line.valid
                    && physical_age(cache_read_line.data) == generation
                    && cache_read_line.tag == lookup_probe_index;
                cache_access_is_store <= 1'b0;
                if (cache_read_line.valid
                        && physical_age(cache_read_line.data) == generation
                        && cache_read_line.tag == lookup_probe_index) begin
                    drive_lookup_response(lookup_probe_req, cache_read_line.data);
                end else begin
                    lookup_miss_req <= lookup_probe_req;
                    lookup_miss_index <= lookup_probe_index;
                    lookup_miss_valid <= 1'b1;
                end
                lookup_probe_valid <= 1'b0;
            end

            if (memory_error && state != S_IDLE) begin
                if (operation_store) begin
                end else begin
                    drive_lookup_response(active_lookup, '0);
                end
                state <= S_IDLE;
            end else case (state)
                S_CACHE_CLEAR: begin
                    cache[cache_clear_index] <= CacheLine'('0);
                    if (cache_clear_index == CacheIndex'(CACHE_COUNT-1)) state <= S_IDLE;
                    else cache_clear_index <= cache_clear_index + CacheIndex'(1);
                end
                S_CACHE_READ: begin
                    cache_access <= 1'b1;
                    cache_hit <= cache_read_line.valid
                        && physical_age(cache_read_line.data) == generation
                        && cache_read_line.tag == active_index;
                    cache_access_is_store <= 1'b1;
                    if (cache_read_line.valid
                            && physical_age(cache_read_line.data) == generation
                            && cache_read_line.tag == active_index) begin
                        if (should_replace(unpack_entry(cache_read_line.data), active_store)) begin
                            store_write_index <= active_index;
                            store_write_data <= make_store_entry(active_store);
                            store_write_pending <= 1'b1;
                        end
                        state <= S_IDLE;
                    end else begin
                        state <= S_READ_REQ;
                    end
                end
                S_IDLE: begin
                    if ((clear_pending || (clear && !clear_prev))
                            && !lookup_probe_valid && !lookup_miss_valid
                            && !store_write_pending) begin
                        clear_pending <= 1'b0;
                        if (&generation) begin
                            clear_index <= '0;
                            state <= S_CLEAR_REQ;
                        end else begin
                            generation <= generation + TTAge'(1);
                        end
                    end else if (lookup_miss_valid) begin
                        active_index <= lookup_miss_index;
                        active_lookup <= lookup_miss_req;
                        operation_store <= 1'b0;
                        lookup_miss_valid <= 1'b0;
                        state <= S_READ_REQ;
                    end else if (store_write_pending && !lookup_probe_valid
                            && !lookup_req_valid) begin
                        active_index <= store_write_index;
                        write_entry <= store_write_data;
                        operation_store <= 1'b1;
                        store_write_pending <= 1'b0;
                        state <= S_WRITE_REQ;
                    end else if (store_pop) begin
                        EntryIndex idx;
                        idx = cache_request_index;
                        active_index <= idx;
                        active_store <= store_fifo_data;
                        operation_store <= 1'b1;
                        state <= S_CACHE_READ;
                    end
                end
                S_READ_REQ: if (mem_req_valid && mem_req_ready) begin word_count <= '0; transfer_entry <= '0; state <= S_READ_DATA; end
                S_READ_DATA: if (mem_read_valid) begin
                    PhysicalEntry assembled;
                    assembled = transfer_entry;
                    assembled[word_count*TT_WORD_BITS +: TT_WORD_BITS] = mem_read_data;
                    transfer_entry <= assembled;
                    if (mem_read_last
                            || word_count == WORD_COUNT_BITS'(WORDS_PER_ENTRY - 1)) begin
                        state <= S_READ_DONE;
                    end else word_count <= word_count + WORD_COUNT_BITS'(1);
                end
                S_READ_DONE: if (mem_done_valid) begin
                    if (mem_done_error) begin
                        if (operation_store) begin
                        end else begin
                            drive_lookup_response(active_lookup, '0);
                        end
                        state <= S_IDLE;
                    end else begin
                        CacheIndex cidx;
                        cidx = CacheIndex'(active_index);
                        cache[cidx] <= CacheLine'({1'b1, active_index, transfer_entry});
                        if (!operation_store) begin
                            drive_lookup_response(active_lookup, transfer_entry);
                            state <= S_IDLE;
                        end else if (should_replace(unpack_entry(transfer_entry), active_store)) begin
                            store_write_index <= active_index;
                            store_write_data <= make_store_entry(active_store);
                            store_write_pending <= 1'b1;
                            state <= S_IDLE;
                        end else begin
                            state <= S_IDLE;
                        end
                    end
                end
                S_WRITE_REQ: if (mem_req_valid && mem_req_ready) begin word_count <= '0; state <= S_WRITE_DATA; end
                S_WRITE_DATA: if (mem_write_valid && mem_write_ready) begin
                    if (word_count == WORD_COUNT_BITS'(WORDS_PER_ENTRY - 1)) state <= S_WRITE_DONE;
                    else word_count <= word_count + WORD_COUNT_BITS'(1);
                end
                S_WRITE_DONE: if (mem_done_valid) begin
                    CacheIndex cidx;
                    cidx = CacheIndex'(active_index);
                    if (!mem_done_error) begin
                        cache[cidx] <= CacheLine'({1'b1, active_index, write_entry});
                    end
                    state <= S_IDLE;
                end
                S_CLEAR_REQ: if (mem_req_valid && mem_req_ready) state <= S_CLEAR_DATA;
                S_CLEAR_DATA: if (mem_write_valid && mem_write_ready) state <= S_CLEAR_DONE;
                S_CLEAR_DONE: if (mem_done_valid) begin
                    if (clear_index == EntryIndex'(ENTRY_COUNT - 1)) begin
                        generation <= TTAge'(1);
                        cache_clear_index <= '0;
                        state <= S_CACHE_CLEAR;
                    end else begin
                        clear_index <= clear_index + EntryIndex'(1);
                        state <= S_CLEAR_REQ;
                    end
                end
                default: state <= S_IDLE;
            endcase
        end
    end

    synchronous_fifo #(
        .DATA_WIDTH($bits(TTStoreRequest)),
        .DEPTH(STORE_FIFO_DEPTH)
    ) store_queue (
        .clk(clk),
        .rst_n(rst_n),
        .clear(clear && !clear_prev),
        .push_valid(store_accept),
        .push_ready(store_fifo_push_ready),
        .push_data(store_req),
        .pop_valid(store_fifo_valid),
        .pop_ready(store_pop),
        .pop_data(store_fifo_data),
        .count(store_fifo_count)
    );
endmodule
