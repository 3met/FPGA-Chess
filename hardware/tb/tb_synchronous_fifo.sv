`timescale 1ns/1ps

// Check the public ready/valid contract against an independent transaction queue.
module synchronous_fifo_case #(parameter int DEPTH = 3) (
    output bit done = 0,
    output int pass_count = 0,
    output int fail_count = 0
);
    logic clk = 0, rst_n = 0, clear = 0;
    logic push_valid = 0, push_ready, pop_valid, pop_ready = 0;
    logic [15:0] push_data = 0, pop_data;
    logic [$clog2(DEPTH+1)-1:0] count;
    logic [15:0] expected[$];
    int simultaneous = 0, blocked_pushes = 0, empty_reads = 0;
    int next_word = 1;
    logic [31:0] random_state = 32'hcafe1234;
    always #5 clk = ~clk;
    synchronous_fifo #(.DATA_WIDTH(16), .DEPTH(DEPTH)) dut (.*);

    // Include geometry in failures so concurrently running fixtures are identifiable.
    task automatic check(input logic condition, input string label);
        if (condition) pass_count++;
        else begin
            fail_count++;
            $error("depth=%0d: %s", DEPTH, label);
        end
    endtask

    // Sample handshakes before the active edge, then check settled occupancy.
    task automatic cycle(input bit send, input bit receive, input bit discard = 0);
        bit accepted_push, accepted_pop, held;
        logic [15:0] head, removed;
        @(negedge clk);
        push_valid = send;
        pop_ready = receive;
        clear = discard;
        push_data = 16'(next_word);
        #1;
        check(int'(count) == expected.size(), "occupancy matches accepted transactions");
        check(push_ready == (expected.size() < DEPTH), "ready reflects available capacity");
        if (pop_valid) begin
            check(expected.size() > 0, "no unsolicited output");
            if (expected.size() > 0) check(pop_data === expected[0], "oldest word is visible");
        end
        accepted_push = send && push_ready;
        accepted_pop = receive && pop_valid;
        held = pop_valid && !receive && !discard;
        head = pop_data;
        if (discard) expected.delete();
        else begin
            if (accepted_pop) removed = expected.pop_front();
            if (accepted_push) begin
                expected.push_back(push_data);
                next_word++;
            end
            if (accepted_push && accepted_pop) simultaneous++;
            if (send && !push_ready) blocked_pushes++;
            if (receive && !pop_valid) empty_reads++;
        end
        @(posedge clk); #1;
        check(int'(count) == expected.size(), "occupancy updates exactly once");
        if (held) check(pop_valid && pop_data === head, "stalled payload remains stable");
        if (discard) check(!pop_valid, "clear cancels buffered and pending output");
    endtask

    initial begin
        repeat (2) @(negedge clk);
        rst_n = 1;
        // Underflow, overflow, and sustained overlap exercise every pointer wrap.
        repeat (3) cycle(0, 1);
        repeat (DEPTH+4) cycle(1, 0);
        repeat (DEPTH*8) cycle(1, 1);
        repeat (DEPTH*4+4) cycle(0, 1);
        check(expected.size() == 0 && !pop_valid, "directed drain completes");

        // Cancel immediately after a write and while a prefetched head is held.
        cycle(1, 0);
        cycle(1, 1, 1);
        repeat (DEPTH+4) cycle(1, 0);
        cycle(1, 1, 1);
        repeat (DEPTH*4+4) cycle(0, 1);
        check(expected.size() == 0 && !pop_valid, "cleared words cannot reappear");

        // Fixed LFSR traffic provides reproducible stalls, overlap, and clears.
        repeat (400) begin
            random_state = {random_state[30:0], random_state[31] ^ random_state[21]
                ^ random_state[1] ^ random_state[0]};
            cycle(random_state[0], random_state[4], random_state[9:5] == 0);
        end
        repeat (DEPTH*4+4) cycle(0, 1);
        check(expected.size() == 0 && !pop_valid, "all accepted words drain");
        check(simultaneous > 0 && blocked_pushes > 0 && empty_reads > 0,
            "traffic covers overlap and both capacity boundaries");
        done = 1;
    end
endmodule

module tb_synchronous_fifo;
    wire [2:0] done;
    wire signed [31:0] passes[3], failures[3];
    synchronous_fifo_case #(.DEPTH(2)) minimum_case(done[0], passes[0], failures[0]);
    synchronous_fifo_case #(.DEPTH(3)) odd_case(done[1], passes[1], failures[1]);
    synchronous_fifo_case #(.DEPTH(8)) power_of_two_case(done[2], passes[2], failures[2]);
    initial begin
        wait (&done);
        $display("Pass Count: %0d", passes[0]+passes[1]+passes[2]);
        $display("Fail Count: %0d", failures[0]+failures[1]+failures[2]);
        if (failures[0]+failures[1]+failures[2] != 0) $fatal(1, "FIFO checks failed");
        $finish;
    end
    initial begin
        #100_000;
        $fatal(1, "synchronous FIFO test timed out");
    end
endmodule
