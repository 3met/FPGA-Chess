// By Emet Behrendt

import general_chess_defs::*;
import tt_defs::*;

module tt_load_store #(
    parameter int TT_INDEX_BITS = 10,
    parameter int STORE_FIFO_DEPTH = 4,
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

    input logic store_req_valid,
    output logic store_req_ready,
    input var TTStoreRequest store_req
);

    localparam int TT_ENTRY_COUNT = 1 << TT_INDEX_BITS;
    localparam int STORAGE_ENTRY_BITS = USE_FULL_KEY ? $bits(TTFullEntry) : $bits(TTEntry);
    localparam int FIFO_COUNT_BITS = $clog2(STORE_FIFO_DEPTH + 1);
    localparam int FIFO_PTR_BITS = (STORE_FIFO_DEPTH > 1) ? $clog2(STORE_FIFO_DEPTH) : 1;

    typedef logic [TT_INDEX_BITS-1:0] TTIndex;
    typedef logic [STORAGE_ENTRY_BITS-1:0] TTStorageEntry;
    typedef logic [FIFO_COUNT_BITS-1:0] StoreFifoCount;
    typedef logic [FIFO_PTR_BITS-1:0] StoreFifoPtr;

    typedef enum logic [1:0] {
        STORE_IDLE,
        STORE_WRITE,
        STORE_RETRY
    } StoreState;

    StoreState store_state;
    TTStoreRequest active_store_req;
    TTStorageEntry active_store_old_entry;
    TTIndex active_store_index;
    TTLookupRequest active_lookup_req;

    TTStoreRequest store_fifo[0:STORE_FIFO_DEPTH-1];
    StoreFifoCount store_fifo_count;
    StoreFifoPtr store_fifo_head;
    StoreFifoPtr store_fifo_tail;

    logic clear_active;
    TTIndex clear_index;
    logic clear_prev;
    logic clear_start;
    logic lookup_accept;
    logic store_accept;
    logic store_pop_frees_slot;
    logic mem_read_enable;
    logic mem_write_enable;
    TTIndex mem_read_address;
    TTIndex mem_write_address;
    TTStorageEntry mem_write_data;
    TTStorageEntry mem_read_data;

    assign clear_start = clear && !clear_prev && !clear_active;
    assign clear_busy = clear_start || clear_active;
    assign lookup_req_ready = !clear_start && !clear_active;
    assign lookup_accept = lookup_req_valid && lookup_req_ready;
    assign store_pop_frees_slot = !lookup_accept && (store_state == STORE_IDLE) && (store_fifo_count != StoreFifoCount'(0));
    assign store_req_ready = !clear_start && !clear_active
        && ((store_fifo_count < StoreFifoCount'(STORE_FIFO_DEPTH)) || store_pop_frees_slot);
    assign store_accept = store_req_valid && store_req_ready;

    function automatic TTIndex tt_index(input ZobristKey zobrist_key);
        return TTIndex'(zobrist_key[TT_INDEX_BITS-1:0]);
    endfunction : tt_index

    function automatic StoreFifoPtr next_store_fifo_ptr(input StoreFifoPtr ptr);
        if (ptr == StoreFifoPtr'(STORE_FIFO_DEPTH - 1)) begin
            return StoreFifoPtr'(0);
        end

        return ptr + StoreFifoPtr'(1);
    endfunction : next_store_fifo_ptr

    function automatic EvalScore normalize_mate_for_store(input EvalScore score, input PlyIndex ply);
        automatic int signed adjusted;

        if (score >= MATE_THRESHOLD) begin
            adjusted = int'(score) + int'(ply);
            return EvalScore'(adjusted);
        end

        if (score <= -MATE_THRESHOLD) begin
            adjusted = int'(score) - int'(ply);
            return EvalScore'(adjusted);
        end

        return score;
    endfunction : normalize_mate_for_store

    function automatic EvalScore restore_mate_for_lookup(input EvalScore score, input PlyIndex ply);
        automatic int signed adjusted;

        if (score >= MATE_THRESHOLD) begin
            adjusted = int'(score) - int'(ply);
            return EvalScore'(adjusted);
        end

        if (score <= -MATE_THRESHOLD) begin
            adjusted = int'(score) + int'(ply);
            return EvalScore'(adjusted);
        end

        return score;
    endfunction : restore_mate_for_lookup

    function automatic TTStorageEntry invalid_storage_entry();
        if (USE_FULL_KEY) begin
            return TTStorageEntry'(tt_invalid_full_entry());
        end

        return TTStorageEntry'(tt_invalid_entry());
    endfunction : invalid_storage_entry

    function automatic TTStorageEntry make_storage_entry(input TTStoreRequest req);
        if (USE_FULL_KEY) begin
            return TTStorageEntry'(tt_make_full_entry(
                req.zobrist_key,
                req.best_move,
                normalize_mate_for_store(req.score, req.ply),
                req.depth,
                req.bound_type,
                req.age,
                TTAux'(0)
            ));
        end

        return TTStorageEntry'(tt_make_entry(
            req.zobrist_key,
            req.best_move,
            normalize_mate_for_store(req.score, req.ply),
            req.depth,
            req.bound_type,
            req.age
        ));
    endfunction : make_storage_entry

    function automatic TTBoundType storage_bound_type(input TTStorageEntry entry);
        if (USE_FULL_KEY) begin
            automatic TTFullEntry full_entry;

            full_entry = TTFullEntry'(entry);
            return full_entry.bound_type;
        end

        begin
            automatic TTEntry compact_entry;

            compact_entry = TTEntry'(entry);
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
            automatic TTEntry compact_entry;

            compact_entry = TTEntry'(entry);
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
            automatic TTEntry compact_entry;

            compact_entry = TTEntry'(entry);
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
            automatic TTEntry compact_entry;

            compact_entry = TTEntry'(entry);
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
            automatic TTEntry compact_entry;

            compact_entry = TTEntry'(entry);
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
            automatic TTEntry compact_entry;

            compact_entry = TTEntry'(entry);
            return compact_entry.verify_key == tt_verify_key(zobrist_key);
        end
    endfunction : storage_key_matches

    function automatic TTLookupResponse make_lookup_response(input TTLookupRequest req, input TTStorageEntry entry);
        automatic TTLookupResponse resp;
        automatic logic entry_hit;

        entry_hit = (storage_bound_type(entry) != TT_BOUND_INVALID) && storage_key_matches(entry, req.zobrist_key);

        resp.thread_id = req.thread_id;
        resp.hit = entry_hit;
        resp.score = entry_hit ? restore_mate_for_lookup(storage_score(entry), req.ply) : UNKNOWN_EVAL_SCORE;
        resp.bound_type = entry_hit ? storage_bound_type(entry) : TT_BOUND_INVALID;
        resp.depth = entry_hit ? storage_depth(entry) : TTDepth'(0);
        resp.best_move = entry_hit ? storage_best_move(entry) : NULL_MOVE;
        return resp;
    endfunction : make_lookup_response

    function automatic logic should_replace(input TTStorageEntry old_entry, input TTStoreRequest req);
        automatic logic old_invalid;
        automatic logic key_mismatch;
        automatic logic stale_with_depth_window;
        automatic logic new_deeper_or_equal;
        automatic logic exact_over_non_exact;

        old_invalid = storage_bound_type(old_entry) == TT_BOUND_INVALID;
        key_mismatch = !storage_key_matches(old_entry, req.zobrist_key);
        stale_with_depth_window = (storage_age(old_entry) != req.age) && ((int'(req.depth) + 4) >= int'(storage_depth(old_entry)));
        new_deeper_or_equal = req.depth >= storage_depth(old_entry);
        exact_over_non_exact = (req.bound_type == TT_BOUND_EXACT)
            && (storage_bound_type(old_entry) != TT_BOUND_EXACT)
            && (req.depth == storage_depth(old_entry));

        return old_invalid || key_mismatch || stale_with_depth_window || new_deeper_or_equal || exact_over_non_exact;
    endfunction : should_replace

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
                    if (store_fifo_count != StoreFifoCount'(0)) begin
                        mem_read_enable = 1'b1;
                        mem_read_address = tt_index(store_fifo[store_fifo_head].zobrist_key);
                    end else if (store_accept) begin
                        mem_read_enable = 1'b1;
                        mem_read_address = tt_index(store_req.zobrist_key);
                    end
                end

                STORE_WRITE: begin
                    if (should_replace(mem_read_data, active_store_req)) begin
                        mem_write_enable = 1'b1;
                        mem_write_address = active_store_index;
                        mem_write_data = make_storage_entry(active_store_req);
                    end
                end

                STORE_RETRY: begin
                    if (should_replace(active_store_old_entry, active_store_req)) begin
                        mem_write_enable = 1'b1;
                        mem_write_address = active_store_index;
                        mem_write_data = make_storage_entry(active_store_req);
                    end
                end

                default: begin
                end
            endcase
        end
    end

    synchronous_simple_dual_port_ram #(
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
            store_fifo_count <= StoreFifoCount'(0);
            store_fifo_head <= StoreFifoPtr'(0);
            store_fifo_tail <= StoreFifoPtr'(0);
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
                store_fifo_count <= StoreFifoCount'(0);
                store_fifo_head <= StoreFifoPtr'(0);
                store_fifo_tail <= StoreFifoPtr'(0);
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
                        active_store_old_entry <= mem_read_data;
                        store_state <= STORE_RETRY;
                    end

                    if (store_accept) begin
                        store_fifo[store_fifo_tail] <= store_req;
                        store_fifo_tail <= next_store_fifo_ptr(store_fifo_tail);
                        store_fifo_count <= store_fifo_count + StoreFifoCount'(1);
                    end
                end else begin
                    case (store_state)
                        STORE_IDLE: begin
                            if (store_fifo_count != StoreFifoCount'(0)) begin
                                active_store_req <= store_fifo[store_fifo_head];
                                active_store_index <= tt_index(store_fifo[store_fifo_head].zobrist_key);
                                store_fifo_head <= next_store_fifo_ptr(store_fifo_head);

                                if (store_accept) begin
                                    store_fifo[store_fifo_tail] <= store_req;
                                    store_fifo_tail <= next_store_fifo_ptr(store_fifo_tail);
                                end else begin
                                    store_fifo_count <= store_fifo_count - StoreFifoCount'(1);
                                end

                                store_state <= STORE_WRITE;
                            end else if (store_accept) begin
                                active_store_req <= store_req;
                                active_store_index <= tt_index(store_req.zobrist_key);
                                store_state <= STORE_WRITE;
                            end
                        end

                        STORE_WRITE: begin
                            store_state <= STORE_IDLE;

                            if (store_accept) begin
                                store_fifo[store_fifo_tail] <= store_req;
                                store_fifo_tail <= next_store_fifo_ptr(store_fifo_tail);
                                store_fifo_count <= store_fifo_count + StoreFifoCount'(1);
                            end
                        end

                        STORE_RETRY: begin
                            store_state <= STORE_IDLE;

                            if (store_accept) begin
                                store_fifo[store_fifo_tail] <= store_req;
                                store_fifo_tail <= next_store_fifo_ptr(store_fifo_tail);
                                store_fifo_count <= store_fifo_count + StoreFifoCount'(1);
                            end
                        end
                    endcase
                end
            end
        end
    end

endmodule : tt_load_store
