// By Emet Behrendt

import general_chess_defs::*;
import tt_defs::*;

module tt_load_store #(
    parameter int TT_INDEX_BITS = 10,
    parameter int TAG_BITS = TT_DEFAULT_TAG_BITS,
    parameter int STORE_FIFO_DEPTH = 256,
    parameter bit USE_FULL_KEY = 1'b0
) (
    input logic clk,
    input logic rst_n,

    input logic clear,
    output logic clear_busy,

    input logic lookup_req_valid,
    output logic lookup_req_ready,
    input var TTLookupRequest lookup_req,
    output logic lookup_resp_valid,
    output TTLookupResponse lookup_resp,
    output logic cache_access,
    output logic cache_hit,
    output logic cache_access_is_store,

    input logic store_req_valid,
    output logic store_req_ready,
    input var TTStoreRequest store_req
);

    localparam int TT_ENTRY_COUNT = 1 << TT_INDEX_BITS;
    localparam int SELECTOR_BITS = $bits(ZobristKey) - TAG_BITS;
    localparam int HASH_ENTROPY_BITS = SELECTOR_BITS < TT_HASH_BITS
        ? SELECTOR_BITS : TT_HASH_BITS;
    localparam int COMPACT_ENTRY_BITS = TAG_BITS + TT_ENTRY_PAYLOAD_BITS;

    typedef logic [TT_INDEX_BITS-1:0] TTIndex;
    typedef logic [TAG_BITS-1:0] EntryTag;
    typedef struct packed {
        TTAge age;
        TTBoundType bound_type;
        TTDepth depth;
        EvalScore score;
        TTMoveBits best_move_bits;
        EntryTag tag;
    } CompactEntry;
    localparam int STORAGE_ENTRY_BITS = USE_FULL_KEY ? $bits(TTFullEntry) : $bits(CompactEntry);
    typedef logic [STORAGE_ENTRY_BITS-1:0] TTStorageEntry;
    typedef logic [$clog2(STORE_FIFO_DEPTH + 1)-1:0] StoreFifoCount;

    // Retain the publisher until the memory operation completes.
    typedef struct packed {
        ZobristKey zobrist_key;
        TTDepth depth;
        EvalScore score;
        TTBoundType bound_type;
        Move best_move;
        TTAge age;
        PlyIndex ply;
    } TTStorePayload;

    typedef enum logic [1:0] {
        STORE_IDLE,
        STORE_WRITE,
        STORE_RETRY
    } StoreState;

    StoreState store_state;
    TTStorePayload active_store_req;
    logic active_store_replace;
    TTLookupRequest active_lookup_req;

    TTStorePayload store_fifo_data;
    StoreFifoCount store_fifo_count;
    logic store_fifo_valid;
    logic store_fifo_push_ready;

    logic clear_active;
    TTIndex clear_index;
    logic clear_prev;
    logic clear_start;
    logic lookup_accept;
    logic store_accept;
    logic store_pop;
    logic mem_read_enable;
    logic mem_write_enable;
    TTIndex mem_read_address;
    TTIndex mem_write_address;
    TTStorageEntry mem_write_data;
    TTStorageEntry mem_read_data;

