import chess_defs::*;
import nnue_defs::*;

module nnue_evaluator #(
    parameter int STATE_THREAD_COUNT = THREAD_COUNT
) (
    input logic clk,
    input logic rst_n,
    input logic clear,
    input logic update_valid,
    output logic update_ready,
    output logic update_idle,
    input NnueUpdateRequest update_req,
    output logic update_done_valid,
    output ThreadID update_done_thread,
    output PlyIndex update_done_ply,
    input logic eval_valid,
    output logic eval_ready,
    input ThreadID eval_thread_id,
    input Color eval_turn,
    input PieceCount eval_piece_count,
    output logic result_valid,
    output EvalScore result
);

    // Each thread owns one live accumulator. Search stores compact move deltas
    // and applies their inverse while unwinding instead of retaining a copy per ply.
    localparam int STATE_COUNT = STATE_THREAD_COUNT;
    localparam int STATE_ADDR_BITS = (STATE_COUNT <= 1) ? 1 : $clog2(STATE_COUNT);
    localparam int ACCUMULATOR_WORD_BITS =
        NNUE_STATE_VALUE_COUNT * NNUE_ACCUMULATOR_BITS;
    localparam int OUTPUT_WEIGHT_ROW_BITS =
        NNUE_OUTPUT_MAC_LANES * NNUE_OUTPUT_WEIGHT_BITS;
    localparam int OUTPUT_WEIGHT_ROW_ADDR_BITS =
        $clog2(NNUE_OUTPUT_WEIGHT_ROW_COUNT);
    typedef logic [STATE_ADDR_BITS-1:0] StateAddress;
    typedef logic [OUTPUT_WEIGHT_ROW_ADDR_BITS-1:0] OutputWeightRowAddress;
    typedef logic signed [5:0] OutputProduct;
    typedef logic signed [6:0] PairSum;
    typedef logic signed [7:0] QuadSum;
    typedef logic signed [8:0] OctetSum;
    typedef logic signed [9:0] SixteenSum;
    typedef logic signed [10:0] ThirtyTwoSum;
    typedef logic signed [11:0] SixtyFourSum;
    typedef logic signed [12:0] MacGroupSum;
    typedef logic signed [14:0] OutputSum;

    NnueUpdateRequest active_update;
    logic update_busy;
    logic [NNUE_FEATURE_ROW_BITS-1:0] feature_row_white, feature_row_black;

    // These are generic inferred memories; the paired attributes are advisory
    // hints for Intel and AMD tools and unsupported hints may be ignored.
    // The update mirror uses distributed RAM for its wide asynchronous read,
    // while the evaluation mirror uses block RAM for its synchronous read.
    // Both copies are written together to provide two independent read ports.
    (* ramstyle = "MLAB", ram_style = "distributed" *)
    logic [ACCUMULATOR_WORD_BITS-1:0] accumulator_update_memory[STATE_COUNT];
    (* ramstyle = "no_rw_check", ram_style = "block" *)
    logic [ACCUMULATOR_WORD_BITS-1:0] accumulator_eval_memory[STATE_COUNT];
    logic [ACCUMULATOR_WORD_BITS-1:0] eval_accumulators;
    NnueOutputBucket eval_output_bucket;
    logic eval_busy;
    logic partial_pending;
    logic result_pending;
    logic [$clog2(NNUE_OUTPUT_MAC_CYCLES)-1:0] eval_cycle;
    logic [$clog2(NNUE_OUTPUT_MAC_CYCLES)-1:0] partial_cycle;
    QuadSum partial_q[32];
    OutputSum eval_sum;
    OutputSum result_sum;

    (* ram_style = "block" *)
    logic [NNUE_ROW_BYTES * 8-1:0] feature_rom[NNUE_FEATURE_COUNT];
    // Prefetch each wide weight row from block ROM while the preceding row is
    // consumed, avoiding a large bank of combinational bucket-selection muxes.
    (* ramstyle = "M10K", ram_style = "block" *)
    logic [OUTPUT_WEIGHT_ROW_BITS-1:0]
        output_weight_rows[NNUE_OUTPUT_WEIGHT_ROW_COUNT];
    OutputWeightRowAddress output_weight_row_address;
    logic [OUTPUT_WEIGHT_ROW_BITS-1:0] output_weight_row_q;
    // Keep byte-wide loader storage while only the signed low five bits enter
    // the datapath.
    logic [7:0] output_bias[NNUE_OUTPUT_BUCKET_COUNT];
    // Hex files have nibble granularity; only the signed low three bits enter
    // the datapath, avoiding loader truncation warnings without widening it.
    logic [3:0] accumulator_bias[NNUE_ACCUMULATOR_COUNT];
