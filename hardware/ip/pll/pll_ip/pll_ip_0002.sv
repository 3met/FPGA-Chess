// DE1-SoC clocks use independent PLLs so memory frequency does not constrain search.
module pll_ip_0002 (
    input wire refclk, rst,
    output wire outclk_0, outclk_1, outclk_2, outclk_3, locked
);
    wire engine_locked, memory_locked, communication_locked;
    assign locked = engine_locked && memory_locked && communication_locked;
    altera_pll #(
        .reference_clock_frequency("50.0 MHz"), .operation_mode("direct"),
        .number_of_clocks(1), .output_clock_frequency0("15.000000 MHz"),
        .phase_shift0("0 ps"), .duty_cycle0(50), .pll_type("General"), .pll_subtype("General")
    ) altera_pll_i (
        .refclk(refclk), .rst(rst), .outclk(outclk_0), .locked(engine_locked), .fbclk(1'b0), .fboutclk()
    );
    altera_pll #(
        .reference_clock_frequency("50.0 MHz"), .operation_mode("direct"),
        .number_of_clocks(2), .output_clock_frequency0("100.000000 MHz"),
        .phase_shift0("0 ps"), .duty_cycle0(50),
        .output_clock_frequency1("100.000000 MHz"), .phase_shift1("-2500 ps"), .duty_cycle1(50),
        .pll_type("General"), .pll_subtype("General")
    ) memory_pll_i (
        .refclk(refclk), .rst(rst), .outclk({outclk_2, outclk_1}), .locked(memory_locked), .fbclk(1'b0), .fboutclk()
    );
    // Communications have their own frequency and reset-release domain.
    altera_pll #(
        .reference_clock_frequency("50.0 MHz"), .operation_mode("direct"),
        .number_of_clocks(1), .output_clock_frequency0("100.000000 MHz"),
        .phase_shift0("0 ps"), .duty_cycle0(50), .pll_type("General"), .pll_subtype("General")
    ) communication_pll_i (
        .refclk(refclk), .rst(rst), .outclk(outclk_3), .locked(communication_locked), .fbclk(1'b0), .fboutclk()
    );
endmodule
