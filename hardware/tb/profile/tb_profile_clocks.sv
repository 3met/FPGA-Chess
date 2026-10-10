`timescale 1ns/1ps

// Constant folding must preserve signed phase shifts on every simulator.
module tb_profile_clocks;
    `include "hardware/tb/profile/clock_math.svh"
    localparam int ADVANCED_PHASE = normalized_phase_ps(-100, 16666);
    localparam int DELAYED_PHASE = normalized_phase_ps(200, 7500);
    localparam int MULTI_PERIOD_PHASE = normalized_phase_ps(-15100, 7500);
    localparam int FULL_PERIOD_PHASE = normalized_phase_ps(-7500, 7500);
    localparam int ZERO_PHASE = normalized_phase_ps(0, 7500);
    localparam int SLOW_CLOCK_HIGH = clock_high_ps(1000000000, 55);
    localparam int FRACTIONAL_HIGH = clock_high_ps(16666, 45);
    localparam int MINIMUM_DUTY_HIGH = clock_high_ps(1000, 1);
    initial begin
        if (ADVANCED_PHASE != 16566 || DELAYED_PHASE != 200
                || MULTI_PERIOD_PHASE != 7400 || FULL_PERIOD_PHASE != 0 || ZERO_PHASE != 0)
            $fatal(1, "Clock phase normalization changed during constant folding");
        if (SLOW_CLOCK_HIGH != 550000000 || FRACTIONAL_HIGH != 7500 || MINIMUM_DUTY_HIGH != 10)
            $fatal(1, "Clock duty calculation overflowed or rounded incorrectly");
        $display("Pass Count: 8");
        $display("Fail Count: 0");
        $finish;
    end
endmodule
