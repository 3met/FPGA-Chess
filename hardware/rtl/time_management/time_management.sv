// By Emet Behrendt

import chess_defs::*;

// Owns elapsed-time measurement and the infrequent arithmetic used to allocate
// clock-search budgets. Setup and adaptive requests are accepted only while idle.
module time_management #(
    parameter int CLOCK_FREQ = 100_000_000,
    parameter int MOVES_TO_GO_BUFFER = 2,
    parameter int DEFAULT_MOVES_DIVISOR = 20,
    parameter int INCREMENT_NUMERATOR = 4,
    parameter int INCREMENT_DENOMINATOR = 5,
    parameter int HARD_BASE_MULTIPLIER = 4,
    parameter int HARD_TIME_NUMERATOR = 4,
    parameter int HARD_TIME_DENOMINATOR = 5,
    parameter int SOFT_FACTOR_DEFAULT = 4,
    parameter int NEXT_DEPTH_NUMERATOR = 3,
    parameter int NEXT_DEPTH_DENOMINATOR = 5,
    parameter int SINGLE_LEGAL_MOVE_MS = 10
) (
    input logic clk,
    input logic rst_n,
    input logic cancel,
    input logic timer_reset,
    input logic timer_run,
    output TimeType elapsed_ms,

    input logic setup_start,
    input logic setup_fixed_time,
    input logic setup_clock_time,
    input TimeType time_limit,
    input TimeType move_overhead,
    input TimeType remaining_time,
    input TimeType clock_increment,
    input logic [15:0] moves_to_go,

    input logic adaptive_start,
    input logic [TIME_BITS+1:0] adaptive_base_ms,
    input TimeType adaptive_hard_ms,
    input logic [3:0] adaptive_factor,
    input logic adaptive_single_legal_move,

    output logic busy,
    output logic done,
    output logic [TIME_BITS+1:0] base_ms,
    output TimeType soft_ms,
    output TimeType next_depth_ms,
    output TimeType hard_ms
);

    typedef enum logic [3:0] {
        TM_IDLE,
        TM_BASE_START,
        TM_BASE_WAIT,
        TM_INCREMENT_WAIT,
        TM_HARD_START,
        TM_HARD_WAIT,
        TM_ADAPT_SOFT_START,
        TM_ADAPT_SOFT_WAIT,
        TM_ADAPT_THRESHOLD_WAIT
    } TimeManagementState;

    TimeManagementState state;
    logic div_start;
    logic divider_busy;
    logic [31:0] div_numerator;
    logic [31:0] div_denominator;
    logic div_done;
    logic [31:0] div_quotient;
    TimeType usable_time;
    TimeType increment;
    logic [16:0] clock_divisor;
    logic [31:0] clock_share;
    logic [31:0] base_candidate;
    logic adaptive_single_move_q;

    assign busy = state != TM_IDLE || divider_busy;

`ifndef SYNTHESIS
    initial begin
        if (INCREMENT_DENOMINATOR < 1 || HARD_TIME_DENOMINATOR < 1
                || SOFT_FACTOR_DEFAULT < 1 || NEXT_DEPTH_DENOMINATOR < 1
                || DEFAULT_MOVES_DIVISOR < 1)
            $fatal(1, "time-management denominators must be positive");
        if (DEFAULT_MOVES_DIVISOR > 131071)
            $fatal(1, "default moves divisor must fit the runtime divisor");
        if (MOVES_TO_GO_BUFFER < 0 || MOVES_TO_GO_BUFFER > 65535)
            $fatal(1, "moves-to-go buffer must fit the runtime divisor");
    end
`endif

