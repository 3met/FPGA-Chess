// Portable cached TT frontend for a 16-bit burst-memory backend.

import general_chess_defs::*;
import tt_defs::*;

module tt_external_load_store #(
    parameter int CACHE_INDEX_BITS = 10,
    parameter int ENTRY_COUNT = TT_EXTERNAL_ENTRY_COUNT,
    parameter int STORE_FIFO_DEPTH = 256
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
    typedef logic [ENTRY_INDEX_BITS-1:0] EntryIndex;
    typedef logic [CACHE_INDEX_BITS-1:0] CacheIndex;
    typedef logic [$clog2(STORE_FIFO_DEPTH + 1)-1:0] StoreFifoCount;

    typedef enum logic [3:0] {
        S_IDLE, S_READ_REQ, S_READ_DATA, S_WRITE_REQ, S_WRITE_DATA, S_WRITE_DONE,
        S_CLEAR_REQ, S_CLEAR_DATA, S_CLEAR_DONE, S_CACHE_CLEAR, S_CACHE_READ,
        S_READ_DONE
    } State;

    State state;
    logic operation_store;
    TTLookupRequest active_lookup;
    TTStoreRequest active_store;
    TTPhysicalEntry transfer_entry;
    TTPhysicalEntry write_entry;
    logic [2:0] word_count;
    EntryIndex active_index;
    EntryIndex clear_index;
    CacheIndex cache_clear_index;
    TTAge generation;
    logic clear_prev;
    logic clear_pending;
    EntryIndex lookup_index;
    StoreFifoCount store_fifo_count;
    TTStoreRequest store_fifo_data;
    logic store_fifo_valid;
    logic store_fifo_push_ready;
    logic store_accept;
    logic store_pop;

