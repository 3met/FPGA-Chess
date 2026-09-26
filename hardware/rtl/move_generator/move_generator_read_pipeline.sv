// Per-thread move memories own FIFO pointers, bucket phase, and destructive pops.
import chess_defs::*;
import move_generator_defs::*;

module move_generator_read_pipeline #(
    parameter int THREAD_COUNT = 1,
    parameter int SEARCH_STACK_DEPTH = 32,
    parameter int MEMORY_ENTRIES = 2048,
    parameter int BUCKET_RATIOS[MOVE_BUCKET_COUNT] = '{48,16,192,64,64,32,64,32}
) (
    input logic clk, rst_n, clear, flush,
    input logic pop_valid[THREAD_COUNT], output logic pop_ready[THREAD_COUNT],
    input PlyIndex pop_ply[THREAD_COUNT],
    input logic node_init_valid[THREAD_COUNT], output logic node_init_ready[THREAD_COUNT],
    input PlyIndex node_init_ply[THREAD_COUNT],
    input logic bad_noisy_enable[THREAD_COUNT],
    output logic pop_resp_valid[THREAD_COUNT], input logic pop_resp_ready[THREAD_COUNT],
    output PlyIndex pop_resp_ply[THREAD_COUNT],
    output logic pop_resp_found[THREAD_COUNT],
    output Move pop_resp_move[THREAD_COUNT], output MoveBucketIndex pop_resp_bucket[THREAD_COUNT],
    input logic generation_request_valid[2], input logic generation_start_valid[2],
    output logic generation_start_ready[2],
    input ThreadID generation_request_thread[2], input PlyIndex generation_request_ply[2],
    input ThreadID generation_start_thread[2], input PlyIndex generation_start_ply[2],
    input logic live_active[2], input ThreadID live_thread[2], input PlyIndex live_ply[2],
    input logic write_valid[2], input Move write_move[2],
    input MoveBucketIndex write_bucket[2], output MoveBucketTop write_top[2],
    output logic overflow_sticky
);
    localparam int TOTAL_RATIO = BUCKET_RATIOS[0]+BUCKET_RATIOS[1]+BUCKET_RATIOS[2]+BUCKET_RATIOS[3]
        +BUCKET_RATIOS[4]+BUCKET_RATIOS[5]+BUCKET_RATIOS[6]+BUCKET_RATIOS[7];
    localparam int SCALE = TOTAL_RATIO > 0 ? MEMORY_ENTRIES/TOTAL_RATIO : 0;
    localparam int CAPACITIES[MOVE_BUCKET_COUNT] = '{BUCKET_RATIOS[0]*SCALE,BUCKET_RATIOS[1]*SCALE,
        BUCKET_RATIOS[2]*SCALE,BUCKET_RATIOS[3]*SCALE,BUCKET_RATIOS[4]*SCALE,
        BUCKET_RATIOS[5]*SCALE,BUCKET_RATIOS[6]*SCALE,BUCKET_RATIOS[7]*SCALE};
    localparam int POINTER_ADDR_BITS = SEARCH_STACK_DEPTH <= 1 ? 1 : $clog2(SEARCH_STACK_DEPTH);

    typedef logic [POINTER_ADDR_BITS-1:0] PointerAddress;
    typedef struct packed {
        MoveBucketTops tops;
        // Absolute FIFO heads avoid a second parent-stack read on every pop.
        MoveBucketTops heads;
        MoveMemoryPhase phase;
    } MovePointerState;

    genvar bucket_index;
    generate
        if (TOTAL_RATIO <= 0 || MEMORY_ENTRIES < 2
                || MEMORY_ENTRIES % (TOTAL_RATIO > 0 ? TOTAL_RATIO : 1) != 0) begin : gen_invalid_size
            MOVE_MEMORY_SIZE_MUST_BE_A_MULTIPLE_OF_BUCKET_RATIO_SUM invalid_configuration();
        end
        if (SEARCH_STACK_DEPTH < 1 || SEARCH_STACK_DEPTH > MAX_PLY_COUNT) begin : gen_invalid_depth
            MOVE_POINTER_STACK_DEPTH_MUST_FIT_PLY invalid_configuration();
        end
        for (bucket_index=0;bucket_index<MOVE_BUCKET_COUNT;bucket_index++) begin : gen_validate_bucket
            if (BUCKET_RATIOS[bucket_index] <= 0 || CAPACITIES[bucket_index] >= (1<<MOVE_BUCKET_TOP_BITS)) begin : gen_invalid
                MOVE_BUCKET_CAPACITY_MUST_BE_POSITIVE_AND_FIT_POINTER invalid_configuration();
            end
        end
    endgenerate

    logic stage_valid[THREAD_COUNT], result_valid[THREAD_COUNT];
    PlyIndex stage_ply[THREAD_COUNT], result_ply[THREAD_COUNT];
    logic result_found[THREAD_COUNT], result_bypass[THREAD_COUNT];
    MoveBucketIndex result_bucket[THREAD_COUNT];
    Move result_forward[THREAD_COUNT], ram_move[THREAD_COUNT];

    MovePointerState cache_state[THREAD_COUNT], next_state[THREAD_COUNT];
    PlyIndex cache_ply[THREAD_COUNT];
    logic cache_valid[THREAD_COUNT], state_update[THREAD_COUNT];
    PlyIndex state_update_ply[THREAD_COUNT];

    logic pointer_load_pending[THREAD_COUNT], pointer_load_issue[THREAD_COUNT];
    PlyIndex pointer_load_tag[THREAD_COUNT], pointer_read_ply[THREAD_COUNT];
    PointerAddress pointer_read_address[THREAD_COUNT], pointer_write_address[THREAD_COUNT];
    logic pointer_write_enable[THREAD_COUNT];
    logic [$bits(MovePointerState)-1:0] pointer_read_bits[THREAD_COUNT];

    logic service[THREAD_COUNT], found[THREAD_COUNT], blocked[THREAD_COUNT];
    logic bypass[THREAD_COUNT], cache_match[THREAD_COUNT];
    MoveBucketIndex selected[THREAD_COUNT];
    MoveBucketTop read_top[THREAD_COUNT];
    logic thread_write_valid[THREAD_COUNT];
    Move thread_write_move[THREAD_COUNT];
    MoveBucketIndex thread_write_bucket[THREAD_COUNT];
    MoveBucketTop thread_write_top[THREAD_COUNT];
    logic generation_active_q[2];
    ThreadID generation_thread_q[2];
    PlyIndex generation_ply_q[2];

    // Retain accepted generator ownership locally so lane-state decode does not
    // sit on the pointer-stack RAM write-data path. Release is registered after
    // the lane becomes idle, which only adds a conservative wait cycle.
    always_ff @(posedge clk) begin
        if (!rst_n || clear || flush) begin
            for (int lane = 0; lane < 2; lane++) begin
                generation_active_q[lane] <= 1'b0;
                generation_thread_q[lane] <= ThreadID'(0);
                generation_ply_q[lane] <= PlyIndex'(0);
            end
        end else begin
            for (int lane = 0; lane < 2; lane++) begin
                if (generation_start_valid[lane]) begin
                    generation_active_q[lane] <= 1'b1;
                    generation_thread_q[lane] <= generation_start_thread[lane];
                    generation_ply_q[lane] <= generation_start_ply[lane];
                end else if (!live_active[lane]) begin
                    generation_active_q[lane] <= 1'b0;
                end
            end
        end
    end

    function automatic MoveBucketMask phase_mask(input MoveMemoryPhase phase);
        case (phase)
            MOVE_MEMORY_GOOD_NOISY: return GOOD_NOISY_BUCKET_MASK;
            MOVE_MEMORY_QUIET: return QUIET_BUCKET_MASK;
            MOVE_MEMORY_BAD_NOISY: return BAD_NOISY_BUCKET_MASK;
            default: return MoveBucketMask'(0);
        endcase
    endfunction

    function automatic MoveMemoryPhase exhausted_phase(input MoveMemoryPhase phase);
        case (phase)
            MOVE_MEMORY_GOOD_NOISY: return MOVE_MEMORY_WAIT_QUIET;
            MOVE_MEMORY_QUIET: return MOVE_MEMORY_BAD_NOISY;
            MOVE_MEMORY_BAD_NOISY: return MOVE_MEMORY_DONE;
            default: return phase;
        endcase
    endfunction

    // The first generator initializes a node from its parent's final tails;
    // quiet generation reuses the current node and advances its bucket phase.
    always_comb begin
        for (int lane = 0; lane < 2; lane++) begin
            automatic int tid = int'(generation_request_thread[lane]);
            if (lane == 0)
                generation_start_ready[lane] = generation_request_ply[lane] == PlyIndex'(0)
                    || (cache_valid[tid]
                        && (cache_ply[tid] + PlyIndex'(1) == generation_request_ply[lane]
                            || (cache_ply[tid] == generation_request_ply[lane]
                                && cache_state[tid].phase == MOVE_MEMORY_INITIALIZED)));
            else
                generation_start_ready[lane] = cache_valid[tid]
                    && cache_ply[tid] == generation_request_ply[lane]
                    && cache_state[tid].phase == MOVE_MEMORY_WAIT_QUIET;
            generation_start_ready[lane] = generation_start_ready[lane]
                && !pointer_load_pending[tid] && !stage_valid[tid];
        end
    end

    // Select the next move for every thread independently and combine a same-
    // cycle generator write with the pointer update for its thread.
    always_comb begin
        for (int lane = 0; lane < 2; lane++) write_top[lane] = MoveBucketTop'(0);
        for (int tid = 0; tid < THREAD_COUNT; tid++) begin
            automatic MoveBucketMask eligible;
            automatic MoveBucketMask generating;
            automatic MoveBucketMask incoming;
            automatic logic result_room;
            automatic logic generation_starting;
            next_state[tid] = cache_state[tid];
            generation_starting = 1'b0;
            for (int lane = 0; lane < 2; lane++) begin
                generation_starting |= generation_start_valid[lane]
                    && generation_start_thread[lane] == ThreadID'(tid);
            end
            node_init_ready[tid] = rst_n && !clear && !flush
                && !pointer_load_pending[tid] && !stage_valid[tid]
                && !generation_starting
                && (node_init_ply[tid] == PlyIndex'(0)
                    || (cache_valid[tid]
                        && cache_ply[tid] + PlyIndex'(1) == node_init_ply[tid]));
            state_update[tid] = 1'b0;
            state_update_ply[tid] = cache_ply[tid];
            cache_match[tid] = cache_valid[tid] && stage_ply[tid] == cache_ply[tid];
            thread_write_valid[tid] = 1'b0;
            thread_write_move[tid] = NULL_MOVE;
            thread_write_bucket[tid] = MoveBucketIndex'(0);
            thread_write_top[tid] = MoveBucketTop'(0);
            generating = MoveBucketMask'(0);
            incoming = MoveBucketMask'(0);

            for (int lane = 0; lane < 2; lane++) begin
                if (generation_active_q[lane]
                        && generation_thread_q[lane] == ThreadID'(tid)
                        && cache_valid[tid] && generation_ply_q[lane] == cache_ply[tid]) begin
                    generating |= lane == 0
                        ? GOOD_NOISY_BUCKET_MASK | BAD_NOISY_BUCKET_MASK
                        : QUIET_BUCKET_MASK;
                    if (write_valid[lane]) begin
                        incoming[write_bucket[lane]] = 1'b1;
                        thread_write_valid[tid] = 1'b1;
                        thread_write_move[tid] = write_move[lane];
                        thread_write_bucket[tid] = write_bucket[lane];
                        thread_write_top[tid] = next_state[tid].tops[write_bucket[lane]];
                        write_top[lane] = next_state[tid].tops[write_bucket[lane]];
                    end
                end
            end

            found[tid] = 1'b0;
            blocked[tid] = 1'b0;
            selected[tid] = MoveBucketIndex'(0);
            read_top[tid] = MoveBucketTop'(0);
            eligible = phase_mask(cache_state[tid].phase);
            for (int bucket = MOVE_BUCKET_COUNT-1; bucket >= 0; bucket--) begin
                if (!found[tid] && !blocked[tid] && eligible[bucket]) begin
                    automatic MoveBucketTop head = cache_state[tid].heads[bucket];
                    if (cache_state[tid].tops[bucket] > head
                            || (cache_state[tid].tops[bucket] == head
                                && incoming[bucket])) begin
                        found[tid] = 1'b1;
                        selected[tid] = MoveBucketIndex'(bucket);
                        read_top[tid] = head;
                    end else if (generating[bucket]) begin
                        blocked[tid] = 1'b1;
                    end
                end
            end

            result_room = !result_valid[tid] || pop_resp_ready[tid];
            service[tid] = stage_valid[tid] && cache_match[tid]
                && !blocked[tid] && result_room && rst_n && !clear && !flush;
            bypass[tid] = service[tid] && found[tid] && thread_write_valid[tid]
                && thread_write_bucket[tid] == selected[tid]
                && cache_state[tid].tops[selected[tid]] == read_top[tid];

            // A generation start changes ownership before its first write.
            if (node_init_valid[tid] && node_init_ready[tid]) begin
                state_update[tid] = 1'b1;
                state_update_ply[tid] = node_init_ply[tid];
                next_state[tid].tops = node_init_ply[tid] == PlyIndex'(0)
                    ? MoveBucketTops'(0) : cache_state[tid].tops;
                next_state[tid].heads = node_init_ply[tid] == PlyIndex'(0)
                    ? MoveBucketTops'(0) : cache_state[tid].tops;
                next_state[tid].phase = MOVE_MEMORY_INITIALIZED;
            end
            for (int lane = 0; lane < 2; lane++) begin
                if (generation_start_valid[lane]
                        && generation_start_thread[lane] == ThreadID'(tid)) begin
                    state_update[tid] = 1'b1;
                    state_update_ply[tid] = generation_start_ply[lane];
                    if (lane == 0) begin
                        next_state[tid].tops = generation_start_ply[lane] == PlyIndex'(0)
                            ? MoveBucketTops'(0) : cache_state[tid].tops;
                        next_state[tid].heads = generation_start_ply[lane] == PlyIndex'(0)
                            ? MoveBucketTops'(0) : cache_state[tid].tops;
                        next_state[tid].phase = MOVE_MEMORY_GOOD_NOISY;
                    end else begin
                        next_state[tid].phase = MOVE_MEMORY_QUIET;
                    end
                end
            end

            // A forwarded empty-FIFO write is consumed without allocating an
            // arena entry, so neither FIFO pointer advances.
            if (thread_write_valid[tid] && !bypass[tid]) begin
                next_state[tid].tops[thread_write_bucket[tid]]
                    = next_state[tid].tops[thread_write_bucket[tid]] + MoveBucketTop'(1);
                state_update[tid] = 1'b1;
            end
            if (service[tid]) begin
                if (found[tid]) begin
                    if (!bypass[tid]) begin
                        next_state[tid].heads[selected[tid]]
                            = next_state[tid].heads[selected[tid]] + MoveBucketTop'(1);
                        state_update[tid] = 1'b1;
                    end
                end else begin
                    next_state[tid].phase = exhausted_phase(next_state[tid].phase);
                    state_update[tid] = 1'b1;
                end
            end
            if (bad_noisy_enable[tid]) begin
                next_state[tid].phase = MOVE_MEMORY_BAD_NOISY;
                state_update[tid] = 1'b1;
            end

            pop_ready[tid] = rst_n && !clear && !flush
                && !generation_starting && (!stage_valid[tid] || service[tid]);
            pop_resp_valid[tid] = result_valid[tid] && rst_n && !clear && !flush;
            pop_resp_ply[tid] = result_ply[tid];
            pop_resp_found[tid] = result_found[tid];
            pop_resp_bucket[tid] = result_bucket[tid];
            pop_resp_move[tid] = result_found[tid]
                ? (result_bypass[tid] ? result_forward[tid] : ram_move[tid])
                : Move'('x);

            pointer_load_issue[tid] = 1'b0;
            pointer_read_ply[tid] = stage_ply[tid];
            if (pop_ready[tid] && pop_valid[tid]
                    && (!cache_valid[tid] || pop_ply[tid] != cache_ply[tid])) begin
                pointer_load_issue[tid] = 1'b1;
                pointer_read_ply[tid] = pop_ply[tid];
            end else if (stage_valid[tid] && !cache_match[tid]
                    && !pointer_load_pending[tid]) begin
                pointer_load_issue[tid] = 1'b1;
            end else if (!pointer_load_pending[tid] && !stage_valid[tid]
                    && node_init_valid[tid] && !node_init_ready[tid]
                    && node_init_ply[tid] != PlyIndex'(0)) begin
                pointer_load_issue[tid] = 1'b1;
                pointer_read_ply[tid] = node_init_ply[tid] - PlyIndex'(1);
            end else if (!pointer_load_pending[tid] && !stage_valid[tid]) begin
                for (int lane = 0; lane < 2; lane++) begin
                    if (!pointer_load_issue[tid] && generation_request_valid[lane]
                            && generation_request_thread[lane] == ThreadID'(tid)
                            && !generation_start_ready[lane]
                            && (lane == 0 || !cache_valid[tid]
                                || cache_ply[tid] != generation_request_ply[lane])
                            && !(lane == 0 && generation_request_ply[lane] == PlyIndex'(0))) begin
                        pointer_load_issue[tid] = 1'b1;
                        pointer_read_ply[tid] = lane == 0
                            ? generation_request_ply[lane] - PlyIndex'(1)
                            : generation_request_ply[lane];
                    end
                end
            end
            pointer_read_address[tid] = PointerAddress'(pointer_read_ply[tid]);
            pointer_write_enable[tid] = state_update[tid] && rst_n && !clear && !flush;
            pointer_write_address[tid] = PointerAddress'(state_update_ply[tid]);
        end
    end

    genvar thread_index;
    generate
        for (thread_index = 0; thread_index < THREAD_COUNT; thread_index++) begin : gen_thread
            move_generator_bucket_store #(
                .MEMORY_ENTRIES(MEMORY_ENTRIES), .CAPACITIES(CAPACITIES)
            ) store (
                .clk,
                .wr_valid(thread_write_valid[thread_index]
                    && !bypass[thread_index] && !flush && !clear && rst_n),
                .wr_move(thread_write_move[thread_index]),
                .wr_bucket(thread_write_bucket[thread_index]),
                .wr_top(thread_write_top[thread_index]),
                .rd_valid(service[thread_index] && found[thread_index]
                    && !bypass[thread_index]),
                .rd_bucket(selected[thread_index]), .rd_top(read_top[thread_index]),
                .rd_move(ram_move[thread_index])
            );

            sync_read_simple_dual_port_ram #(
                .NUM_WORDS(SEARCH_STACK_DEPTH), .WORD_SIZE($bits(MovePointerState))
            ) pointer_stack (
                .clock(clk), .data(next_state[thread_index]),
                .rdaddress(pointer_read_address[thread_index]),
                .rden(pointer_load_issue[thread_index]),
                .wraddress(pointer_write_address[thread_index]),
                .wren(pointer_write_enable[thread_index]),
                .q(pointer_read_bits[thread_index])
            );

            always_ff @(posedge clk) begin
                if (!rst_n || clear) begin
                    stage_valid[thread_index] <= 1'b0;
                    result_valid[thread_index] <= 1'b0;
                    pointer_load_pending[thread_index] <= 1'b0;
                    cache_valid[thread_index] <= 1'b1;
                    cache_ply[thread_index] <= PlyIndex'(0);
                    cache_state[thread_index].tops <= MoveBucketTops'(0);
                    cache_state[thread_index].heads <= MoveBucketTops'(0);
                    cache_state[thread_index].phase <= MOVE_MEMORY_DONE;
                end else if (flush) begin
                    stage_valid[thread_index] <= 1'b0;
                    result_valid[thread_index] <= 1'b0;
                    pointer_load_pending[thread_index] <= 1'b0;
                    cache_valid[thread_index] <= 1'b0;
                end else begin
                    if (pop_resp_ready[thread_index]) result_valid[thread_index] <= 1'b0;
                    if (service[thread_index]) begin
                        stage_valid[thread_index] <= 1'b0;
                        result_valid[thread_index] <= 1'b1;
                        result_ply[thread_index] <= stage_ply[thread_index];
                        result_found[thread_index] <= found[thread_index];
                        result_bucket[thread_index] <= selected[thread_index];
                        result_bypass[thread_index] <= bypass[thread_index];
                        result_forward[thread_index] <= thread_write_move[thread_index];
                    end
                    if (pop_ready[thread_index]) begin
                        stage_valid[thread_index] <= pop_valid[thread_index];
                        if (pop_valid[thread_index]) stage_ply[thread_index] <= pop_ply[thread_index];
                    end
                    if (pointer_load_issue[thread_index]) begin
                        pointer_load_pending[thread_index] <= 1'b1;
                        pointer_load_tag[thread_index] <= pointer_read_ply[thread_index];
                    end else if (pointer_load_pending[thread_index]) begin
                        pointer_load_pending[thread_index] <= 1'b0;
                        cache_valid[thread_index] <= 1'b1;
                        cache_ply[thread_index] <= pointer_load_tag[thread_index];
                        cache_state[thread_index] <= MovePointerState'(pointer_read_bits[thread_index]);
                    end
                    if (state_update[thread_index]) begin
                        cache_valid[thread_index] <= 1'b1;
                        cache_ply[thread_index] <= state_update_ply[thread_index];
                        cache_state[thread_index] <= next_state[thread_index];
                    end
                end
            end
        end
    endgenerate

`ifndef SYNTHESIS
    always_ff @(posedge clk) if (rst_n && !clear && !flush) begin
        assert (!(write_valid[0] && write_valid[1]
                && live_thread[0] == live_thread[1]))
            else $error("two generators wrote one thread");
        for (int tid = 0; tid < THREAD_COUNT; tid++) begin
            if (node_init_valid[tid] && node_init_ready[tid]) begin
                assert (node_init_ply[tid] == PlyIndex'(0)
                        || (cache_valid[tid]
                            && cache_ply[tid] + PlyIndex'(1) == node_init_ply[tid]))
                    else $error("node initialization did not inherit parent: thread=%0d node=%0d cache_valid=%0b cache_ply=%0d pending=%0b",
                        tid, node_init_ply[tid], cache_valid[tid], cache_ply[tid],
                        pointer_load_pending[tid]);
            end
        end
        for (int lane = 0; lane < 2; lane++) begin
            if (write_valid[lane])
                assert (cache_valid[live_thread[lane]]
                    && cache_ply[live_thread[lane]] == live_ply[lane])
                    else $error("generator write did not own pointer cache");
        end
    end
`endif

    always_ff @(posedge clk) begin
        if (!rst_n || clear) overflow_sticky <= 1'b0;
        else if (!flush) begin
            for (int tid = 0; tid < THREAD_COUNT; tid++) begin
                if (thread_write_valid[tid] && !bypass[tid]
                        && int'(thread_write_top[tid])
                            >= CAPACITIES[thread_write_bucket[tid]])
                    overflow_sticky <= 1'b1;
            end
        end
    end
endmodule : move_generator_read_pipeline
