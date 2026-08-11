// Assert reset asynchronously and release it through the minimum safe local-clock synchronizer.
module reset_release #(
    parameter int SYNC_STAGES = 2
) (
    input logic clk,
    input logic async_reset_n,
    output logic reset_n
);

    logic [SYNC_STAGES-1:0] release_pipe = '0;

    initial begin
        if (SYNC_STAGES < 2) begin
            $error("reset_release SYNC_STAGES must be at least two");
        end
    end

    always_ff @(posedge clk or negedge async_reset_n) begin
        if (!async_reset_n) begin
            release_pipe <= '0;
        end else begin
            release_pipe <= {release_pipe[SYNC_STAGES-2:0], 1'b1};
        end
    end

    assign reset_n = release_pipe[SYNC_STAGES-1];

endmodule : reset_release


// Start and monitor a PLL with one long LFSR delay reused across every startup phase.
module pll_startup_controller #(
    parameter int DELAY_BITS = 20,
    parameter int FEEDBACK_TAP = 16
) (
    input logic clk,
    input logic reset_n,
    input logic restart_n,
    input logic pll_locked,
    output logic pll_reset = 1'b1,
    output logic clocks_ready
);

    localparam logic [DELAY_BITS-1:0] DELAY_SEED = {{DELAY_BITS-1{1'b0}}, 1'b1};

    typedef enum logic [1:0] {
        PLL_HOLD_RESET,
        PLL_WAIT_LOCK,
        PLL_VERIFY_LOCK,
        PLL_RUNNING
    } PllStartupState;

    PllStartupState state = PLL_HOLD_RESET;
    logic [DELAY_BITS-1:0] delay_lfsr = DELAY_SEED;
    logic [DELAY_BITS-1:0] delay_lfsr_next;
    logic pll_locked_meta = 1'b0;
    logic pll_locked_sync = 1'b0;
    logic delay_done;

    initial begin
        if (DELAY_BITS < 3 || FEEDBACK_TAP < 0 || FEEDBACK_TAP >= DELAY_BITS - 1) begin
            $error("pll_startup_controller needs valid LFSR width and feedback tap parameters");
        end
    end

    // The production x^20+x^17+1 polynomial visits every nonzero state.
    // Reusing its roughly 21 ms period avoids an adder and phase-specific counters.
    assign delay_done = delay_lfsr == {1'b1, {DELAY_BITS-1{1'b0}}};
    assign delay_lfsr_next = {delay_lfsr[DELAY_BITS-2:0],
        delay_lfsr[DELAY_BITS-1] ^ delay_lfsr[FEEDBACK_TAP]};

    // Synchronize the asynchronous lock indication before using it for startup decisions.
    always_ff @(posedge clk) begin
        if (!reset_n) begin
            pll_locked_meta <= 1'b0;
            pll_locked_sync <= 1'b0;
        end else begin
            pll_locked_meta <= pll_locked;
            pll_locked_sync <= pll_locked_meta;
        end
    end

    always_ff @(posedge clk) begin
        if (!reset_n || !restart_n) begin
            state <= PLL_HOLD_RESET;
            delay_lfsr <= DELAY_SEED;
            pll_reset <= 1'b1;
        end else begin
            case (state)
                PLL_HOLD_RESET: begin
                    pll_reset <= 1'b1;
                    if (delay_done) begin
                        delay_lfsr <= DELAY_SEED;
                        pll_reset <= 1'b0;
                        state <= PLL_WAIT_LOCK;
                    end else begin
                        delay_lfsr <= delay_lfsr_next;
                    end
                end

                PLL_WAIT_LOCK: begin
                    pll_reset <= 1'b0;
                    if (pll_locked_sync) begin
                        delay_lfsr <= DELAY_SEED;
                        state <= PLL_VERIFY_LOCK;
                    end else if (delay_done) begin
                        delay_lfsr <= DELAY_SEED;
                        pll_reset <= 1'b1;
                        state <= PLL_HOLD_RESET;
                    end else begin
                        delay_lfsr <= delay_lfsr_next;
                    end
                end

                PLL_VERIFY_LOCK: begin
                    pll_reset <= 1'b0;
                    if (!pll_locked_sync) begin
                        delay_lfsr <= DELAY_SEED;
                        state <= PLL_WAIT_LOCK;
                    end else if (delay_done) begin
                        delay_lfsr <= DELAY_SEED;
                        state <= PLL_RUNNING;
                    end else begin
                        delay_lfsr <= delay_lfsr_next;
                    end
                end

                PLL_RUNNING: begin
                    pll_reset <= 1'b0;
                    delay_lfsr <= DELAY_SEED;
                    if (!pll_locked_sync) begin
                        pll_reset <= 1'b1;
                        state <= PLL_HOLD_RESET;
                    end
                end

                default: begin
                    state <= PLL_HOLD_RESET;
                    delay_lfsr <= DELAY_SEED;
                    pll_reset <= 1'b1;
                end
            endcase
        end
    end

    assign clocks_ready = state == PLL_RUNNING;

endmodule : pll_startup_controller