`ifdef FPGA_CHESS_PROFILE
    longint unsigned profile_accumulator_wrap_lanes;
`endif

    initial begin
        $readmemh("hardware/data/nnue/feature_transformer.hex", feature_rom);
        $readmemh("hardware/data/nnue/output_weights.hex", output_weight_rows);
        $readmemh("hardware/data/nnue/output_bias.hex", output_bias);
        $readmemh("hardware/data/nnue/accumulator_bias.hex", accumulator_bias);
    end

    function automatic StateAddress state_address(input ThreadID thread_id);
        return StateAddress'(thread_id);
    endfunction

    // Keep multiplication generic so each synthesis target may choose its own
    // LUT, DSP, packing, and MAC implementation.
    function automatic OutputProduct output_product(
        input logic signed [3:0] activation,
        input logic signed [NNUE_OUTPUT_WEIGHT_BITS-1:0] weight
    );
        return activation * weight;
    endfunction

    // The full-width update pipeline accepts one transformer row per cycle.
    assign update_ready = 1'b1;
    assign update_idle = !update_busy;
    // Accept a new snapshot while the preceding registered partial sums drain.
    assign eval_ready = !eval_busy || (eval_busy && partial_pending
        && partial_cycle == NNUE_OUTPUT_MAC_CYCLES - 1);

    // An accepted evaluation primes row zero. Thereafter the ROM reads one row
    // ahead so its synchronous output does not add a MAC cycle.
    always_comb begin
        output_weight_row_address = OutputWeightRowAddress'(
            int'(eval_output_bucket) * NNUE_OUTPUT_MAC_CYCLES);
        if (eval_valid && eval_ready)
            output_weight_row_address = OutputWeightRowAddress'(
                int'(nnue_output_bucket(eval_piece_count))
                    * NNUE_OUTPUT_MAC_CYCLES);
        else if (eval_busy && eval_cycle < NNUE_OUTPUT_MAC_CYCLES - 1)
            output_weight_row_address = OutputWeightRowAddress'(
                int'(eval_output_bucket) * NNUE_OUTPUT_MAC_CYCLES
                    + int'(eval_cycle) + 1);
    end

    always_ff @(posedge clk)
        output_weight_row_q <= output_weight_rows[output_weight_row_address];

    always_ff @(posedge clk) begin
        if (!rst_n || clear) begin
            update_busy <= 1'b0;
            update_done_valid <= 1'b0;
            update_done_thread <= '0;
            update_done_ply <= '0;
            eval_busy <= 1'b0;
            partial_pending <= 1'b0;
            result_pending <= 1'b0;
            result_valid <= 1'b0;
            result <= '0;
`ifdef FPGA_CHESS_PROFILE
            profile_accumulator_wrap_lanes <= 0;
`endif
        end else begin
            result_valid <= 1'b0;
            update_done_valid <= 1'b0;

            if (update_valid) begin
                active_update <= update_req;
                feature_row_white <= feature_rom[update_req.white_feature];
                feature_row_black <= feature_rom[update_req.black_feature];
            end
            update_busy <= update_valid;

            if (update_busy) begin
                automatic StateAddress destination_address =
                    state_address(active_update.thread_id);
                automatic logic [ACCUMULATOR_WORD_BITS-1:0] committed_state;
`ifdef FPGA_CHESS_PROFILE
                automatic longint unsigned wrapped_lanes = 0;
`endif
                // Chess feature deltas always affect both perspectives, so a
                // coarse request enable avoids a mux on every accumulator lane.
                if (active_update.apply) begin
                    for (int perspective = 0; perspective < 2; perspective++) begin
                        for (int lane = 0; lane < NNUE_ACCUMULATOR_COUNT; lane++) begin
                            automatic int source_bit_offset =
                                (perspective * NNUE_ACCUMULATOR_COUNT + lane)
                                    * NNUE_ACCUMULATOR_BITS;
                            automatic NnueAccumulator old_value = active_update.clear
                                ? NnueAccumulator'($signed(accumulator_bias[lane][
                                    NNUE_ACCUMULATOR_BIAS_BITS-1:0]))
                                : $signed(accumulator_update_memory[
                                    destination_address][
                                    source_bit_offset +: NNUE_ACCUMULATOR_BITS]);
                            automatic logic signed [1:0] feature_weight = perspective == 0
                                ? $signed(feature_row_white[
                                    lane * NNUE_FEATURE_WEIGHT_BITS
                                        +: NNUE_FEATURE_WEIGHT_BITS])
                                : $signed(feature_row_black[
                                    lane * NNUE_FEATURE_WEIGHT_BITS
                                        +: NNUE_FEATURE_WEIGHT_BITS]);
                            automatic NnueAccumulator changed =
                                active_update.add
                                    ? old_value + NnueAccumulator'(feature_weight)
                                    : old_value - NnueAccumulator'(feature_weight);
