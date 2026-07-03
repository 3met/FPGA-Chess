// By Emet Behrendt

import general_chess_defs::*;
import tt_defs::*;

module tt_load_store #(
    parameter int TT_INDEX_BITS = 10,
    parameter int STORE_FIFO_DEPTH = 4
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
    localparam int FIFO_COUNT_BITS = $clog2(STORE_FIFO_DEPTH + 1);
    localparam int FIFO_PTR_BITS = (STORE_FIFO_DEPTH > 1) ? $clog2(STORE_FIFO_DEPTH) : 1;

    typedef logic [TT_INDEX_BITS-1:0] TTIndex;
    typedef logic [FIFO_COUNT_BITS-1:0] StoreFifoCount;
    typedef logic [FIFO_PTR_BITS-1:0] StoreFifoPtr;

    typedef enum logic {
        STORE_IDLE,
        STORE_WRITE
    } StoreState;

    TTEntry mem[0:TT_ENTRY_COUNT-1];

    TTLookupResponse lookup_resp_reg;
    StoreState store_state;
    TTStoreRequest active_store_req;
    TTEntry active_store_old_entry;
    TTIndex active_store_index;

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

    assign clear_start = clear && !clear_prev && !clear_active;
    assign clear_busy = clear_start || clear_active;
    assign lookup_req_ready = !clear_start && !clear_active;
    assign lookup_accept = lookup_req_valid && lookup_req_ready;
    assign store_pop_frees_slot = !lookup_accept && (store_state == STORE_IDLE) && (store_fifo_count != StoreFifoCount'(0));
    assign store_req_ready = !clear_start && !clear_active
        && ((store_fifo_count < StoreFifoCount'(STORE_FIFO_DEPTH)) || store_pop_frees_slot);
    assign store_accept = store_req_valid && store_req_ready;
    assign lookup_resp = lookup_resp_reg;

    initial begin
        for (int idx = 0; idx < TT_ENTRY_COUNT; idx++) begin
            mem[idx] = tt_invalid_entry();
        end
    end

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

    function automatic TTLookupResponse make_lookup_response(input TTLookupRequest req, input TTEntry entry);
        automatic TTLookupResponse resp;
        automatic logic entry_hit;

        entry_hit = (entry.bound_type != TT_BOUND_INVALID) && (entry.verify_key == tt_verify_key(req.zobrist_key));

        resp.thread_id = req.thread_id;
        resp.hit = entry_hit;
        resp.score = entry_hit ? restore_mate_for_lookup(entry.score, req.ply) : UNKNOWN_EVAL_SCORE;
        resp.bound_type = entry_hit ? entry.bound_type : TT_BOUND_INVALID;
        resp.depth = entry_hit ? entry.depth : TTDepth'(0);
        resp.best_move = entry_hit ? tt_decode_move(entry.best_move_bits) : NULL_MOVE;
        resp.age = entry_hit ? entry.age : TTAge'(0);
        return resp;
    endfunction : make_lookup_response

    function automatic TTEntry make_store_entry(input TTStoreRequest req);
        return tt_make_entry(
            req.zobrist_key,
            req.best_move,
            normalize_mate_for_store(req.score, req.ply),
            req.depth,
            req.bound_type,
            req.age
        );
    endfunction : make_store_entry

    function automatic logic should_replace(input TTEntry old_entry, input TTStoreRequest req);
        automatic logic old_invalid;
        automatic logic key_mismatch;
        automatic logic stale_with_depth_window;
        automatic logic new_deeper_or_equal;
        automatic logic exact_over_non_exact;

        old_invalid = old_entry.bound_type == TT_BOUND_INVALID;
        key_mismatch = old_entry.verify_key != tt_verify_key(req.zobrist_key);
        stale_with_depth_window = (old_entry.age != req.age) && ((int'(req.depth) + 4) >= int'(old_entry.depth));
        new_deeper_or_equal = req.depth >= old_entry.depth;
        exact_over_non_exact = (req.bound_type == TT_BOUND_EXACT)
            && (old_entry.bound_type != TT_BOUND_EXACT)
            && (req.depth == old_entry.depth);

        return old_invalid || key_mismatch || stale_with_depth_window || new_deeper_or_equal || exact_over_non_exact;
    endfunction : should_replace

    always_ff @(posedge clk) begin
        if (!rst_n) begin
            lookup_resp_reg <= TTLookupResponse'('0);
            lookup_resp_valid <= 1'b0;
            store_state <= STORE_IDLE;
            active_store_req <= TTStoreRequest'('0);
            active_store_old_entry <= tt_invalid_entry();
            active_store_index <= TTIndex'(0);
            store_fifo_count <= StoreFifoCount'(0);
            store_fifo_head <= StoreFifoPtr'(0);
            store_fifo_tail <= StoreFifoPtr'(0);
            clear_active <= 1'b0;
            clear_index <= TTIndex'(0);
            clear_prev <= 1'b0;
            for (int idx = 0; idx < STORE_FIFO_DEPTH; idx++) begin
                store_fifo[idx] <= TTStoreRequest'('0);
            end
        end else begin
            lookup_resp_valid <= 1'b0;
            clear_prev <= clear;

            if (clear_start) begin
                clear_active <= 1'b1;
                clear_index <= TTIndex'(0);
                store_state <= STORE_IDLE;
                active_store_req <= TTStoreRequest'('0);
                active_store_old_entry <= tt_invalid_entry();
                active_store_index <= TTIndex'(0);
                store_fifo_count <= StoreFifoCount'(0);
                store_fifo_head <= StoreFifoPtr'(0);
                store_fifo_tail <= StoreFifoPtr'(0);
                for (int idx = 0; idx < STORE_FIFO_DEPTH; idx++) begin
                    store_fifo[idx] <= TTStoreRequest'('0);
                end
            end else if (clear_active) begin
                mem[clear_index] <= tt_invalid_entry();
                if (clear_index == TTIndex'(TT_ENTRY_COUNT - 1)) begin
                    clear_active <= 1'b0;
                end else begin
                    clear_index <= clear_index + TTIndex'(1);
                end
            end else begin
                if (lookup_accept) begin
                    lookup_resp_reg <= make_lookup_response(lookup_req, mem[tt_index(lookup_req.zobrist_key)]);
                    lookup_resp_valid <= 1'b1;
                end

                if (lookup_accept) begin
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
                                active_store_old_entry <= mem[tt_index(store_fifo[store_fifo_head].zobrist_key)];
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
                                active_store_old_entry <= mem[tt_index(store_req.zobrist_key)];
                                store_state <= STORE_WRITE;
                            end
                        end

                        STORE_WRITE: begin
                            if (should_replace(active_store_old_entry, active_store_req)) begin
                                mem[active_store_index] <= make_store_entry(active_store_req);
                            end
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
