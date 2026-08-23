// Definitions for streamed move generation and bucketed move ordering.
package move_generator_defs;

    import general_chess_defs::*;

    localparam int MOVE_BUCKET_COUNT = 8;
    // Bucket tops include the one-past-last value for the 1,024-entry low
    // quiet partition, so they require one more bit than its address.
    localparam int MOVE_BUCKET_TOP_BITS = 11;

    typedef logic [2:0] MoveBucketIndex;
    typedef logic [MOVE_BUCKET_TOP_BITS-1:0] MoveBucketTop;
    typedef logic [MOVE_BUCKET_COUNT-1:0][MOVE_BUCKET_TOP_BITS-1:0] MoveBucketTops;
    typedef logic [MOVE_BUCKET_COUNT-1:0] MoveBucketMask;

    localparam MoveBucketIndex BAD_NOISY_LOW_BUCKET = MoveBucketIndex'(0);
    localparam MoveBucketIndex BAD_NOISY_HIGH_BUCKET = MoveBucketIndex'(1);
    localparam MoveBucketIndex QUIET_LOW_BUCKET = MoveBucketIndex'(2);
    localparam MoveBucketIndex QUIET_MEDIUM_BUCKET = MoveBucketIndex'(3);
    localparam MoveBucketIndex QUIET_HIGH_BUCKET = MoveBucketIndex'(4);
    localparam MoveBucketIndex QUIET_HIGHEST_BUCKET = MoveBucketIndex'(5);
    localparam MoveBucketIndex GOOD_NOISY_LOW_BUCKET = MoveBucketIndex'(6);
    localparam MoveBucketIndex GOOD_NOISY_HIGH_BUCKET = MoveBucketIndex'(7);

    localparam MoveBucketMask GOOD_NOISY_BUCKET_MASK = MoveBucketMask'(8'b1100_0000);
    localparam MoveBucketMask QUIET_BUCKET_MASK = MoveBucketMask'(8'b0011_1100);
    localparam MoveBucketMask BAD_NOISY_BUCKET_MASK = MoveBucketMask'(8'b0000_0011);
    localparam MoveBucketMask ALL_BUCKET_MASK = MoveBucketMask'('1);

    typedef enum logic [1:0] {
        MOVE_GEN_VALIDATE_DIRECT,
        MOVE_GEN_GENERATE_NOISY,
        MOVE_GEN_GENERATE_QUIET
    } MoveGenCommand;

    typedef enum logic [2:0] {
        MOVE_ORDER_DIRECT,
        MOVE_ORDER_GENERATE_NOISY,
        MOVE_ORDER_GOOD_NOISY,
        MOVE_ORDER_GENERATE_QUIET,
        MOVE_ORDER_QUIET,
        MOVE_ORDER_BAD_NOISY,
        MOVE_ORDER_DONE
    } MoveOrderState;

    typedef struct packed {
        Tile tile;
        logic [2:0] distance;
    } RayRecord;

    localparam RayRecord NULL_RAY = RayRecord'({EMPTY_TILE, 3'd0});

endpackage : move_generator_defs