`ifdef FPGA_CHESS_PROFILE
                            automatic logic signed [NNUE_ACCUMULATOR_BITS:0]
                                old_extended = {old_value[NNUE_ACCUMULATOR_BITS-1], old_value};
                            automatic logic signed [NNUE_ACCUMULATOR_BITS:0]
                                weight_extended =
                                    {{(NNUE_ACCUMULATOR_BITS-1){feature_weight[1]}},
                                        feature_weight};
                            automatic logic signed [NNUE_ACCUMULATOR_BITS:0]
                                exact_changed = active_update.add
                                    ? old_extended + weight_extended
                                    : old_extended - weight_extended;
                            if (exact_changed > 6'sd15 || exact_changed < -6'sd16)
                                wrapped_lanes++;
`endif
                            committed_state[source_bit_offset
                                    +: NNUE_ACCUMULATOR_BITS] = changed;
                        end
                    end
                    accumulator_update_memory[destination_address] <= committed_state;
                    accumulator_eval_memory[destination_address] <= committed_state;
`ifdef FPGA_CHESS_PROFILE
                    profile_accumulator_wrap_lanes <=
                        profile_accumulator_wrap_lanes + wrapped_lanes;
`endif
                end
                if (active_update.complete) begin
                    update_done_valid <= 1'b1;
                    update_done_thread <= active_update.thread_id;
                    update_done_ply <= active_update.ply;
                end
            end

            // Clip from a dedicated result register so output timing is
            // independent of the fourth MAC tree.
            if (result_pending) begin
                if (result_sum > 24'sd16383)
                    result <= MAX_NON_MATE_EVAL_SCORE;
                else if (result_sum < -24'sd16383)
                    result <= -MAX_NON_MATE_EVAL_SCORE;
                else
                    result <= EvalScore'(result_sum);
                result_valid <= 1'b1;
                result_pending <= 1'b0;
            end

            if (eval_busy) begin
                automatic OutputProduct products[NNUE_OUTPUT_MAC_LANES];
                automatic PairSum pair_sums_a[32], pair_sums_b[32];
                automatic OctetSum octet_sums[16];
                automatic SixteenSum sixteen_sums[8];
                automatic ThirtyTwoSum thirty_two_sums[4];
                automatic SixtyFourSum sixty_four_sums[2];
                automatic MacGroupSum lane_sum;
                automatic OutputSum cycle_sum;
                // Register 32 four-product sums to keep the block-ROM/DSP path
                // short without adding a MAC cycle or retaining every product.
                // The drain cycle overwrites these registers with unused data;
                // unconditional writes avoid a high-fanout terminal-count enable.
                for (int lane = 0; lane < NNUE_OUTPUT_MAC_LANES; lane++) begin
                    automatic NnueAccumulator accumulator =
                        $signed(eval_accumulators[
                            lane * NNUE_ACCUMULATOR_BITS
                                +: NNUE_ACCUMULATOR_BITS]);
                    automatic logic signed [3:0] activation =
                        accumulator < 0 ? 4'sd0
                            : accumulator > NnueAccumulator'(7) ? 4'sd7
                            : {1'b0, accumulator[2:0]};
                    automatic logic signed [NNUE_OUTPUT_WEIGHT_BITS-1:0] weight =
                        $signed(output_weight_row_q[
                            lane * NNUE_OUTPUT_WEIGHT_BITS
                                +: NNUE_OUTPUT_WEIGHT_BITS]);
                    products[lane] = output_product(activation, weight);
                end
                for (int lane = 0; lane < 32; lane++) begin
                    automatic int base = 4 * lane;
                    pair_sums_a[lane] = PairSum'(products[base])
                        + PairSum'(products[base + 1]);
                    pair_sums_b[lane] = PairSum'(products[base + 2])
                        + PairSum'(products[base + 3]);
                    partial_q[lane] <= QuadSum'(pair_sums_a[lane])
                        + QuadSum'(pair_sums_b[lane]);
                end
                partial_cycle <= eval_cycle;
                partial_pending <= 1'b1;
                eval_cycle <= eval_cycle + 1'b1;
                // Advance the ordered snapshot so every MAC lane reads a fixed
                // bit slice instead of a cycle-selected four-row mux.
                eval_accumulators <= eval_accumulators
                    >> (NNUE_OUTPUT_MAC_LANES * NNUE_ACCUMULATOR_BITS);

                if (partial_pending) begin
                    for (int lane = 0; lane < 16; lane++)
                        octet_sums[lane] = OctetSum'(partial_q[2 * lane])
                            + OctetSum'(partial_q[2 * lane + 1]);
                    for (int lane = 0; lane < 8; lane++)
                        sixteen_sums[lane] = SixteenSum'(octet_sums[2 * lane])
                            + SixteenSum'(octet_sums[2 * lane + 1]);
                    for (int lane = 0; lane < 4; lane++)
                        thirty_two_sums[lane] = ThirtyTwoSum'(sixteen_sums[2 * lane])
                            + ThirtyTwoSum'(sixteen_sums[2 * lane + 1]);
                    for (int lane = 0; lane < 2; lane++)
                        sixty_four_sums[lane] = SixtyFourSum'(thirty_two_sums[2 * lane])
                            + SixtyFourSum'(thirty_two_sums[2 * lane + 1]);
                    lane_sum = MacGroupSum'(sixty_four_sums[0])
                        + MacGroupSum'(sixty_four_sums[1]);
                    cycle_sum = eval_sum + OutputSum'(lane_sum);
                    if (partial_cycle == NNUE_OUTPUT_MAC_CYCLES - 1) begin
                        result_sum <= cycle_sum;
                        result_pending <= 1'b1;
                        if (eval_valid && eval_ready) begin
                            eval_cycle <= '0;
                            eval_sum <= OutputSum'($signed(output_bias[
                                nnue_output_bucket(eval_piece_count)][
                                NNUE_OUTPUT_BIAS_BITS-1:0]));
                            partial_pending <= 1'b0;
                        end else begin
                            eval_busy <= 1'b0;
                            partial_pending <= 1'b0;
                        end
                    end else begin
                        eval_sum <= cycle_sum;
                    end
                end
            end else if (eval_valid && eval_ready) begin
                eval_cycle <= '0;
                eval_sum <= OutputSum'($signed(output_bias[
                    nnue_output_bucket(eval_piece_count)][
                    NNUE_OUTPUT_BIAS_BITS-1:0]));
                partial_pending <= 1'b0;
                eval_busy <= 1'b1;
            end

            // Keep the evaluation-memory read in one syntactic location so
            // Intel and AMD tools infer a single synchronous read port. Order
            // the two perspectives once, then shift one MAC row per cycle.
            if (eval_valid && eval_ready) begin
                automatic logic [ACCUMULATOR_WORD_BITS-1:0] selected_state;

                // A single-thread build has no other state to update while it
                // evaluates, so reuse the update mirror and avoid a very wide,
                // one-word block RAM. Multi-thread builds keep the independent
                // mirror so another thread may update concurrently.
                if (STATE_COUNT == 1)
                    selected_state = accumulator_update_memory[0];
                else
                    selected_state = accumulator_eval_memory[
                        state_address(eval_thread_id)];
                if (eval_turn == WHITE)
                    eval_accumulators <= selected_state;
                else
                    eval_accumulators <= {
                        selected_state[0 +: ACCUMULATOR_WORD_BITS / 2],
                        selected_state[ACCUMULATOR_WORD_BITS / 2
                            +: ACCUMULATOR_WORD_BITS / 2]
                    };
                eval_output_bucket <= nnue_output_bucket(eval_piece_count);
            end
        end
    end

`ifndef SYNTHESIS
    initial begin
        assert (STATE_THREAD_COUNT >= 1 && STATE_THREAD_COUNT <= THREAD_COUNT)
            else $fatal(1, "NNUE state thread count exceeds the ThreadID domain");
    end
`endif

endmodule
