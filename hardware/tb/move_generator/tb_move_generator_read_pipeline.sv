import chess_defs::*;
import move_generator_defs::*;

module tb_move_generator_read_pipeline;
    localparam int THREADS = 2;
    logic clk = 0, rst_n = 0, clear = 0, flush = 0, overflow_sticky;
    logic pop_valid[THREADS], pop_ready[THREADS], pop_resp_valid[THREADS];
    logic pop_resp_ready[THREADS], pop_resp_found[THREADS];
    PlyIndex pop_ply[THREADS], pop_resp_ply[THREADS];
    Move pop_resp_move[THREADS];
    MoveBucketIndex pop_resp_bucket[THREADS];
    logic node_init_valid[THREADS], node_init_ready[THREADS], bad_noisy_enable[THREADS];
    PlyIndex node_init_ply[THREADS];
    logic generation_request_valid[2], generation_start_valid[2];
    logic generation_start_ready[2], live_active[2];
    ThreadID generation_request_thread[2], generation_start_thread[2], live_thread[2];
    PlyIndex generation_request_ply[2], generation_start_ply[2], live_ply[2];
    logic write_valid[2];
    Move write_move[2];
    MoveBucketIndex write_bucket[2];
    MoveBucketTop write_top[2];
    int pass_count = 0, fail_count = 0;

    move_generator_read_pipeline #(
        .THREAD_COUNT(THREADS), .SEARCH_STACK_DEPTH(8), .MEMORY_ENTRIES(512)
    ) dut (.*);

    task automatic tick(input int count = 1);
        repeat (count) begin clk = 0; #5; clk = 1; #5; end
    endtask

    task automatic check(input logic condition, input string description);
        if (condition) pass_count++;
        else begin fail_count++; $error("FAIL: %s", description); end
    endtask

    task automatic reset_inputs();
        clear = 1;
        tick();
        for (int tid = 0; tid < THREADS; tid++) begin
            pop_valid[tid] = 0;
            pop_resp_ready[tid] = 0;
            pop_ply[tid] = 0;
            node_init_valid[tid] = 0;
            node_init_ply[tid] = 0;
            bad_noisy_enable[tid] = 0;
        end
        for (int lane = 0; lane < 2; lane++) begin
            generation_start_valid[lane] = 0;
            generation_request_valid[lane] = 0;
            generation_request_thread[lane] = ThreadID'(lane);
            generation_request_ply[lane] = 0;
            generation_start_thread[lane] = ThreadID'(lane);
            generation_start_ply[lane] = 0;
            live_active[lane] = 0;
            live_thread[lane] = ThreadID'(lane);
            live_ply[lane] = 0;
            write_valid[lane] = 0;
            write_move[lane] = NULL_MOVE;
            write_bucket[lane] = 0;
        end
        clear = 0;
        tick();
    endtask

    task automatic start_generation(input int lane, input int tid, input int ply);
        generation_request_thread[lane] = ThreadID'(tid);
        generation_request_ply[lane] = PlyIndex'(ply);
        generation_request_valid[lane] = 1;
        while (!generation_start_ready[lane]) tick();
        generation_start_valid[lane] = 1;
        generation_start_thread[lane] = ThreadID'(tid);
        generation_start_ply[lane] = PlyIndex'(ply);
        tick();
        generation_start_valid[lane] = 0;
        generation_request_valid[lane] = 0;
        live_active[lane] = 1;
        live_thread[lane] = ThreadID'(tid);
        live_ply[lane] = PlyIndex'(ply);
    endtask

    task automatic finish_generation(input int lane);
        live_active[lane] = 0;
        tick();
    endtask

    task automatic push(input int lane, input int bucket, input int value);
        write_bucket[lane] = MoveBucketIndex'(bucket);
        write_move[lane] = Move'(value);
        write_valid[lane] = 1;
        tick();
        write_valid[lane] = 0;
    endtask

    task automatic request(input int tid, input int ply);
        pop_ply[tid] = PlyIndex'(ply);
        while (!pop_ready[tid]) tick();
        pop_valid[tid] = 1;
        tick();
        pop_valid[tid] = 0;
    endtask

    task automatic expect_response(
        input int tid, input logic expected_found,
        input int expected_move, input int expected_bucket,
        input string description
    );
        for (int wait_cycle = 0; wait_cycle < 8 && !pop_resp_valid[tid]; wait_cycle++) tick();
        check(pop_resp_valid[tid], {description, " response"});
        check(pop_resp_found[tid] == expected_found, {description, " found"});
        if (expected_found) begin
            check(pop_resp_move[tid] == Move'(expected_move), {description, " move"});
            check(pop_resp_bucket[tid] == MoveBucketIndex'(expected_bucket),
                {description, " bucket"});
        end
        pop_resp_ready[tid] = 1;
        tick();
        pop_resp_ready[tid] = 0;
    endtask

    initial begin
        reset_inputs();
        rst_n = 1;
        tick();

        // Both threads own independent memories and can pop on the same cycle.
        start_generation(0, 1, 0);
        finish_generation(0);
        request(1, 0);
        expect_response(1, 0, 0, 0,
            "thread one completes an empty noisy phase");
        start_generation(0, 0, 0);
        start_generation(1, 1, 0);
        push(0, 7, 101);
        push(0, 7, 102);
        push(1, 5, 201);
        pop_ply[0] = 0;
        pop_ply[1] = 0;
        pop_valid[0] = 1;
        pop_valid[1] = 1;
        #1;
        check(pop_ready[0] && pop_ready[1], "both thread pops are accepted together");
        tick();
        pop_valid[0] = 0;
        pop_valid[1] = 0;
        tick();
        check(pop_resp_valid[0] && pop_resp_valid[1], "both thread responses return together");
        check(pop_resp_move[0] == Move'(101), "thread zero returns its oldest move");
        check(pop_resp_move[1] == Move'(201), "thread one returns its oldest move");
        pop_resp_ready[0] = 1;
        pop_resp_ready[1] = 1;
        tick();
        pop_resp_ready[0] = 0;
        pop_resp_ready[1] = 0;
        request(0, 0);
        expect_response(0, 1, 102, 7, "FIFO second move");

        // An unfinished empty high bucket blocks a populated lower bucket.
        push(0, 6, 301);
        request(0, 0);
        tick(2);
        check(!pop_resp_valid[0], "empty unfinished bucket seven blocks bucket six");
        push(0, 7, 302);
        expect_response(0, 1, 302, 7, "incoming high move wakes blocked pop");
        request(0, 0);
        tick(2);
        check(!pop_resp_valid[0], "reader waits before descending from live bucket seven");
        finish_generation(0);
        expect_response(0, 1, 301, 6, "reader descends after noisy completion");

        // Same-bucket writes append behind existing data instead of bypassing it.
        reset_inputs();
        start_generation(0, 0, 0);
        push(0, 7, 401);
        request(0, 0);
        write_bucket[0] = 7;
        write_move[0] = Move'(402);
        write_valid[0] = 1;
        tick();
        write_valid[0] = 0;
        expect_response(0, 1, 401, 7, "simultaneous append preserves old head");
        request(0, 0);
        expect_response(0, 1, 402, 7, "appended move becomes next FIFO entry");

        // Bad noisy moves remain hidden until the explicit quiet-policy decision.
        reset_inputs();
        start_generation(0, 0, 0);
        push(0, 1, 501);
        finish_generation(0);
        request(0, 0);
        expect_response(0, 0, 0, 0, "good noisy exhaustion");
        bad_noisy_enable[0] = 1;
        tick();
        bad_noisy_enable[0] = 0;
        request(0, 0);
        expect_response(0, 1, 501, 1, "bad noisy phase follows policy command");

        // A child begins at the parent's tails, and loading the parent restores
        // its unconsumed FIFO heads without any pointer payload from the caller.
        reset_inputs();
        start_generation(0, 0, 0);
        push(0, 7, 601);
        push(0, 7, 602);
        finish_generation(0);
        start_generation(0, 0, 1);
        push(0, 7, 611);
        push(0, 7, 612);
        finish_generation(0);
        request(0, 1);
        expect_response(0, 1, 611, 7, "child excludes parent first move");
        request(0, 1);
        expect_response(0, 1, 612, 7, "child excludes parent second move");
        request(0, 0);
        expect_response(0, 1, 601, 7, "restored parent first move");
        request(0, 0);
        expect_response(0, 1, 602, 7, "restored parent second move");

        // Poison ply one, clear only the logical state, then initialize a new
        // ply one without generation before creating and generating ply two.
        reset_inputs();
        start_generation(0, 0, 0);
        push(0, 7, 620);
        push(0, 7, 621);
        finish_generation(0);
        start_generation(0, 0, 1);
        push(0, 7, 622);
        push(0, 7, 623);
        finish_generation(0);
        clear = 1;
        tick();
        clear = 0;
        tick();
        start_generation(0, 0, 0);
        push(0, 7, 630);
        finish_generation(0);
        request(0, 1);
        expect_response(0, 1, 622, 7,
            "poisoned same-ply entry is visible before reinitialization");
        node_init_ply[0] = 1;
        node_init_valid[0] = 1;
        #1;
        check(!node_init_ready[0],
            "same-ply stale cache cannot initialize as its own parent");
        while (!node_init_ready[0]) tick();
        tick();
        node_init_valid[0] = 0;
        check(dut.cache_ply[0] == PlyIndex'(1),
            "ungenerated node initialization takes pointer ownership");
        check(dut.cache_state[0].tops[7] == MoveBucketTop'(1),
            "ungenerated node ignores poisoned pointer-stack contents");
        start_generation(0, 0, 2);
        write_bucket[0] = 7;
        write_move[0] = Move'(631);
        write_valid[0] = 1;
        #1;
        check(write_top[0] == MoveBucketTop'(1),
            "grandchild generation inherits initialized parent tails");
        tick();
        write_valid[0] = 0;
        finish_generation(0);
        request(0, 2);
        expect_response(0, 1, 631, 7,
            "grandchild reads from initialized parent boundary");

        // If a speculative direct move is rejected, generation reuses the
        // already initialized current-ply entry.
        reset_inputs();
        start_generation(0, 0, 0);
        push(0, 7, 640);
        finish_generation(0);
        node_init_ply[0] = 1;
        node_init_valid[0] = 1;
        tick();
        node_init_valid[0] = 0;
        generation_request_thread[0] = ThreadID'(0);
        generation_request_ply[0] = PlyIndex'(1);
        generation_request_valid[0] = 1;
        #1;
        check(generation_start_ready[0],
            "initialized current ply can begin noisy generation");
        generation_start_valid[0] = 1;
        generation_start_thread[0] = ThreadID'(0);
        generation_start_ply[0] = PlyIndex'(1);
        tick();
        generation_start_valid[0] = 0;
        generation_request_valid[0] = 0;
        live_active[0] = 1;
        live_thread[0] = ThreadID'(0);
        live_ply[0] = PlyIndex'(1);
        push(0, 7, 641);
        finish_generation(0);
        request(0, 1);
        expect_response(0, 1, 641, 7,
            "current-ply generation preserves initialized boundary");

        // A reused ply in WAIT_QUIET belongs to an older node incarnation;
        // noisy generation must reload the parent rather than append to it.
        reset_inputs();
        start_generation(0, 0, 0);
        push(0, 7, 650);
        finish_generation(0);
        start_generation(0, 0, 1);
        for (int move_index = 0; move_index < 4; move_index++)
            push(0, 7, 651 + move_index);
        finish_generation(0);
        for (int move_index = 0; move_index < 4; move_index++) begin
            request(0, 1);
            expect_response(0, 1, 651 + move_index, 7,
                "old child FIFO is consumed in order");
        end
        request(0, 1);
        expect_response(0, 0, 0, 0, "old child reaches wait-quiet phase");
        start_generation(0, 0, 1);
        check(dut.cache_state[0].tops[7] == MoveBucketTop'(1),
            "same-ply re-search reloads the parent boundary");
        push(0, 7, 660);
        finish_generation(0);
        request(0, 1);
        expect_response(0, 1, 660, 7,
            "same-ply re-search starts at the parent tail");

        // Forwarding into an empty FIFO at its one-past-end boundary consumes
        // no RAM address and leaves both pointers at the boundary.
        reset_inputs();
        start_generation(0, 0, 0);
        for (int move_index = 0; move_index < 32; move_index++)
            push(0, 7, 800 + move_index);
        for (int move_index = 0; move_index < 32; move_index++) begin
            request(0, 0);
            expect_response(0, 1, 800 + move_index, 7,
                "full bucket drains in FIFO order");
        end
        request(0, 0);
        tick(2);
        check(!pop_resp_valid[0], "empty live bucket waits at capacity");
        push(0, 7, 900);
        expect_response(0, 1, 900, 7,
            "empty FIFO forwards a same-cycle incoming move");
        check(dut.cache_state[0].heads[7] == MoveBucketTop'(32)
                && dut.cache_state[0].tops[7] == MoveBucketTop'(32),
            "empty-FIFO bypass leaves both pointers unchanged");
        check(!overflow_sticky,
            "empty-FIFO bypass at capacity does not report overflow");

        // Logical reset makes stale move RAM contents unreachable.
        clear = 1;
        tick();
        clear = 0;
        tick();
        start_generation(0, 0, 0);
        finish_generation(0);
        request(0, 0);
        expect_response(0, 0, 0, 0, "clear resets pointer ownership");

        // Overflow is detected while the tail continues advancing.
        reset_inputs();
        start_generation(0, 0, 0);
        for (int move_index = 0; move_index < 34; move_index++)
            push(0, 7, 700 + move_index);
        check(overflow_sticky, "overflow sets sticky error");
        check(dut.cache_state[0].tops[7] > MoveBucketTop'(32),
            "overflow does not clamp the tail");

        $display("Pass Count: %0d", pass_count);
        $display("Fail Count: %0d", fail_count);
        if (fail_count != 0) $fatal(1, "move reader test failed");
        $finish;
    end
endmodule
