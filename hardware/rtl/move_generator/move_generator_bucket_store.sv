// Per-lane move-bucket RAM ownership and addressing.

import chess_defs::*;
import move_generator_defs::*;

module move_generator_bucket_store #(
    parameter int THREAD_COUNT = 1,
    parameter int BUCKET_0_CAPACITY = 512,
    parameter int BUCKET_1_CAPACITY = 512,
    parameter int BUCKET_2_CAPACITY = 1024,
    parameter int BUCKET_3_CAPACITY = 512,
    parameter int BUCKET_4_CAPACITY = 512,
    parameter int BUCKET_5_CAPACITY = 512,
    parameter int BUCKET_6_CAPACITY = 512,
    parameter int BUCKET_7_CAPACITY = 512,
    parameter MoveBucketMask OWNED_BUCKETS = MoveBucketMask'(0)
) (
    input logic clk,
    input logic wr_en[MOVE_BUCKET_COUNT],
    input Move wr_data,
    input ThreadID wr_thread,
    input MoveBucketTop wr_top,
    input logic rd_en[MOVE_BUCKET_COUNT],
    input ThreadID rd_thread,
    input MoveBucketTop rd_top,
    output Move rd_data[MOVE_BUCKET_COUNT]
);

    function automatic int bucket_capacity(input int bucket);
        case (bucket)
            0: return BUCKET_0_CAPACITY;
            1: return BUCKET_1_CAPACITY;
            2: return BUCKET_2_CAPACITY;
            3: return BUCKET_3_CAPACITY;
            4: return BUCKET_4_CAPACITY;
            5: return BUCKET_5_CAPACITY;
            6: return BUCKET_6_CAPACITY;
            default: return BUCKET_7_CAPACITY;
        endcase
    endfunction

    genvar bucket_gen;
    generate
        for (bucket_gen = 0; bucket_gen < MOVE_BUCKET_COUNT; bucket_gen++) begin : gen_bucket
            localparam int CAPACITY = bucket_capacity(bucket_gen);
            localparam int WORDS = THREAD_COUNT * CAPACITY;
            localparam int ADDR_BITS = (WORDS <= 1) ? 1 : $clog2(WORDS);
            if (OWNED_BUCKETS[bucket_gen]) begin : gen_owned
                logic [ADDR_BITS-1:0] rd_addr;
                logic [ADDR_BITS-1:0] wr_addr;

                always_comb begin
                    rd_addr = ADDR_BITS'(int'(rd_thread) * CAPACITY + int'(rd_top));
                    wr_addr = ADDR_BITS'(int'(wr_thread) * CAPACITY + int'(wr_top));
                end

                sync_read_simple_dual_port_ram #(
                    .NUM_WORDS(WORDS),
                    .WORD_SIZE($bits(Move))
                ) move_ram (
                    .clock(clk),
                    .data(wr_data),
                    .rdaddress(rd_addr),
                    .rden(rd_en[bucket_gen]),
                    .wraddress(wr_addr),
                    .wren(wr_en[bucket_gen]),
                    .q(rd_data[bucket_gen])
                );

`ifndef SYNTHESIS
                always_ff @(posedge clk) begin
                    if (wr_en[bucket_gen] && rd_en[bucket_gen])
                        assert (wr_addr != rd_addr)
                            else $error("simultaneous move-bucket read/write address collision");
                end
`endif
            end else begin : gen_unowned
                assign rd_data[bucket_gen] = NULL_MOVE;
            end
        end
    endgenerate

endmodule : move_generator_bucket_store

