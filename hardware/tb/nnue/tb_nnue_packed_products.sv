`timescale 1ns/1ps
module tb_nnue_packed_products;
    logic [15:0] activations, weights;
    wire [31:0] products;
    int pass_count = 0;
    int fail_count = 0;
    nnue_packed_products dut (.activations, .weights, .products);

    // Exhaust each pair's full domain with different values in the other pairs,
    // checking both arithmetic and ordering against independent scalar products.
    initial begin
        for (int a = 0; a < 16; a++)
            for (int b = 0; b < 16; b++)
                for (int wa = 0; wa < 16; wa++)
                    for (int wb = 0; wb < 16; wb++) begin
                        for (int pair_index = 0; pair_index < 2; pair_index++) begin
                            activations[pair_index * 8 +: 4] = 4'(a + pair_index);
                            activations[pair_index * 8 + 4 +: 4] = 4'(b + 3 * pair_index);
                            weights[pair_index * 8 +: 4] = 4'(wa + pair_index);
                            weights[pair_index * 8 + 4 +: 4] = 4'(wb + 3 * pair_index);
                        end
                        #1;
                        for (int lane = 0; lane < 4; lane++) begin
                            automatic int expected = int'(activations[lane * 4 +: 4])
                                * int'($signed(weights[lane * 4 +: 4]));
                            if (int'($signed(products[lane * 8 +: 8])) === expected)
                                pass_count++;
                            else begin
                                fail_count++;
                                $error("lane %0d: expected %0d, got %0d", lane,
                                    expected, $signed(products[lane * 8 +: 8]));
                            end
                        end
                    end
        $display("Pass Count: %0d", pass_count);
        $display("Fail Count: %0d", fail_count);
        if (fail_count != 0) $fatal(1, "Packed NNUE products failed");
        $finish;
    end
endmodule
