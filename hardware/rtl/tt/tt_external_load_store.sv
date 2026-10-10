// Engine-domain two-way cache of individual TT ways, metadata, and response assembly.
import chess_defs::*;
import tt_defs::*;
module tt_external_load_store #(
    parameter int CACHE_INDEX_BITS = 10,
    parameter int TAG_BITS = TT_DEFAULT_TAG_BITS,
    parameter int ENTRY_COUNT = 2 * (TT_EXTERNAL_WORD_COUNT
        / (TT_WAYS*((TAG_BITS+TT_ENTRY_PAYLOAD_BITS+TT_WORD_BITS-1)/TT_WORD_BITS)) / 2),
    parameter int STORE_FIFO_DEPTH = 256,
    parameter int OUTSTANDING_DEPTH = 8,
    parameter int RESPONSE_FIFO_DEPTH = 64,
    parameter int WRITEBACK_FIFO_DEPTH = 8,
    parameter int unsigned STALE_DEPTH_TOLERANCE = 4
) (
    input logic clk, rst_n, memory_clk, memory_rst_n,
    input logic memory_ready, memory_error,
    input logic clear,
    output logic clear_busy,
    input logic lookup_req_valid,
    output logic lookup_req_ready,
    input TTLookupRequest lookup_req,
    output logic lookup_resp_valid,
    output TTLookupResponse lookup_resp,
    output logic cache_access, cache_hit, cache_store_access, cache_store_hit,
    input logic store_req_valid,
    output logic store_req_ready,
    input TTStoreRequest store_req,
    // The search arbiter uses this hint to select a probe in the other bank.
    output logic store_bank_valid, store_bank,
    output logic mem_req_valid,
    input logic mem_req_ready,
    output logic mem_req_write,
    output TTWordAddress mem_req_address,
    output TTBurstLength mem_req_length,
    output logic mem_write_valid,
    input logic mem_write_ready,
    output logic [TT_WORD_BITS-1:0] mem_write_data,
    output logic mem_write_last,
    input logic mem_read_valid,
    output logic mem_read_ready,
    input logic [TT_WORD_BITS-1:0] mem_read_data,
    input logic mem_read_last,
    input logic mem_done_valid,
    output logic mem_done_ready,
    input logic mem_done_error
);
    localparam int BANK_INDEX_BITS = CACHE_INDEX_BITS-1;
    localparam int BANK_SET_COUNT = 1 << BANK_INDEX_BITS;
    localparam int CACHE_SET_COUNT = 1 << CACHE_INDEX_BITS;
    localparam int CACHE_TAG_COUNT = (ENTRY_COUNT+CACHE_SET_COUNT-1)/CACHE_SET_COUNT;
    localparam int CACHE_TAG_BITS = CACHE_TAG_COUNT <= 1 ? 1 : $clog2(CACHE_TAG_COUNT);
    localparam int ENTRY_INDEX_BITS = $clog2(ENTRY_COUNT+1);
    localparam int WAY_PAYLOAD_BITS = TAG_BITS + TT_ENTRY_PAYLOAD_BITS;
    localparam int WAY_BITS = ((WAY_PAYLOAD_BITS+TT_WORD_BITS-1)/TT_WORD_BITS)*TT_WORD_BITS;
    localparam int WAY_WORDS = WAY_BITS/TT_WORD_BITS;
    localparam int ENTRY_WORDS = TT_WAYS*WAY_WORDS;
    localparam int ENTRY_BITS = TT_WAYS*WAY_BITS;
    localparam int WORD_COUNT_BITS = $clog2(ENTRY_WORDS+1);
    typedef logic [ENTRY_INDEX_BITS-1:0] EntryIndex;
    typedef logic [BANK_INDEX_BITS-1:0] CacheIndex;
    typedef logic [CACHE_TAG_BITS-1:0] CacheTag;
    typedef logic [WAY_BITS-1:0] PhysicalWay;
    typedef logic [ENTRY_BITS-1:0] PhysicalEntry;
    typedef struct packed {
        TTAge age;
        TTDepth depth;
        EvalScore score;
        TTMoveBits best_move_bits;
        logic [TAG_BITS-1:0] tag;
        TTBoundType bound_type;
    } Way;
    typedef logic [$clog2(TT_WAYS)-1:0] MemoryWayIndex;
    typedef struct packed { CacheTag entry_tag; MemoryWayIndex memory_way; Way data; } CacheWay;
    typedef CacheWay [1:0] CacheSet;
    typedef struct packed { logic hit; logic slot; CacheWay way; } CacheMatch;
    typedef struct packed { EntryIndex index; CacheWay way; logic store; } CacheFill;
    typedef struct packed { TTLookupRequest req; EntryIndex index; } ProbeTarget;
    typedef struct packed { TTStoreRequest req; EntryIndex index; } StoreTarget;
    typedef enum logic [1:0] { S_IDLE, S_DRAIN, S_CLEAR_WAIT, S_CACHE_CLEAR } State;
    State state;
    CacheIndex clear_index;
    logic clear_slot;
    logic clear_toggle, clear_ack, transport_idle;
    logic clear_prev;
    logic active;
    logic probe_pending, store_pending;
    ProbeTarget probe_stage;
    logic probe_buffer_valid, probe_accept;
    TTLookupRequest probe_buffer;
    StoreTarget store_stage;
    CacheSet bank_read[2];
    logic [1:0] bank_read_enable, bank_write_enable, bank_write_slot;
    CacheIndex bank_read_index[2], bank_write_index[2];
    CacheWay bank_write_way[2];
    logic [1:0] bank_read_lru, bank_lru_write_enable, bank_lru_write_value;
    CacheIndex bank_lru_write_index[2];
    logic [1:0] bank_fill_issue, bank_fill_pending, bank_fill_write;
    CacheFill bank_fill_input[2], bank_fill_stage[2];
    CacheMatch bank_fill_match[2];
    logic [1:0] bank_fill_slot;
    logic probe_issue, store_issue;
    EntryIndex probe_index, store_index;
    logic probe_position_hit, store_position_hit;
    CacheMatch probe_match, store_match;
    logic probe_enqueue, store_enqueue;
    logic probe_transport_ready, store_transport_ready;
    logic probe_meta_ready, store_meta_ready, probe_meta_valid, store_meta_valid;
    ProbeTarget probe_meta;
    StoreTarget store_meta;
    logic [$clog2(OUTSTANDING_DEPTH+1)-1:0] probe_meta_count, store_meta_count;
    logic probe_complete, store_complete;
    // Reuse one way comparison while retaining the full group for cache fill.
    PhysicalWay probe_next_way;
    logic [$clog2(WAY_WORDS+1)-1:0] probe_way_word_count;
    logic probe_way_last, probe_returned;
    TTLookupResponse probe_stream_response;
    PhysicalWay probe_way_buffer;
    MemoryWayIndex probe_memory_way;
    PhysicalEntry store_entry;
    logic [WORD_COUNT_BITS-1:0] probe_word_count, store_word_count;
    logic probe_word_valid, store_word_valid, probe_word_ready, store_word_ready;
    logic [TT_WORD_BITS-1:0] probe_word, store_word;
    logic probe_finish, store_finish;
    logic fill_valid;
    EntryIndex fill_index;
    CacheWay fill_way;
    logic fill_issue;
    logic store_fill_valid, store_fill_issue;
    EntryIndex store_fill_index;
    CacheWay store_fill_way;
    TTStoreRequest store_fifo_data;
    logic store_fifo_valid, store_fifo_push_ready, store_pop, store_accept;
    logic [$clog2(STORE_FIFO_DEPTH+1)-1:0] store_fifo_count;
    logic store_buffer_valid;
    StoreTarget store_buffer;
    logic replacement_valid, replacement_cache, replacement_matches, replacement_write;
    logic [$clog2(TT_WAYS)-1:0] replacement_way;
    PhysicalEntry replacement_old;
    PhysicalWay replacement_new, replacement_updated;
    StoreTarget replacement_target;
    logic way_write_ready;
    // Pipeline the cache comparison and publication to keep RAM and replacement
    // paths independent while retaining one shared replacement datapath.
    logic cache_store_valid;
    StoreTarget cache_store_target;
    CacheWay cache_store_way;
    logic cache_store_slot;
    logic commit_valid;
    StoreTarget commit_target;
    logic commit_cache, commit_slot;
    PhysicalWay commit_way;
    logic [$clog2(TT_WAYS)-1:0] commit_way_index;

    // Both banks read two candidates together and write only one individual way.
    genvar bank;
    generate for (bank = 0; bank < 2; bank++) begin : cache_banks
        tt_cache_bank #(.WAY_BITS($bits(CacheWay)), .INDEX_BITS(BANK_INDEX_BITS)) cache_bank (
            .clk(clk), .read_enable(bank_read_enable[bank]), .read_index(bank_read_index[bank]), .read_set(bank_read[bank]),
            .read_lru(bank_read_lru[bank]), .write_enable(bank_write_enable[bank]), .write_index(bank_write_index[bank]),
            .write_slot(bank_write_slot[bank]), .write_way(bank_write_way[bank]),
            .lru_write_enable(bank_lru_write_enable[bank]), .lru_write_index(bank_lru_write_index[bank]),
            .lru_write_value(bank_lru_write_value[bank]));
    end endgenerate

    // Split the external entry space evenly; bit 63 exclusively chooses the bank.
    function automatic EntryIndex entry_index(input ZobristKey key);
        logic [TT_HASH_BITS+ENTRY_INDEX_BITS-1:0] product;
        ZobristKey index_key;
        index_key = key; index_key[$bits(ZobristKey)-1] = 1'b0;
        product = tt_index_hash(index_key, TAG_BITS) * (ENTRY_COUNT/2);
        return (EntryIndex'(product >> TT_HASH_BITS) << 1) | EntryIndex'(key[$bits(ZobristKey)-1]);
    endfunction
    // Derive the cache set from the external index; positions in a group share a set.
    function automatic CacheIndex cache_index(input EntryIndex index);
        return CacheIndex'(index >> 1);
    endfunction
    // Bank and set already identify the low external-entry index bits.
    function automatic CacheTag cache_tag(input EntryIndex index);
        return CacheTag'(index >> CACHE_INDEX_BITS);
    endfunction
    // Both the external-entry identity and position tag must match a cache candidate.
    function automatic CacheMatch cache_match(input CacheSet candidates, input EntryIndex index,
        input logic [TAG_BITS-1:0] position_tag);
        CacheMatch result;
        result = '0;
        for (int slot = 0; slot < 2; slot++) begin
            if (!result.hit && candidates[slot].data.bound_type != TT_BOUND_INVALID
                    && candidates[slot].entry_tag == cache_tag(index) && candidates[slot].data.tag == position_tag) begin
                result.hit = 1'b1; result.slot = 1'(slot); result.way = candidates[slot];
            end
        end
        return result;
    endfunction
    // The search producer already omits underpromotion moves using its board.
    function automatic PhysicalWay make_way(input TTStoreRequest req);
        Way way;
        way.age = req.age; way.depth = req.depth;
        way.score = tt_normalize_mate_score(req.score, req.ply);
        way.best_move_bits = tt_encode_move(req.best_move);
        way.tag = TAG_BITS'(req.zobrist_key); way.bound_type = req.bound_type;
        return PhysicalWay'(way);
    endfunction
    // A streaming probe uses this single-way comparison and payload decoder.
    function automatic TTLookupResponse way_response(input TTLookupRequest req, input PhysicalWay physical_way);
        TTLookupResponse result;
        Way way;
        result = '0; result.thread_id = req.thread_id; result.best_move = NULL_MOVE;
        way = Way'(physical_way);
        if (way.bound_type != TT_BOUND_INVALID && way.tag == TAG_BITS'(req.zobrist_key)) begin
            result.hit = 1'b1; result.score = tt_restore_mate_score(way.score, req.ply);
            result.bound_type = way.bound_type; result.depth = way.depth;
            result.best_move = tt_decode_move(way.best_move_bits);
        end
        return result;
    endfunction
    // Cache-hit stores own the single replacement datapath before memory stores.
    always_comb begin
        active = state == S_IDLE && !clear && memory_ready && !memory_error;
        clear_busy = state != S_IDLE || clear;
        probe_index = entry_index(probe_buffer.zobrist_key);
        store_index = store_buffer.index;
        probe_match = cache_match(bank_read[probe_stage.index[0]], probe_stage.index, TAG_BITS'(probe_stage.req.zobrist_key));
        store_match = cache_match(bank_read[store_stage.index[0]], store_stage.index, TAG_BITS'(store_stage.req.zobrist_key));
        probe_position_hit = probe_match.hit;
        store_position_hit = store_match.hit;
        // Include the arriving final word so a way can respond on its acceptance edge.
        probe_next_way = {probe_word, probe_way_buffer[WAY_BITS-1:TT_WORD_BITS]};
        probe_way_last = int'(probe_way_word_count) == WAY_WORDS-1;
        probe_stream_response = way_response(probe_meta.req, probe_next_way);
        // Register thread selection before address hashing and the bank RAM.
        // Accepted probes also drain during New Game before memory is cleared.
        probe_issue = (state == S_IDLE || state == S_DRAIN)
            && memory_ready && !memory_error && probe_buffer_valid && !probe_complete
            // Let the previous cache read retire, then give the stream a response slot.
            && !(probe_word_valid && probe_way_last && !probe_returned);
        lookup_req_ready = active && (!probe_buffer_valid || probe_issue);
        probe_accept = lookup_req_valid && lookup_req_ready;
        store_req_ready = active;
        store_accept = store_req_valid && store_req_ready;
        store_pop = active && !store_buffer_valid && store_fifo_valid;
        // Advertise a store held by the current probe: it will still need a
        // read when the newly selected probe reaches the registered bank input.
        store_bank_valid = active && store_buffer_valid && probe_issue
            && probe_index[0] == store_index[0];
        store_bank = store_index[0];
        store_issue = active && store_buffer_valid && (!probe_issue || probe_index[0] != store_index[0]);
        probe_enqueue = probe_pending && !probe_position_hit && probe_transport_ready && probe_meta_ready;
        store_enqueue = store_pending && !store_position_hit && store_transport_ready && store_meta_ready;
        probe_finish = probe_complete && !probe_pending && probe_meta_valid;
        replacement_cache = cache_store_valid;
        replacement_valid = replacement_cache || (store_complete && store_meta_valid);
        replacement_target = replacement_cache ? cache_store_target : store_meta;
        // A cache hit supplies only its matching way; external misses supply all three.
        replacement_old = replacement_cache ? PhysicalEntry'(PhysicalWay'(cache_store_way.data)) : store_entry;
        replacement_new = make_way(replacement_target.req);
        store_finish = replacement_valid && !replacement_cache;
        // Cache results own the response port; hold only an unanswered way boundary.
        probe_word_ready = !probe_complete && probe_meta_valid
            && (probe_returned || !probe_way_last || !probe_pending);
        store_word_ready = !store_complete;
        bank_read_enable = '0; bank_write_enable = '0; bank_write_slot = '0;
        bank_fill_issue = '0; bank_fill_write = '0;
        bank_lru_write_enable = '0; bank_lru_write_value = '0;
        fill_issue = 1'b0; store_fill_issue = 1'b0;
        for (int b = 0; b < 2; b++) begin
            bank_read_index[b] = cache_index(store_index);
            bank_write_index[b] = cache_index(bank_fill_stage[b].index);
            bank_write_way[b] = bank_fill_stage[b].way;
            bank_lru_write_index[b] = cache_index(bank_fill_stage[b].index);
            bank_fill_input[b] = '0;
            // Admission reads never steal an engine probe/store read slot.
            if (store_issue && store_index[0] == b) bank_read_enable[b] = 1'b1;
            if (probe_issue && probe_index[0] == b) begin
                bank_read_enable[b] = 1'b1; bank_read_index[b] = cache_index(probe_index);
            end
            if (!bank_read_enable[b] && store_fill_valid && store_fill_index[0] == b) begin
                bank_read_enable[b] = 1'b1; bank_read_index[b] = cache_index(store_fill_index);
                bank_fill_issue[b] = 1'b1; store_fill_issue = 1'b1;
                bank_fill_input[b] = CacheFill'({store_fill_index, store_fill_way, 1'b1});
            end else if (!bank_read_enable[b] && fill_valid && fill_index[0] == b) begin
                bank_read_enable[b] = 1'b1; bank_read_index[b] = cache_index(fill_index);
                bank_fill_issue[b] = 1'b1; fill_issue = 1'b1;
                bank_fill_input[b] = CacheFill'({fill_index, fill_way, 1'b0});
            end
            // Update an existing position, otherwise prefer empty slots before the LRU.
            bank_fill_match[b] = cache_match(bank_read[b], bank_fill_stage[b].index, bank_fill_stage[b].way.data.tag);
            bank_fill_slot[b] = bank_fill_match[b].hit ? bank_fill_match[b].slot
                : bank_read[b][0].data.bound_type == TT_BOUND_INVALID ? 1'b0
                : bank_read[b][1].data.bound_type == TT_BOUND_INVALID ? 1'b1 : bank_read_lru[b];
            // Cache-hit stores own publication; blocked admissions are best-effort.
            bank_fill_write[b] = bank_fill_pending[b]
                && !(commit_valid && commit_cache && (bank_fill_stage[b].store || commit_target.index[0] == b));
            if (bank_fill_write[b]) begin
                bank_write_enable[b] = 1'b1; bank_write_slot[b] = bank_fill_slot[b];
                bank_lru_write_enable[b] = 1'b1; bank_lru_write_value[b] = !bank_fill_slot[b];
            end
            if (commit_valid && commit_cache && commit_target.index[0] == b) begin
                bank_write_enable[b] = 1'b1; bank_write_index[b] = cache_index(commit_target.index);
                bank_write_slot[b] = commit_slot;
                bank_write_way[b] = CacheWay'({cache_tag(commit_target.index), commit_way_index, Way'(commit_way)});
            end
            // Only one read retires per bank, so touches need no second LRU write port.
            if (probe_pending && probe_stage.index[0] == b && probe_position_hit) begin
                bank_lru_write_enable[b] = 1'b1; bank_lru_write_index[b] = cache_index(probe_stage.index);
                bank_lru_write_value[b] = !probe_match.slot;
            end
            if (store_pending && store_stage.index[0] == b && store_position_hit) begin
                bank_lru_write_enable[b] = 1'b1; bank_lru_write_index[b] = cache_index(store_stage.index);
                bank_lru_write_value[b] = !store_match.slot;
            end
            if (state == S_CACHE_CLEAR) begin
                bank_write_enable[b] = 1'b1; bank_write_index[b] = clear_index;
                bank_write_slot[b] = clear_slot; bank_write_way[b] = '0;
                bank_lru_write_enable[b] = 1'b1; bank_lru_write_index[b] = clear_index; bank_lru_write_value[b] = 1'b0;
            end
        end
    end

    tt_replacement #(.TAG_BITS(TAG_BITS), .WAY_BITS(WAY_BITS), .STALE_DEPTH_TOLERANCE(STALE_DEPTH_TOLERANCE)) replacement (
        .old_entry(replacement_old), .new_way(replacement_new), .position_matches(replacement_matches),
        .replace(replacement_write), .selected_way(replacement_way), .updated_way(replacement_updated));

    // Metadata never leaves the engine clock domain and is queued with each miss.
    synchronous_fifo #(.DATA_WIDTH($bits(ProbeTarget)), .DEPTH(OUTSTANDING_DEPTH)) probe_targets (
        .clk(clk), .rst_n(rst_n), .clear(1'b0), .push_valid(probe_enqueue), .push_ready(probe_meta_ready),
        .push_data(probe_stage), .pop_valid(probe_meta_valid), .pop_ready(probe_finish), .pop_data(probe_meta), .count(probe_meta_count));
    synchronous_fifo #(.DATA_WIDTH($bits(StoreTarget)), .DEPTH(OUTSTANDING_DEPTH)) store_targets (
        .clk(clk), .rst_n(rst_n), .clear(1'b0), .push_valid(store_enqueue), .push_ready(store_meta_ready),
        .push_data(store_stage), .pop_valid(store_meta_valid), .pop_ready(store_finish), .pop_data(store_meta), .count(store_meta_count));
    synchronous_fifo #(.DATA_WIDTH($bits(TTStoreRequest)), .DEPTH(STORE_FIFO_DEPTH)) stores (
        .clk(clk), .rst_n(rst_n), .clear(clear), .push_valid(store_accept), .push_ready(store_fifo_push_ready),
        .push_data(store_req), .pop_valid(store_fifo_valid), .pop_ready(store_pop), .pop_data(store_fifo_data), .count(store_fifo_count));

    tt_memory_cdc_bridge #(.WAY_BITS(WAY_BITS), .ENTRY_COUNT(ENTRY_COUNT),
        .READ_FIFO_DEPTH(OUTSTANDING_DEPTH), .WRITE_FIFO_DEPTH(WRITEBACK_FIFO_DEPTH),
        .RESPONSE_FIFO_DEPTH(RESPONSE_FIFO_DEPTH)) transport (
        .req_clk(clk), .req_rst_n(rst_n), .mem_clk(memory_clk), .mem_rst_n(memory_rst_n),
        .clear_toggle(clear_toggle), .clear_ack(clear_ack), .idle(transport_idle),
        .probe_valid(probe_enqueue), .probe_ready(probe_transport_ready), .probe_entry_index(probe_stage.index),
        .probe_response_valid(probe_word_valid), .probe_response_ready(probe_word_ready), .probe_response_data(probe_word),
        .store_valid(store_enqueue), .store_ready(store_transport_ready), .store_entry_index(store_stage.index),
        .store_response_valid(store_word_valid), .store_response_ready(store_word_ready), .store_response_data(store_word),
        .write_valid(commit_valid), .write_ready(way_write_ready),
        .write_entry_index(commit_target.index), .write_way_index(commit_way_index), .write_way(commit_way),
        .backend_req_valid(mem_req_valid), .backend_req_ready(mem_req_ready), .backend_req_write(mem_req_write),
        .backend_req_address(mem_req_address), .backend_req_length(mem_req_length),
        .backend_write_valid(mem_write_valid), .backend_write_ready(mem_write_ready), .backend_write_data(mem_write_data), .backend_write_last(mem_write_last),
        .backend_read_valid(mem_read_valid), .backend_read_ready(mem_read_ready), .backend_read_data(mem_read_data), .backend_read_last(mem_read_last),
        .backend_done_valid(mem_done_valid), .backend_done_ready(mem_done_ready), .backend_done_error(mem_done_error));

    // Cache reads retire every cycle; full miss queues return/drop without stalling.
    always_ff @(posedge clk) begin
        if (!rst_n) begin
            cache_store_valid <= 1'b0; commit_valid <= 1'b0;
            state <= S_CACHE_CLEAR; clear_index <= '0; clear_slot <= 1'b0; clear_toggle <= 1'b0; clear_prev <= 1'b0;
            probe_buffer_valid <= 1'b0; probe_buffer <= '0;
            probe_pending <= 1'b0; store_pending <= 1'b0; store_buffer_valid <= 1'b0;
            probe_complete <= 1'b0; store_complete <= 1'b0;
            probe_way_word_count <= '0; probe_returned <= 1'b0; probe_memory_way <= '0;
            probe_word_count <= '0; store_word_count <= '0; fill_valid <= 1'b0;
            store_fill_valid <= 1'b0; bank_fill_pending <= '0;
            lookup_resp_valid <= 1'b0; lookup_resp <= '0;
            cache_access <= 1'b0; cache_hit <= 1'b0; cache_store_access <= 1'b0; cache_store_hit <= 1'b0;
        end else begin
            cache_store_valid <= store_pending && store_position_hit;
            if (store_pending && store_position_hit) begin
                cache_store_target <= store_stage;
                cache_store_way <= store_match.way; cache_store_slot <= store_match.slot;
            end
            commit_valid <= replacement_valid && replacement_write;
            if (replacement_valid && replacement_write) begin
                commit_target <= replacement_target; commit_cache <= replacement_cache;
                commit_slot <= cache_store_slot; commit_way <= replacement_updated;
                commit_way_index <= replacement_cache ? cache_store_way.memory_way : replacement_way;
            end
            clear_prev <= clear;
            lookup_resp_valid <= 1'b0; cache_access <= 1'b0; cache_hit <= 1'b0;
            cache_store_access <= 1'b0; cache_store_hit <= 1'b0;
            probe_pending <= probe_issue; store_pending <= store_issue;
            if (store_pop) begin
                store_buffer.req <= store_fifo_data; store_buffer.index <= entry_index(store_fifo_data.zobrist_key);
                store_buffer_valid <= 1'b1;
            end
            if (store_issue) begin store_stage <= store_buffer; store_buffer_valid <= 1'b0; end
            if (probe_issue) probe_buffer_valid <= 1'b0;
            if (probe_accept) begin probe_buffer <= lookup_req; probe_buffer_valid <= 1'b1; end
            if (probe_issue) begin probe_stage.req <= probe_buffer; probe_stage.index <= probe_index; end
            if (clear) store_buffer_valid <= 1'b0;
            if (probe_pending) begin
                cache_access <= 1'b1; cache_hit <= probe_position_hit;
                if (probe_position_hit || !probe_enqueue) begin
                    lookup_resp <= way_response(probe_stage.req, probe_position_hit ? PhysicalWay'(probe_match.way.data) : PhysicalWay'(0));
                    lookup_resp_valid <= 1'b1;
                end
            end
            if (store_pending) begin
                cache_store_access <= 1'b1; cache_store_hit <= store_position_hit;
            end
            // Retry a preempted admission unless a newer buffered fill supersedes it.
            if (fill_issue) fill_valid <= 1'b0;
            if (store_fill_issue) store_fill_valid <= 1'b0;
            for (int b = 0; b < 2; b++) begin
                if (bank_fill_pending[b] && !bank_fill_write[b]) begin
                    if (bank_fill_stage[b].store && (!store_fill_valid || store_fill_issue)) begin
                        store_fill_valid <= 1'b1; store_fill_index <= bank_fill_stage[b].index;
                        store_fill_way <= bank_fill_stage[b].way;
                    end else if (!bank_fill_stage[b].store && (!fill_valid || fill_issue)) begin
                        fill_valid <= 1'b1; fill_index <= bank_fill_stage[b].index; fill_way <= bank_fill_stage[b].way;
                    end
                end
            end
            if (probe_word_valid && probe_word_ready) begin
                // Low words arrive first; the high slice holds the latest complete way.
                probe_way_buffer <= probe_next_way;
                if (probe_way_last) begin
                    probe_way_word_count <= '0; probe_memory_way <= probe_memory_way + 1'b1;
                    if (!probe_returned && (probe_stream_response.hit || int'(probe_word_count) == ENTRY_WORDS-1)) begin
                        lookup_resp <= probe_stream_response; lookup_resp_valid <= 1'b1;
                        probe_returned <= 1'b1;
                        // Cache only the useful complete way, independently of the response tail.
                        if (probe_stream_response.hit) begin
                            fill_valid <= 1'b1; fill_index <= probe_meta.index;
                            fill_way <= CacheWay'({cache_tag(probe_meta.index), probe_memory_way, Way'(probe_next_way)});
                        end
                    end
                end else probe_way_word_count <= probe_way_word_count + 1'b1;
                if (int'(probe_word_count) == ENTRY_WORDS-1) begin probe_complete <= 1'b1; probe_word_count <= '0; end
                else probe_word_count <= probe_word_count + 1'b1;
            end
            if (store_word_valid && store_word_ready) begin
                store_entry[store_word_count*TT_WORD_BITS +: TT_WORD_BITS] <= store_word;
                if (int'(store_word_count) == ENTRY_WORDS-1) begin store_complete <= 1'b1; store_word_count <= '0; end
                else store_word_count <= store_word_count + 1'b1;
            end
            if (store_finish) store_complete <= 1'b0;
            // New publications supersede an older buffered or preempted store admission.
            if (commit_valid && !commit_cache) begin
                store_fill_valid <= 1'b1; store_fill_index <= commit_target.index;
                store_fill_way <= CacheWay'({cache_tag(commit_target.index), commit_way_index, Way'(commit_way)});
            end
            for (int b = 0; b < 2; b++) begin
                bank_fill_pending[b] <= bank_fill_issue[b];
                if (bank_fill_issue[b]) bank_fill_stage[b] <= bank_fill_input[b];
            end
            if (probe_finish) begin
                // Keep metadata until all words drain, even after an early hit.
                probe_returned <= 1'b0; probe_memory_way <= '0; probe_complete <= 1'b0;
            end
            case (state)
                S_IDLE: if (clear && !clear_prev) state <= S_DRAIN;
                S_DRAIN: if (!probe_buffer_valid && !probe_pending && !store_pending && !cache_store_valid && !commit_valid && probe_meta_count == 0
                        && store_meta_count == 0 && transport_idle && !fill_valid && !store_fill_valid && bank_fill_pending == 0) begin
                    clear_toggle <= !clear_toggle; state <= S_CLEAR_WAIT;
                end
                S_CLEAR_WAIT: if (clear_ack == clear_toggle) begin clear_index <= '0; clear_slot <= 1'b0; state <= S_CACHE_CLEAR; end
                S_CACHE_CLEAR: begin
                    clear_slot <= !clear_slot;
                    if (clear_slot) begin
                        if (int'(clear_index) == BANK_SET_COUNT-1) state <= S_IDLE;
                        else clear_index <= clear_index + 1'b1;
                    end
                end
                default: state <= S_IDLE;
            endcase
        end
    end
`ifndef SYNTHESIS
    initial begin
        if (CACHE_INDEX_BITS < 2 || TAG_BITS < 1 || TAG_BITS >= $bits(ZobristKey)
                || ENTRY_COUNT < 2 || ENTRY_COUNT % 2 != 0)
            $fatal(1, "TT requires two cache banks, a legal tag width, and an even entry count");
        if (ENTRY_COUNT*ENTRY_WORDS > TT_EXTERNAL_WORD_COUNT)
            $fatal(1, "TT entries exceed external memory capacity");
    end
`endif
endmodule
