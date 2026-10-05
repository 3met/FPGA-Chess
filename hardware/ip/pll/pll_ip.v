// Board-specific Intel PLL wrapper; build tooling configures the implementation.
module pll_ip (
    input wire refclk, rst,
    output wire outclk_0, outclk_1, outclk_2, outclk_3, locked
);
    pll_ip_0002 pll_ip_inst (
        .refclk(refclk), .rst(rst), .outclk_0(outclk_0), .outclk_1(outclk_1),
        .outclk_2(outclk_2), .outclk_3(outclk_3), .locked(locked)
    );
endmodule