`ifndef SYNTHESIS
    initial begin
        if (STORE_FIFO_DEPTH < 2) $error("tt_load_store STORE_FIFO_DEPTH must be at least two");
        if (TAG_BITS < 1 || TAG_BITS >= $bits(ZobristKey))
            $error("tt_load_store TAG_BITS must be between 1 and 63");
        if (TT_INDEX_BITS > HASH_ENTROPY_BITS)
            $error("tt_load_store has more TT index bits than untagged hash entropy");
        else if (TT_INDEX_BITS + 8 > HASH_ENTROPY_BITS)
            $warning("tt_load_store TT entry count is large relative to untagged hash entropy");
    end
`endif

    assign clear_start = clear && !clear_prev && !clear_active;
    // The inferred-RAM backend has no separate frontend cache.
    assign cache_access = 1'b0;
    assign cache_hit = 1'b0;
    assign cache_access_is_store = 1'b0;
    assign clear_busy = clear_start || clear_active;
    assign lookup_req_ready = !clear_start && !clear_active;
    assign lookup_accept = lookup_req_valid && lookup_req_ready;
    // TT publication is best-effort. Consume requests even when the queue is
    // full so search threads never backpressure on a store.
    assign store_req_ready = !clear_start && !clear_active;
    assign store_accept = store_req_valid && store_req_ready;
    assign store_pop = !lookup_accept && store_state == STORE_IDLE && store_fifo_valid;

    function automatic TTIndex tt_index(input ZobristKey zobrist_key);
        automatic logic [TT_HASH_BITS-1:0] hash = tt_index_hash(zobrist_key, TAG_BITS);
        automatic TTIndex folded = '0;

        // Fold every hash bit into the power-of-two RAM address so no
        // untagged Zobrist bit is silently discarded by a narrow table.
        for (int bit_index = 0; bit_index < TT_HASH_BITS; bit_index++)
            folded[bit_index % TT_INDEX_BITS] ^= hash[bit_index];
        return folded;
    endfunction : tt_index

    function automatic EntryTag entry_tag(input ZobristKey zobrist_key);
        return EntryTag'(zobrist_key);
    endfunction : entry_tag

    function automatic TTStorePayload store_payload(input TTStoreRequest req);
        automatic TTStorePayload payload;

        payload.zobrist_key = req.zobrist_key;
        payload.depth = req.depth;
        payload.score = req.score;
        payload.bound_type = req.bound_type;
        payload.best_move = req.best_move;
        payload.age = req.age;
        payload.ply = req.ply;
        return payload;
    endfunction : store_payload

    function automatic TTStorageEntry invalid_storage_entry();
        if (USE_FULL_KEY) begin
            return TTStorageEntry'(tt_invalid_full_entry());
        end

        begin
            automatic CompactEntry compact_entry = '0;
            compact_entry.bound_type = TT_BOUND_INVALID;
            return TTStorageEntry'(compact_entry);
        end
    endfunction : invalid_storage_entry

    function automatic TTStorageEntry make_storage_entry(input TTStorePayload req);
        if (USE_FULL_KEY) begin
            return TTStorageEntry'(tt_make_full_entry(
                req.zobrist_key,
                req.best_move,
                tt_normalize_mate_score(req.score, req.ply),
                req.depth,
                req.bound_type,
                req.age,
                TTAux'(0)
            ));
        end

        begin
            automatic CompactEntry compact_entry;

            compact_entry.tag = entry_tag(req.zobrist_key);
            compact_entry.best_move_bits = tt_encode_move(req.best_move);
            compact_entry.score = tt_normalize_mate_score(req.score, req.ply);
            compact_entry.depth = req.depth;
            compact_entry.bound_type = req.bound_type;
            compact_entry.age = req.age;
            return TTStorageEntry'(compact_entry);
        end
    endfunction : make_storage_entry

    function automatic TTBoundType storage_bound_type(input TTStorageEntry entry);
        if (USE_FULL_KEY) begin
            automatic TTFullEntry full_entry;

            full_entry = TTFullEntry'(entry);
            return full_entry.bound_type;
        end

        begin
            automatic CompactEntry compact_entry;

            compact_entry = CompactEntry'(entry);
            return compact_entry.bound_type;
        end
    endfunction : storage_bound_type

    function automatic TTDepth storage_depth(input TTStorageEntry entry);
        if (USE_FULL_KEY) begin
            automatic TTFullEntry full_entry;

            full_entry = TTFullEntry'(entry);
            return full_entry.depth;
        end

        begin
            automatic CompactEntry compact_entry;

            compact_entry = CompactEntry'(entry);
            return compact_entry.depth;
        end
    endfunction : storage_depth

    function automatic TTAge storage_age(input TTStorageEntry entry);
        if (USE_FULL_KEY) begin
            automatic TTFullEntry full_entry;

            full_entry = TTFullEntry'(entry);
            return full_entry.age;
        end

        begin
            automatic CompactEntry compact_entry;

            compact_entry = CompactEntry'(entry);
            return compact_entry.age;
        end
    endfunction : storage_age

    function automatic EvalScore storage_score(input TTStorageEntry entry);
        if (USE_FULL_KEY) begin
            automatic TTFullEntry full_entry;

            full_entry = TTFullEntry'(entry);
            return full_entry.score;
        end

        begin
            automatic CompactEntry compact_entry;

            compact_entry = CompactEntry'(entry);
            return compact_entry.score;
        end
    endfunction : storage_score

    function automatic Move storage_best_move(input TTStorageEntry entry);
        if (USE_FULL_KEY) begin
            automatic TTFullEntry full_entry;

            full_entry = TTFullEntry'(entry);
            return tt_decode_move(full_entry.best_move_bits);
        end

        begin
            automatic CompactEntry compact_entry;

            compact_entry = CompactEntry'(entry);
            return tt_decode_move(compact_entry.best_move_bits);
        end
    endfunction : storage_best_move

    function automatic logic storage_key_matches(input TTStorageEntry entry, input ZobristKey zobrist_key);
        if (USE_FULL_KEY) begin
            automatic TTFullEntry full_entry;

            full_entry = TTFullEntry'(entry);
            return full_entry.zobrist_key == zobrist_key;
        end

        begin
            automatic CompactEntry compact_entry;

            compact_entry = CompactEntry'(entry);
            return compact_entry.tag == entry_tag(zobrist_key);
        end
    endfunction : storage_key_matches

    function automatic TTLookupResponse make_lookup_response(input TTLookupRequest req, input TTStorageEntry entry);
        automatic TTLookupResponse resp;
        automatic logic entry_hit;

        entry_hit = (storage_bound_type(entry) != TT_BOUND_INVALID) && storage_key_matches(entry, req.zobrist_key);

        resp.thread_id = req.thread_id;
        resp.hit = entry_hit;
        resp.score = entry_hit ? tt_restore_mate_score(storage_score(entry), req.ply) : UNKNOWN_EVAL_SCORE;
        resp.bound_type = entry_hit ? storage_bound_type(entry) : TT_BOUND_INVALID;
        resp.depth = entry_hit ? storage_depth(entry) : TTDepth'(0);
        resp.best_move = entry_hit ? storage_best_move(entry) : NULL_MOVE;
        return resp;
    endfunction : make_lookup_response

    function automatic logic should_replace(input TTStorageEntry old_entry, input TTStorePayload req);
        return tt_should_replace(
            storage_bound_type(old_entry) != TT_BOUND_INVALID,
            storage_key_matches(old_entry, req.zobrist_key),
            storage_age(old_entry),
            storage_depth(old_entry),
            storage_bound_type(old_entry),
            req.age,
            req.depth,
            req.bound_type
        );
    endfunction : should_replace

    // Keep response data continuously driven so it is stable with the valid pulse.
    assign lookup_resp = make_lookup_response(active_lookup_req, mem_read_data);

    always_comb begin
        mem_read_enable = 1'b0;
        mem_read_address = TTIndex'(0);
        mem_write_enable = 1'b0;
        mem_write_address = TTIndex'(0);
        mem_write_data = invalid_storage_entry();

        if (clear_active) begin
            mem_write_enable = 1'b1;
            mem_write_address = clear_index;
        end else if (lookup_accept) begin
            mem_read_enable = 1'b1;
            mem_read_address = tt_index(lookup_req.zobrist_key);
        end else begin
            case (store_state)
                STORE_IDLE: begin
                    if (store_fifo_valid) begin
                        mem_read_enable = 1'b1;
                        mem_read_address = tt_index(store_fifo_data.zobrist_key);
                    end
                end

                STORE_WRITE: begin
                    if (should_replace(mem_read_data, active_store_req)) begin
                        mem_write_enable = 1'b1;
                        mem_write_address = tt_index(active_store_req.zobrist_key);
                        mem_write_data = make_storage_entry(active_store_req);
                    end
                end

                STORE_RETRY: begin
                    if (active_store_replace) begin
                        mem_write_enable = 1'b1;
                        mem_write_address = tt_index(active_store_req.zobrist_key);
                        mem_write_data = make_storage_entry(active_store_req);
                    end
                end

                default: begin
                end
            endcase
        end
    end

    sync_read_simple_dual_port_ram #(
        .NUM_WORDS(TT_ENTRY_COUNT),
        .WORD_SIZE(STORAGE_ENTRY_BITS)
    ) entry_memory (
        .clock(clk),
        .data(mem_write_data),
        .rdaddress(mem_read_address),
        .rden(mem_read_enable),
        .wraddress(mem_write_address),
        .wren(mem_write_enable),
        .q(mem_read_data)
    );

    always_ff @(posedge clk) begin
        if (!rst_n) begin
            lookup_resp_valid <= 1'b0;
            store_state <= STORE_IDLE;
            clear_active <= 1'b0;
            clear_index <= TTIndex'(0);
            clear_prev <= 1'b0;
        end else begin
            lookup_resp_valid <= 1'b0;
            clear_prev <= clear;

            if (clear_start) begin
                clear_active <= 1'b1;
                clear_index <= TTIndex'(0);
                store_state <= STORE_IDLE;
            end else if (clear_active) begin
                if (clear_index == TTIndex'(TT_ENTRY_COUNT - 1)) begin
                    clear_active <= 1'b0;
                end else begin
                    clear_index <= clear_index + TTIndex'(1);
                end
            end else begin
                if (lookup_accept) begin
                    active_lookup_req <= lookup_req;
                    lookup_resp_valid <= 1'b1;
                end

                if (lookup_accept) begin
                    if (store_state == STORE_WRITE) begin
                        // The interrupted write needs only this decision, not a full old entry copy.
                        active_store_replace <= should_replace(mem_read_data, active_store_req);
                        store_state <= STORE_RETRY;
                    end

                end else begin
                    case (store_state)
                        STORE_IDLE: begin
                            if (store_fifo_valid) begin
                                active_store_req <= store_fifo_data;
                                store_state <= STORE_WRITE;
                            end
                        end

                        STORE_WRITE: begin
                            store_state <= STORE_IDLE;

                        end

                        STORE_RETRY: begin
                            store_state <= STORE_IDLE;

                        end
                    endcase
                end
            end
        end
    end

    synchronous_fifo #(
        .DATA_WIDTH($bits(TTStorePayload)),
        .DEPTH(STORE_FIFO_DEPTH)
    ) store_queue (
        .clk(clk),
        .rst_n(rst_n),
        .clear(clear_start),
        .push_valid(store_accept),
        .push_ready(store_fifo_push_ready),
        .push_data(store_payload(store_req)),
        .pop_valid(store_fifo_valid),
        .pop_ready(store_pop),
        .pop_data(store_fifo_data),
        .count(store_fifo_count)
    );

endmodule : tt_load_store
