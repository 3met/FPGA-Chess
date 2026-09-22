// One thread's move RAM; bucket and ply pointers live outside the memory.
import chess_defs::*;
import move_generator_defs::*;

module move_generator_bucket_store #(
    parameter int MEMORY_ENTRIES = 2048,
    parameter int CAPACITIES[MOVE_BUCKET_COUNT] = '{192, 64, 768, 256, 256, 128, 256, 128}
) (
    input logic clk,
    input logic wr_valid,
    input Move wr_move,
    input MoveBucketIndex wr_bucket,
    input MoveBucketTop wr_top,
    input logic rd_valid,
    input MoveBucketIndex rd_bucket,
    input MoveBucketTop rd_top,
    output Move rd_move
);
    localparam int ADDRESS_BITS = $clog2(MEMORY_ENTRIES);
    logic [ADDRESS_BITS-1:0] wr_address, rd_address;

    // Fixed unequal partitions need only constant offsets, with no allocation RAM.
    function automatic logic [ADDRESS_BITS-1:0] address(
        input MoveBucketIndex bucket, input MoveBucketTop top
    );
        automatic int offset = 0;
        for (int index = 0; index < MOVE_BUCKET_COUNT; index++)
            if (index < int'(bucket)) offset += CAPACITIES[index];
        return ADDRESS_BITS'(offset + int'(top));
    endfunction

    assign wr_address = address(wr_bucket, wr_top);
    assign rd_address = address(rd_bucket, rd_top);
    sync_read_simple_dual_port_ram #(
        .NUM_WORDS(MEMORY_ENTRIES), .WORD_SIZE($bits(Move))
    ) move_ram (
        .clock(clk), .data(wr_move), .wraddress(wr_address), .wren(wr_valid),
        .rdaddress(rd_address), .rden(rd_valid), .q(rd_move)
    );
endmodule : move_generator_bucket_store