`ifndef SYNTHESIS
    always_ff @(posedge clk) begin
        if (rst_n && !cancel) begin
            assert (!(setup_start && adaptive_start))
                else $fatal(1, "time-management requests must be mutually exclusive");
            assert (!(busy && (setup_start || adaptive_start)))
                else $fatal(1, "time-management request issued while busy");
        end
    end
`endif

    timer #(
        .CLOCK_FREQ(CLOCK_FREQ)
    ) elapsed_timer (
        .clk(clk),
        .rst(timer_reset),
        .run(timer_run),
        .time_ms(elapsed_ms)
    );

    unsigned_iterative_divider #(
        .WIDTH(32)
    ) budget_divider (
        .clk(clk),
        .rst_n(rst_n),
        .cancel(cancel),
        .start(div_start),
        .numerator(div_numerator),
        .denominator(div_denominator),
        .busy(divider_busy),
        .done(div_done),
        .quotient(div_quotient)
    );

    // Cap a scaled soft budget before deriving the next-depth threshold from it.
    function automatic TimeType cap_soft_budget(
        input logic [31:0] scaled,
        input TimeType hard_limit,
        input logic exactly_one_move
    );
        automatic TimeType result;
        result = (scaled > hard_limit) ? hard_limit : TimeType'(scaled);
        if (exactly_one_move && result > TimeType'(SINGLE_LEGAL_MOVE_MS))
            result = TimeType'(SINGLE_LEGAL_MOVE_MS);
        return result;
    endfunction : cap_soft_budget

    always_ff @(posedge clk) begin
        if (!rst_n) begin
            state <= TM_IDLE;
            done <= 1'b0;
            div_start <= 1'b0;
            div_numerator <= 32'd0;
            div_denominator <= 32'd1;
            usable_time <= TimeType'(0);
            increment <= TimeType'(0);
            clock_divisor <= 17'd1;
            clock_share <= 32'd0;
            base_candidate <= 32'd0;
            adaptive_single_move_q <= 1'b0;
            base_ms <= '0;
            soft_ms <= TimeType'(0);
            next_depth_ms <= TimeType'(0);
            hard_ms <= TimeType'(0);
        end else if (cancel) begin
            state <= TM_IDLE;
            done <= 1'b0;
            div_start <= 1'b0;
        end else begin
            done <= 1'b0;
            div_start <= 1'b0;
            case (state)
                TM_IDLE: begin
                    if (setup_start) begin
                        automatic TimeType usable;
                        usable = (remaining_time > move_overhead)
                            ? remaining_time - move_overhead : TimeType'(0);
                        if (setup_fixed_time) begin
                            automatic TimeType fixed_budget;
                            fixed_budget = (time_limit > move_overhead)
                                ? time_limit - move_overhead : TimeType'(0);
                            base_ms <= (TIME_BITS+2)'(fixed_budget);
                            soft_ms <= fixed_budget;
                            next_depth_ms <= fixed_budget;
                            hard_ms <= fixed_budget;
                            done <= 1'b1;
                        end else if (setup_clock_time) begin
                            usable_time <= usable;
                            increment <= clock_increment;
                            clock_divisor <= moves_to_go != 16'd0
                                ? {1'b0, moves_to_go} + 17'(MOVES_TO_GO_BUFFER)
                                : 17'(DEFAULT_MOVES_DIVISOR);
                            state <= TM_BASE_START;
                        end else begin
                            base_ms <= '1;
                            soft_ms <= TimeType'('1);
                            next_depth_ms <= TimeType'('1);
                            hard_ms <= TimeType'('1);
                            done <= 1'b1;
                        end
                    end else if (adaptive_start) begin
                        base_ms <= adaptive_base_ms;
                        hard_ms <= adaptive_hard_ms;
                        adaptive_single_move_q <= adaptive_single_legal_move;
                        div_numerator <= 32'(adaptive_base_ms) * adaptive_factor;
                        div_denominator <= 32'(SOFT_FACTOR_DEFAULT);
                        state <= TM_ADAPT_SOFT_START;
                    end
                end

                TM_BASE_START: begin
                    div_numerator <= 32'(usable_time);
                    div_denominator <= 32'(clock_divisor);
                    div_start <= 1'b1;
                    state <= TM_BASE_WAIT;
                end

                TM_BASE_WAIT: begin
                    if (div_done) begin
                        clock_share <= div_quotient;
                        div_numerator <= 32'(increment) * INCREMENT_NUMERATOR;
                        div_denominator <= 32'(INCREMENT_DENOMINATOR);
                        div_start <= 1'b1;
                        state <= TM_INCREMENT_WAIT;
                    end
                end

                TM_INCREMENT_WAIT: begin
                    if (div_done) begin
                        base_candidate <= clock_share + div_quotient;
                        state <= TM_HARD_START;
                    end
                end

                TM_HARD_START: begin
                    base_ms <= (TIME_BITS+2)'(base_candidate);
                    soft_ms <= TimeType'(base_candidate);
                    next_depth_ms <= TimeType'(0);
                    div_numerator <= 32'(usable_time) * HARD_TIME_NUMERATOR;
                    div_denominator <= 32'(HARD_TIME_DENOMINATOR);
                    div_start <= 1'b1;
                    state <= TM_HARD_WAIT;
                end

                TM_HARD_WAIT: begin
                    if (div_done) begin
                        hard_ms <= ((base_candidate * HARD_BASE_MULTIPLIER) < div_quotient)
                            ? TimeType'(base_candidate * HARD_BASE_MULTIPLIER)
                            : TimeType'(div_quotient);
                        done <= 1'b1;
                        state <= TM_IDLE;
                    end
                end

                TM_ADAPT_SOFT_START: begin
                    div_start <= 1'b1;
                    state <= TM_ADAPT_SOFT_WAIT;
                end

                TM_ADAPT_SOFT_WAIT: begin
                    if (div_done) begin
                        automatic TimeType capped_soft;
                        capped_soft = cap_soft_budget(
                            div_quotient, hard_ms, adaptive_single_move_q);
                        soft_ms <= capped_soft;
                        div_numerator <= 32'(capped_soft) * NEXT_DEPTH_NUMERATOR;
                        div_denominator <= 32'(NEXT_DEPTH_DENOMINATOR);
                        div_start <= 1'b1;
                        state <= TM_ADAPT_THRESHOLD_WAIT;
                    end
                end

                TM_ADAPT_THRESHOLD_WAIT: begin
                    if (div_done) begin
                        next_depth_ms <= TimeType'(div_quotient);
                        done <= 1'b1;
                        state <= TM_IDLE;
                    end
                end

                default: state <= TM_IDLE;
            endcase
        end
    end

endmodule : time_management
