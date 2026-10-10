// DE1-SoC clocks use independent PLLs so memory frequency does not constrain search.
module pll_ip_0002 (
    input wire refclk, rst,
    output wire outclk_0, outclk_1, outclk_2, outclk_3, locked
);
    wire engine_locked, memory_locked, communication_locked;
    assign locked = engine_locked && memory_locked && communication_locked;
    altera_pll #(
        .reference_clock_frequency("@REFERENCE_MHZ@ MHz"), .operation_mode("direct"),
        .number_of_clocks(1), .output_clock_frequency0("@ENGINE_MHZ@ MHz"),
        .phase_shift0("@ENGINE_PHASE_PS@ ps"), .duty_cycle0(@ENGINE_DUTY@), .pll_type("General"), .pll_subtype("General")
    ) altera_pll_i (
        .refclk(refclk), .rst(rst), .outclk(outclk_0), .locked(engine_locked), .fbclk(1'b0), .fboutclk()
    );
    altera_pll #(
        .reference_clock_frequency("@REFERENCE_MHZ@ MHz"), .operation_mode("direct"),
        .number_of_clocks(2), .output_clock_frequency0("@MEMORY_MHZ@ MHz"),
        .phase_shift0("@MEMORY_PHASE_PS@ ps"), .duty_cycle0(@MEMORY_DUTY@),
        .output_clock_frequency1("@MEMORY_IO_MHZ@ MHz"), .phase_shift1("@MEMORY_IO_PHASE_PS@ ps"), .duty_cycle1(@MEMORY_IO_DUTY@),
        .pll_type("General"), .pll_subtype("General")
    ) memory_pll_i (
        .refclk(refclk), .rst(rst), .outclk({outclk_2, outclk_1}), .locked(memory_locked), .fbclk(1'b0), .fboutclk()
    );
    // Communications have their own frequency and reset-release domain.
    altera_pll #(
        .reference_clock_frequency("@REFERENCE_MHZ@ MHz"), .operation_mode("direct"),
        .number_of_clocks(1), .output_clock_frequency0("@COMMUNICATION_MHZ@ MHz"),
        .phase_shift0("@COMMUNICATION_PHASE_PS@ ps"), .duty_cycle0(@COMMUNICATION_DUTY@), .pll_type("General"), .pll_subtype("General")
    ) communication_pll_i (
        .refclk(refclk), .rst(rst), .outclk(outclk_3), .locked(communication_locked), .fbclk(1'b0), .fboutclk()
    );
endmodule