`ifndef SYNTHESIS
    initial begin
        if (STORE_FIFO_DEPTH < 2) $error("tt_external_load_store STORE_FIFO_DEPTH must be at least two");
    end
`endif

    (* ramstyle = "M10K" *) (* ram_style = "block" *) TTPhysicalEntry cache_data[0:CACHE_COUNT-1];
    (* ramstyle = "M10K" *) (* ram_style = "block" *) EntryIndex cache_tag[0:CACHE_COUNT-1];
    (* ramstyle = "M10K" *) (* ram_style = "block" *) logic cache_valid[0:CACHE_COUNT-1];
    TTPhysicalEntry cache_read_data;
    EntryIndex cache_read_tag;
    logic cache_read_valid;

    function automatic EntryIndex entry_index(input ZobristKey key);
        logic [54:0] product;
        product = key[47:16] * ENTRY_COUNT;
        return EntryIndex'(product[54:32]);
    endfunction

    function automatic TTWordAddress word_address(input EntryIndex index);
        return TTWordAddress'((index << 2) + (index << 1));
    endfunction

    function automatic TTPhysicalEntry pack_entry(input TTEntry entry);
        TTPhysicalEntry physical;
        physical = '0;
        physical[47:0] = entry.verify_key;
        physical[61:48] = entry.best_move_bits;
        physical[63:62] = 2'b0;
        physical[79:64] = entry.score;
        physical[85:80] = entry.depth;
        physical[87:86] = entry.bound_type;
        physical[95:88] = entry.age;
        return physical;
    endfunction

    function automatic TTEntry unpack_entry(input TTPhysicalEntry physical);
        TTEntry entry;
        entry.verify_key = physical[47:0];
        entry.best_move_bits = physical[61:48];
        entry.score = EvalScore'(physical[79:64]);
        entry.depth = TTDepth'(physical[85:80]);
        entry.bound_type = TTBoundType'(physical[87:86]);
        entry.age = TTAge'(physical[95:88]);
        return entry;
    endfunction

    function automatic EvalScore normalize_mate(input EvalScore score, input PlyIndex ply);
        if (score >= MATE_THRESHOLD) return EvalScore'(int'(score) + int'(ply));
        if (score <= -MATE_THRESHOLD) return EvalScore'(int'(score) - int'(ply));
        return score;
    endfunction

    function automatic EvalScore restore_mate(input EvalScore score, input PlyIndex ply);
        if (score >= MATE_THRESHOLD) return EvalScore'(int'(score) - int'(ply));
        if (score <= -MATE_THRESHOLD) return EvalScore'(int'(score) + int'(ply));
        return score;
    endfunction

    function automatic logic entry_hit(input TTEntry entry, input ZobristKey key);
        return entry.bound_type != TT_BOUND_INVALID && entry.age == generation
            && entry.verify_key == tt_verify_key(key);
    endfunction

    function automatic logic should_replace(input TTEntry old_entry, input TTStoreRequest req);
        return old_entry.bound_type == TT_BOUND_INVALID || old_entry.age != generation
            || old_entry.verify_key != tt_verify_key(req.zobrist_key)
            || req.depth >= old_entry.depth
            || ((req.bound_type == TT_BOUND_EXACT) && (old_entry.bound_type != TT_BOUND_EXACT)
                && (req.depth == old_entry.depth));
    endfunction

    function automatic TTPhysicalEntry make_store_entry(input TTStoreRequest req);
        TTEntry entry;
        entry = tt_make_entry(req.zobrist_key, req.best_move, normalize_mate(req.score, req.ply),
            req.depth, req.bound_type, generation);
        return pack_entry(entry);
    endfunction

    task automatic drive_lookup_response(input TTLookupRequest req, input TTPhysicalEntry physical);
        TTEntry entry;
        logic hit;
        entry = unpack_entry(physical);
        hit = entry_hit(entry, req.zobrist_key);
        lookup_resp.thread_id <= req.thread_id;
        lookup_resp.hit <= hit;
        lookup_resp.score <= hit ? restore_mate(entry.score, req.ply) : UNKNOWN_EVAL_SCORE;
        lookup_resp.bound_type <= hit ? entry.bound_type : TT_BOUND_INVALID;
        lookup_resp.depth <= hit ? entry.depth : TTDepth'(0);
        lookup_resp.best_move <= hit ? tt_decode_move(entry.best_move_bits) : NULL_MOVE;
        lookup_resp_valid <= 1'b1;
    endtask

    always_comb begin
        lookup_index = entry_index(lookup_req.zobrist_key);
        lookup_req_ready = memory_ready && !memory_error && state == S_IDLE && !clear;
        // A full queue drops the incoming best-effort publication rather than
        // stalling its search thread.
        store_req_ready = !clear && !clear_busy;
        store_accept = store_req_valid && store_req_ready;
        store_pop = state == S_IDLE && !clear_pending && !lookup_req_valid
            && store_fifo_valid;
        clear_busy = clear || clear_pending || state == S_CACHE_CLEAR
            || state == S_CLEAR_REQ || state == S_CLEAR_DATA || state == S_CLEAR_DONE;
        mem_req_valid = state == S_READ_REQ || state == S_WRITE_REQ || state == S_CLEAR_REQ;
        mem_req_write = state != S_READ_REQ;
        mem_req_address = (state == S_CLEAR_REQ || state == S_CLEAR_DATA || state == S_CLEAR_DONE)
            ? word_address(clear_index) + TTWordAddress'(5) : word_address(active_index);
        mem_req_length = (state == S_CLEAR_REQ || state == S_CLEAR_DATA || state == S_CLEAR_DONE) ? 4'd1 : 4'd6;
        mem_write_valid = state == S_WRITE_DATA || state == S_CLEAR_DATA;
        mem_write_data = (state == S_CLEAR_DATA) ? 16'h0000 : write_entry[word_count*16 +: 16];
        mem_write_last = state == S_CLEAR_DATA || word_count == 3'd5;
        mem_read_ready = state == S_READ_DATA;
        // Every backend request, including reads, has a completion token. Do
        // not allow the backend to remain blocked after delivering read data.
        mem_done_ready = state == S_READ_DONE || state == S_WRITE_DONE || state == S_CLEAR_DONE;
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
            word_count <= 3'd0;
            clear_index <= '0;
            cache_clear_index <= '0;
        end else begin
            lookup_resp_valid <= 1'b0;
            cache_access <= 1'b0;
            cache_hit <= 1'b0;
            cache_access_is_store <= 1'b0;
            clear_prev <= clear;
            if (clear && !clear_prev) clear_pending <= 1'b1;

            if (memory_error && state != S_IDLE) begin
                if (operation_store) begin
                end else begin
                    drive_lookup_response(active_lookup, '0);
                end
                state <= S_IDLE;
            end else case (state)
                S_CACHE_CLEAR: begin
                    cache_valid[cache_clear_index] <= 1'b0;
                    if (cache_clear_index == CacheIndex'(CACHE_COUNT-1)) state <= S_IDLE;
                    else cache_clear_index <= cache_clear_index + CacheIndex'(1);
                end
                S_CACHE_READ: begin
                    cache_access <= 1'b1;
                    cache_hit <= cache_read_valid && cache_read_data[95:88] == generation
                        && cache_read_tag == active_index;
                    cache_access_is_store <= operation_store;
                    if (cache_read_valid && cache_read_data[95:88] == generation
                            && cache_read_tag == active_index) begin
                        if (!operation_store) begin
                            drive_lookup_response(active_lookup, cache_read_data);
                            state <= S_IDLE;
                        end else if (should_replace(unpack_entry(cache_read_data), active_store)) begin
                            write_entry <= make_store_entry(active_store);
                            state <= S_WRITE_REQ;
                        end else begin
                            state <= S_IDLE;
                        end
                    end else begin
                        state <= S_READ_REQ;
                    end
                end
                S_IDLE: begin
                    if (clear_pending || (clear && !clear_prev)) begin
                        clear_pending <= 1'b0;
                        if (&generation) begin
                            clear_index <= '0;
                            state <= S_CLEAR_REQ;
                        end else begin
                            generation <= generation + TTAge'(1);
                        end
                    end else if ((lookup_req_valid && lookup_req_ready) || store_pop) begin
                        EntryIndex idx;
                        CacheIndex cidx;
                        idx = lookup_req_valid ? lookup_index : entry_index(store_fifo_data.zobrist_key);
                        cidx = CacheIndex'(idx);
                        active_index <= idx;
                        cache_read_data <= cache_data[cidx];
                        cache_read_tag <= cache_tag[cidx];
                        cache_read_valid <= cache_valid[cidx];
                        if (lookup_req_valid) begin
                            active_lookup <= lookup_req;
                            operation_store <= 1'b0;
                        end else begin
                            active_store <= store_fifo_data;
                            operation_store <= 1'b1;
                        end
                        state <= S_CACHE_READ;
                    end
                end
                S_READ_REQ: if (mem_req_valid && mem_req_ready) begin word_count <= 3'd0; transfer_entry <= '0; state <= S_READ_DATA; end
                S_READ_DATA: if (mem_read_valid) begin
                    TTPhysicalEntry assembled;
                    assembled = transfer_entry;
                    assembled[word_count*16 +: 16] = mem_read_data;
                    transfer_entry <= assembled;
                    if (mem_read_last || word_count == 3'd5) begin
                        state <= S_READ_DONE;
                    end else word_count <= word_count + 3'd1;
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
                        cache_data[cidx] <= transfer_entry;
                        cache_tag[cidx] <= active_index;
                        cache_valid[cidx] <= 1'b1;
                        if (!operation_store) begin
                            drive_lookup_response(active_lookup, transfer_entry);
                            state <= S_IDLE;
                        end else if (should_replace(unpack_entry(transfer_entry), active_store)) begin
                            write_entry <= make_store_entry(active_store);
                            state <= S_WRITE_REQ;
                        end else begin
                            state <= S_IDLE;
                        end
                    end
                end
                S_WRITE_REQ: if (mem_req_valid && mem_req_ready) begin word_count <= 3'd0; state <= S_WRITE_DATA; end
                S_WRITE_DATA: if (mem_write_valid && mem_write_ready) begin
                    if (word_count == 3'd5) state <= S_WRITE_DONE;
                    else word_count <= word_count + 3'd1;
                end
                S_WRITE_DONE: if (mem_done_valid) begin
                    CacheIndex cidx;
                    cidx = CacheIndex'(active_index);
                    if (!mem_done_error) begin
                        cache_data[cidx] <= write_entry;
                        cache_tag[cidx] <= active_index;
                        cache_valid[cidx] <= 1'b1;
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
