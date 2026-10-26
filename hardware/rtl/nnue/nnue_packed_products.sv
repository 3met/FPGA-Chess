// Four signed four-bit weight products share two unsigned 18x18 multipliers.
// The Cyclone V target keeps the entire group in one physical DSP block.
module nnue_packed_products (
    input logic [15:0] activations,
    input logic [15:0] weights,
    output logic [31:0] products
);
    logic [35:0] packed_activations, packed_magnitudes;
    wire [71:0] magnitude_products;

    // In base 256, the cross term is <= 2*15*8 = 240, so it cannot
    // carry into the high product. Each outer product is at most 120.
    genvar pair_index;
    generate
        for (pair_index = 0; pair_index < 2; pair_index = pair_index + 1) begin : gen_pair
            wire signed [3:0] weight_a = weights[pair_index * 8 +: 4];
            wire signed [3:0] weight_b = weights[pair_index * 8 + 4 +: 4];
            wire [3:0] magnitude_a = weight_a < 0 ? 4'(-weight_a) : 4'(weight_a);
            wire [3:0] magnitude_b = weight_b < 0 ? 4'(-weight_b) : 4'(weight_b);
            wire signed [7:0] product_a = $signed(magnitude_products[pair_index * 36 +: 8]);
            wire signed [7:0] product_b = $signed(magnitude_products[pair_index * 36 + 16 +: 8]);
            assign packed_activations[pair_index * 18 +: 18] = {6'b0,
                activations[pair_index * 8 + 4 +: 4], 4'b0,
                activations[pair_index * 8 +: 4]};
            assign packed_magnitudes[pair_index * 18 +: 18] = {6'b0, magnitude_b, 4'b0, magnitude_a};
            assign products[pair_index * 16 +: 8] = weight_a < 0 ? -product_a : product_a;
            assign products[pair_index * 16 + 8 +: 8] = weight_b < 0 ? -product_b : product_b;
        end
    endgenerate

`ifdef FPGA_CHESS_CYCLONE_V
    // A whole-block primitive prevents the fitter from spreading independent
    // 18x18 operations across spare DSPs. Unused primitive ports stay disconnected.
    cyclonev_mac #(
        .operation_mode("m18x18_full"),
        .ax_width(18),
        .ay_scan_in_width(18),
        .bx_width(18), .by_width(18),
        .result_a_width(36), .result_b_width(36)
    ) dsp (
        .ax(packed_activations[17:0]),
        .ay(packed_magnitudes[17:0]),
        .bx(packed_activations[35:18]), .by(packed_magnitudes[35:18]),
        .resulta(magnitude_products[35:0]), .resultb(magnitude_products[71:36]),
        .az(), .bz(), .coefsela(), .coefselb(),
        .scanin(), .chainin(), .loadconst(), .accumulate(), .negate(), .sub(),
        .clk(), .ena(), .aclr(), .scanout(), .chainout(), .dftout()
    );
`else
    // Portable arithmetic for simulation and other FPGA families.
    genvar multiplier_index;
    generate
        for (multiplier_index = 0; multiplier_index < 2; multiplier_index = multiplier_index + 1) begin : gen_multiply
            assign magnitude_products[multiplier_index * 36 +: 36] =
                packed_activations[multiplier_index * 18 +: 18]
                * packed_magnitudes[multiplier_index * 18 +: 18];
        end
    endgenerate
`endif
endmodule
