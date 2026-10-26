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
    input PstEvalPair eval_pst,
    output logic result_valid,
    output NnueCorrection result,
    output PstEvalScore result_pst
);

    localparam int SIDE_ROWS = NNUE_ACCUMULATOR_COUNT / NNUE_OUTPUT_MAC_LANES;
    localparam int STATE_ROWS = 2 * SIDE_ROWS;
    localparam int WORD_BITS = NNUE_OUTPUT_MAC_LANES * NNUE_ACCUMULATOR_BITS;
    localparam int FEATURE_WORD_BITS = NNUE_OUTPUT_MAC_LANES * NNUE_FEATURE_WEIGHT_BITS;
    localparam int BANK_ROWS = NNUE_FEATURE_BANK_ROW_COUNT * SIDE_ROWS;
    localparam int BIAS_BASE = STATE_THREAD_COUNT * STATE_ROWS;
    localparam int MEMORY_ROWS = BIAS_BASE + STATE_ROWS;
    localparam int ADDRESS_BITS = $clog2(MEMORY_ROWS);
    localparam int WEIGHT_BITS = NNUE_OUTPUT_MAC_LANES * NNUE_OUTPUT_WEIGHT_BITS;
    localparam int PRODUCT_GROUPS = (NNUE_OUTPUT_MAC_LANES + 3) / 4;
    localparam int TREE_LEAVES = 1 << $clog2(NNUE_OUTPUT_MAC_LANES);
    typedef logic [ADDRESS_BITS-1:0] StateAddress;
    typedef logic signed [7:0] OutputProduct;
    typedef logic signed [$clog2(NNUE_OUTPUT_MAC_LANES)+7:0] PartialSum;
    typedef logic signed [4:0] FeatureSum;

    // One simple-dual-port BRAM: evaluation owns the shared synchronous read
    // port whenever it has a row to issue. The extra rows hold trained biases.
    (* ramstyle = "M10K", ram_style = "block" *)
    logic [WORD_BITS-1:0] accumulator_memory[MEMORY_ROWS];
    StateAddress state_read_address, state_write_address;
    logic [WORD_BITS-1:0] state_read_q, state_write_data;
    logic state_write_enable;
`ifdef FPGA_CHESS_PROFILE
    longint unsigned profile_accumulator_wrap_lanes;
`endif

    // Disjoint transformer banks, each with two registered ROM ports.
    // Pawn end-rank rows (row zero in each bank) are the idle zero vectors.
    (* ramstyle = "M10K", ram_style = "block" *)
    logic [FEATURE_WORD_BITS-1:0] feature_bank0[BANK_ROWS];
    (* ramstyle = "M10K", ram_style = "block" *)
    logic [FEATURE_WORD_BITS-1:0] feature_bank1[BANK_ROWS];
    (* ramstyle = "M10K", ram_style = "block" *)
    logic [FEATURE_WORD_BITS-1:0] feature_bank2[BANK_ROWS];
    logic [$clog2(BANK_ROWS)-1:0] feature_address[6];
    logic [FEATURE_WORD_BITS-1:0] feature_q[6];
    logic [5:0] feature_add_q;
    FeatureSum feature_sum_q[NNUE_OUTPUT_MAC_LANES];

    // Canonical model arrays are initialization sources, not additional RAM
    // copies in the synthesized datapath.
    logic [NNUE_FEATURE_ROW_BITS-1:0] feature_rom[NNUE_FEATURE_COUNT];
    logic [NNUE_ACCUMULATOR_BIAS_BITS-1:0] accumulator_bias[NNUE_ACCUMULATOR_COUNT];
    logic [7:0] output_bias[NNUE_OUTPUT_BUCKET_COUNT];
    (* ramstyle = "M10K", ram_style = "block" *)
    logic [WEIGHT_BITS-1:0] output_weight_rows[NNUE_OUTPUT_WEIGHT_ROW_COUNT];
    logic [WEIGHT_BITS-1:0] output_weight_read_q, output_weight_q;
    logic [$clog2(NNUE_OUTPUT_WEIGHT_ROW_COUNT)-1:0] output_weight_address;

    initial begin
        $readmemh("hardware/data/nnue/feature_transformer.hex", feature_rom);
        $readmemh("hardware/data/nnue/accumulator_bias.hex", accumulator_bias);
        $readmemh("hardware/data/nnue/output_weights.hex", output_weight_rows);
        $readmemh("hardware/data/nnue/output_bias.hex", output_bias);
        for (int row = 0; row < BANK_ROWS; row++) begin
            feature_bank0[row] = '0;
            feature_bank1[row] = '0;
            feature_bank2[row] = '0;
        end
        for (int feature = 0; feature < NNUE_FEATURE_COUNT; feature++)
            // Never initialize the reserved zero vector from model contents.
            if (nnue_feature_bank_row(NnueFeatureIndex'(feature)) != NNUE_ZERO_FEATURE_ROW)
            for (int row = 0; row < SIDE_ROWS; row++) begin
                case (nnue_feature_bank(NnueFeatureIndex'(feature)))
                    0: feature_bank0[nnue_feature_bank_row(NnueFeatureIndex'(feature))*SIDE_ROWS+row]
                        = feature_rom[feature][row*FEATURE_WORD_BITS +: FEATURE_WORD_BITS];
                    1: feature_bank1[nnue_feature_bank_row(NnueFeatureIndex'(feature))*SIDE_ROWS+row]
                        = feature_rom[feature][row*FEATURE_WORD_BITS +: FEATURE_WORD_BITS];
                    2: feature_bank2[nnue_feature_bank_row(NnueFeatureIndex'(feature))*SIDE_ROWS+row]
                        = feature_rom[feature][row*FEATURE_WORD_BITS +: FEATURE_WORD_BITS];
                endcase
            end
        for (int thread = 0; thread <= STATE_THREAD_COUNT; thread++)
            for (int row = 0; row < STATE_ROWS; row++)
                for (int lane = 0; lane < NNUE_OUTPUT_MAC_LANES; lane++)
                    accumulator_memory[thread*STATE_ROWS+row][lane*NNUE_ACCUMULATOR_BITS +: NNUE_ACCUMULATOR_BITS]
                        = NNUE_ACCUMULATOR_BITS'(accumulator_bias[(row%SIDE_ROWS)*NNUE_OUTPUT_MAC_LANES+lane]);
    end

    // Full four-bit SCReLU, with a lookup instead of a squaring multiplier.
    function automatic logic [3:0] screlu(input NnueAccumulator accumulator);
        if (accumulator < 0) return 4'd0;
        if (accumulator >= 11) return 4'd15;
        case (accumulator)
            3: return 4'd1;
            4: return 4'd2;
            5: return 4'd3;
            6: return 4'd4;
            7: return 4'd6;
            8: return 4'd8;
            9: return 4'd10;
            10: return 4'd12;
            default: return 4'd0;
        endcase
    endfunction

    // Capture a complete move in its bank slots before updating either side.
    // Root replay uses one-row transactions; move requests combine until complete.
    NnueUpdateRequest active_update;
    // One elastic request register separates search feature encoding from bank
    // decoding and can hold the next transaction while the current one writes.
    NnueUpdateRequest queued_update;
    logic queued_update_valid;
    logic collecting;
    logic [5:0] occupied[2], add_ports[2];
    logic [8:0] bank_rows[2][6];
    logic update_busy, update_issue_done, update_rom_valid, update_write_valid;
    logic [$clog2(STATE_ROWS)-1:0] update_row, update_rom_row, update_write_row;
    logic update_read_issue, update_rom_issue;
    assign update_ready = !queued_update_valid || !update_busy;
    assign update_idle = !update_busy && !collecting && !queued_update_valid;
    // A single held ROM row absorbs read-port backpressure. Once the port is
    // available, transformer, sum/read and write stages advance one row per cycle.
    assign update_rom_issue = update_busy && !update_issue_done
        && (!update_rom_valid || update_read_issue);

    // Read rows of successive evaluations without a drain bubble. Metadata
    // travels with each row so the reduction of one request can overlap another.
    logic eval_read_busy;
    logic [$clog2(STATE_ROWS)-1:0] eval_row;
    ThreadID active_eval_thread;
    Color active_eval_turn;
    NnueOutputBucket active_eval_bucket;
    PstEvalPair active_eval_pst;
    PieceCount active_eval_piece_count;
    logic eval_read_issue, eval_accept;
    logic [$clog2(STATE_ROWS)-1:0] issue_row;
    ThreadID issue_thread;
    Color issue_turn;
    NnueOutputBucket issue_bucket;
    PstEvalPair issue_pst;
    PieceCount issue_piece_count;
    typedef struct packed {
        logic valid;
        logic first;
        logic last;
        logic [NNUE_OUTPUT_BIAS_BITS-1:0] bias;
    } RowTag;
    RowTag read_tag, activation_tag, product_tag, sum_tag;
    logic [NNUE_OUTPUT_MAC_LANES*4-1:0] activations_q;
    wire [PRODUCT_GROUPS*32-1:0] products;
    OutputProduct products_q[NNUE_OUTPUT_MAC_LANES];
    PartialSum sum_tree[2*TREE_LEAVES];
    PartialSum partial_sum_q;
    NnueCorrection running_sum;

    // Exact signed phase interpolation; reciprocal division is pipelined with
    // RAM, activation and products and uses truncation toward zero.
    localparam int PST_BITS = $bits(PstEvalScore) + 5;
    localparam int RECIP_SHIFT = $bits(PstEvalScore) + 9;
    localparam int RECIP_BITS = RECIP_SHIFT - 4;
    localparam logic [RECIP_BITS-1:0] RECIP =
        RECIP_BITS'(((64'd1 << RECIP_SHIFT) + 29) / 30);
    logic signed [PST_BITS-1:0] pst_numerator;
    logic [PST_BITS-1:0] pst_magnitude;
    logic [PST_BITS+RECIP_BITS-1:0] pst_product;
    logic pst_negative;
    PstEvalScore product_pst, sum_pst;

    assign eval_ready = !eval_read_busy;
    assign eval_accept = eval_valid && eval_ready;
    assign eval_read_issue = eval_read_busy || eval_accept;
    always_comb begin
        issue_row = eval_read_busy ? eval_row : '0;
        issue_thread = eval_read_busy ? active_eval_thread : eval_thread_id;
        issue_turn = eval_read_busy ? active_eval_turn : eval_turn;
        issue_bucket = eval_read_busy ? active_eval_bucket : nnue_output_bucket(eval_piece_count);
        issue_pst = eval_read_busy ? active_eval_pst : eval_pst;
        issue_piece_count = eval_read_busy ? active_eval_piece_count : eval_piece_count;
        output_weight_address = $clog2(NNUE_OUTPUT_WEIGHT_ROW_COUNT)'(
            int'(issue_bucket)*STATE_ROWS + ((int'(issue_row)
                + (issue_turn == BLACK ? SIDE_ROWS : 0)) % STATE_ROWS));
        update_read_issue = update_rom_valid && !eval_read_issue;
        state_read_address = eval_read_issue
            ? StateAddress'(int'(issue_thread)*STATE_ROWS + int'(issue_row))
            : StateAddress'((active_update.clear ? BIAS_BASE
                : int'(active_update.thread_id)*STATE_ROWS) + int'(update_rom_row));
        state_write_address = StateAddress'(int'(active_update.thread_id)*STATE_ROWS + int'(update_write_row));
        state_write_enable = rst_n && !clear && update_write_valid && active_update.apply;
        for (int lane = 0; lane < NNUE_OUTPUT_MAC_LANES; lane++)
            state_write_data[lane*NNUE_ACCUMULATOR_BITS +: NNUE_ACCUMULATOR_BITS]
                = NnueAccumulator'(state_read_q[lane*NNUE_ACCUMULATOR_BITS +: NNUE_ACCUMULATOR_BITS])
                    + NnueAccumulator'(feature_sum_q[lane]);
        for (int port_index = 0; port_index < 6; port_index++)
            feature_address[port_index] = $clog2(BANK_ROWS)'(
                int'(bank_rows[int'(update_row)/SIDE_ROWS][port_index])*SIDE_ROWS
                    + int'(update_row)%SIDE_ROWS);
    end

    // RAM output registers deliberately have no reset or combinational read.
    always_ff @(posedge clk) begin
        if (eval_read_issue || update_read_issue)
            state_read_q <= accumulator_memory[state_read_address];
        if (state_write_enable)
            accumulator_memory[state_write_address] <= state_write_data;
        output_weight_read_q <= output_weight_rows[output_weight_address];
        if (update_rom_issue) begin
            feature_q[0] <= feature_bank0[feature_address[0]];
            feature_q[1] <= feature_bank0[feature_address[1]];
            feature_q[2] <= feature_bank1[feature_address[2]];
            feature_q[3] <= feature_bank1[feature_address[3]];
            feature_q[4] <= feature_bank2[feature_address[4]];
            feature_q[5] <= feature_bank2[feature_address[5]];
        end
    end

    genvar group_index, lane_index;
    generate
        for (group_index = 0; group_index < PRODUCT_GROUPS; group_index++) begin : gen_products
            wire [15:0] a, w;
            for (lane_index = 0; lane_index < 4; lane_index++) begin : gen_lane
                if (group_index*4 + lane_index < NNUE_OUTPUT_MAC_LANES) begin : gen_used
                    assign a[lane_index*4 +: 4] = activations_q[(group_index*4+lane_index)*4 +: 4];
                    assign w[lane_index*4 +: 4] = output_weight_q[(group_index*4+lane_index)*4 +: 4];
                end else begin : gen_unused
                    assign a[lane_index*4 +: 4] = '0;
                    assign w[lane_index*4 +: 4] = '0;
                end
            end
            nnue_packed_products multiplier (.activations(a), .weights(w),
                .products(products[group_index*32 +: 32]));
        end
    endgenerate

    // A balanced tree terminates at one registered partial sum per vector.
    always_comb begin
        sum_tree[0] = '0;
        for (int lane = 0; lane < TREE_LEAVES; lane++)
            sum_tree[TREE_LEAVES+lane] = lane < NNUE_OUTPUT_MAC_LANES
                ? PartialSum'(products_q[lane]) : PartialSum'(0);
        for (int node = TREE_LEAVES-1; node > 0; node--)
            sum_tree[node] = sum_tree[node*2] + sum_tree[node*2+1];
    end

    always_ff @(posedge clk) begin
        if (!rst_n || clear) begin
`ifdef FPGA_CHESS_PROFILE
            profile_accumulator_wrap_lanes <= 0;
`endif
            update_busy <= 1'b0;
            update_issue_done <= 1'b0;
            update_rom_valid <= 1'b0;
            update_write_valid <= 1'b0;
            collecting <= 1'b0;
            active_update <= '0;
            queued_update_valid <= 1'b0;
            update_row <= '0;
            update_done_valid <= 1'b0;
            update_done_thread <= '0;
            update_done_ply <= '0;
            for (int perspective = 0; perspective < 2; perspective++) begin
                occupied[perspective] <= '0;
                add_ports[perspective] <= '0;
                for (int port_index = 0; port_index < 6; port_index++)
                    bank_rows[perspective][port_index] <= '0;
            end
            eval_read_busy <= 1'b0;
            eval_row <= '0;
            read_tag <= '0;
            activation_tag <= '0;
            product_tag <= '0;
            sum_tag <= '0;
            result_valid <= 1'b0;
            result <= '0;
            result_pst <= '0;
            running_sum <= '0;
        end else begin
            update_done_valid <= 1'b0;
`ifdef FPGA_CHESS_PROFILE
            if (state_write_enable) begin
                automatic int wraps = 0;
                for (int lane = 0; lane < NNUE_OUTPUT_MAC_LANES; lane++) begin
                    automatic int exact_sum = int'($signed(state_read_q[lane*NNUE_ACCUMULATOR_BITS +: NNUE_ACCUMULATOR_BITS]))
                        + int'(feature_sum_q[lane]);
                    if (exact_sum < -(1 << (NNUE_ACCUMULATOR_BITS-1))
                            || exact_sum >= (1 << (NNUE_ACCUMULATOR_BITS-1))) wraps++;
                end
                profile_accumulator_wrap_lanes <= profile_accumulator_wrap_lanes + 64'(wraps);
            end
`endif
            if (update_ready) begin
                queued_update_valid <= update_valid;
                if (update_valid) queued_update <= update_req;
            end
            if (queued_update_valid && !update_busy) begin
                active_update <= queued_update;
                if (collecting) active_update.clear <= active_update.clear || queued_update.clear;
                for (int perspective = 0; perspective < 2; perspective++) begin
                    automatic NnueFeatureIndex feature = perspective == 0
                        ? queued_update.white_feature : queued_update.black_feature;
                    automatic int bank = nnue_feature_bank(feature);
                    automatic logic [5:0] used = collecting ? occupied[perspective] : 6'b0;
                    automatic int slot = bank*2 + int'(used[bank*2]);
                    if (!collecting) begin
                        add_ports[perspective] <= '0;
                        for (int port_index = 0; port_index < 6; port_index++)
                            bank_rows[perspective][port_index] <= '0;
                    end
                    if (queued_update.apply) begin
`ifndef SYNTHESIS
                        assert (!used[slot]) else $fatal(1, "NNUE transformer bank conflict");
`endif
                        used[slot] = 1'b1;
                        bank_rows[perspective][slot] <= 9'(nnue_feature_bank_row(feature));
                        add_ports[perspective][slot] <= queued_update.add;
                    end
                    occupied[perspective] <= used;
                end
                collecting <= queued_update.combine && !queued_update.complete;
                if (!queued_update.combine || queued_update.complete) begin
                    update_row <= '0;
                    update_issue_done <= 1'b0;
                    if (queued_update.apply) update_busy <= 1'b1;
                    else if (queued_update.complete) begin
                        update_done_valid <= 1'b1;
                        update_done_thread <= queued_update.thread_id;
                        update_done_ply <= queued_update.ply;
                    end
                end
            end
            if (update_rom_issue) begin
                feature_add_q <= add_ports[int'(update_row)/SIDE_ROWS];
                update_rom_row <= update_row;
                if (update_row == STATE_ROWS-1) update_issue_done <= 1'b1;
                else update_row <= update_row + 1'b1;
            end
            if (update_rom_issue || update_read_issue)
                update_rom_valid <= update_rom_issue;
            update_write_valid <= update_read_issue;
            if (update_read_issue) begin
                update_write_row <= update_rom_row;
                for (int lane = 0; lane < NNUE_OUTPUT_MAC_LANES; lane++) begin
                    automatic FeatureSum sum = '0;
                    for (int port_index = 0; port_index < 6; port_index++) begin
                        automatic FeatureSum weight = FeatureSum'($signed(feature_q[port_index][lane*2 +: 2]));
                        sum += feature_add_q[port_index] ? weight : -weight;
                    end
                    feature_sum_q[lane] <= sum;
                end
            end
            if (update_write_valid && update_write_row == STATE_ROWS-1) begin
                update_busy <= 1'b0;
                if (active_update.complete) begin
                    update_done_valid <= 1'b1;
                    update_done_thread <= active_update.thread_id;
                    update_done_ply <= active_update.ply;
                end
            end

            if (eval_accept) begin
                active_eval_thread <= eval_thread_id;
                active_eval_turn <= eval_turn;
                active_eval_bucket <= nnue_output_bucket(eval_piece_count);
                active_eval_pst <= eval_pst;
                active_eval_piece_count <= eval_piece_count;
                eval_read_busy <= 1'b1;
                eval_row <= 1;
            end else if (eval_read_busy) begin
                if (eval_row == STATE_ROWS-1) eval_read_busy <= 1'b0;
                else eval_row <= eval_row + 1'b1;
            end
            read_tag <= '{valid: eval_read_issue, first: issue_row == 0,
                last: issue_row == STATE_ROWS-1,
                bias: output_bias[issue_bucket][NNUE_OUTPUT_BIAS_BITS-1:0]};
            activation_tag <= read_tag;
            product_tag <= activation_tag;
            sum_tag <= product_tag;
            for (int lane = 0; lane < NNUE_OUTPUT_MAC_LANES; lane++) begin
                activations_q[lane*4 +: 4] <= screlu(NnueAccumulator'(
                    state_read_q[lane*NNUE_ACCUMULATOR_BITS +: NNUE_ACCUMULATOR_BITS]));
                products_q[lane] <= OutputProduct'(products[lane*8 +: 8]);
            end
            output_weight_q <= output_weight_read_q;
            partial_sum_q <= sum_tree[1];
            begin
                automatic int phase = issue_piece_count <= 2 ? 0
                    : issue_piece_count >= 32 ? 30 : int'(issue_piece_count)-2;
                pst_numerator <= PST_BITS'(int'(issue_pst.first)*phase + int'(issue_pst.endgame)*(30-phase));
            end
            pst_product <= pst_magnitude * RECIP;
            pst_negative <= pst_numerator < 0;
            product_pst <= pst_negative ? -(PstEvalScore'(pst_product >> RECIP_SHIFT))
                : PstEvalScore'(pst_product >> RECIP_SHIFT);
            sum_pst <= product_pst;
            result_valid <= sum_tag.valid && sum_tag.last;
            if (sum_tag.valid) begin
                automatic NnueCorrection total = (sum_tag.first ? NnueCorrection'(0) : running_sum)
                    + NnueCorrection'(partial_sum_q);
                running_sum <= total;
                if (sum_tag.last) begin
                    result <= total + NnueCorrection'({1'b0, sum_tag.bias});
                    result_pst <= sum_pst;
                end
            end
        end
    end
    assign pst_magnitude = pst_numerator < 0 ? PST_BITS'(-pst_numerator) : PST_BITS'(pst_numerator);

`ifndef SYNTHESIS
    // Test hooks update the actual banked storage and canonical reference data.
    task automatic load_feature(input int feature, input logic [NNUE_FEATURE_ROW_BITS-1:0] value);
        feature_rom[feature] = value;
        if (nnue_feature_bank_row(NnueFeatureIndex'(feature)) != NNUE_ZERO_FEATURE_ROW)
        for (int row = 0; row < SIDE_ROWS; row++)
            case (nnue_feature_bank(NnueFeatureIndex'(feature)))
                0: feature_bank0[nnue_feature_bank_row(NnueFeatureIndex'(feature))*SIDE_ROWS+row] = value[row*FEATURE_WORD_BITS +: FEATURE_WORD_BITS];
                1: feature_bank1[nnue_feature_bank_row(NnueFeatureIndex'(feature))*SIDE_ROWS+row] = value[row*FEATURE_WORD_BITS +: FEATURE_WORD_BITS];
                2: feature_bank2[nnue_feature_bank_row(NnueFeatureIndex'(feature))*SIDE_ROWS+row] = value[row*FEATURE_WORD_BITS +: FEATURE_WORD_BITS];
            endcase
    endtask
    task automatic load_bias(input int lane, input logic [NNUE_ACCUMULATOR_BIAS_BITS-1:0] value);
        accumulator_bias[lane] = value;
        for (int perspective = 0; perspective < 2; perspective++)
            accumulator_memory[BIAS_BASE+perspective*SIDE_ROWS+lane/NNUE_OUTPUT_MAC_LANES][(lane%NNUE_OUTPUT_MAC_LANES)*NNUE_ACCUMULATOR_BITS +: NNUE_ACCUMULATOR_BITS]
                = NNUE_ACCUMULATOR_BITS'(value);
    endtask
    function automatic logic [NNUE_STATE_VALUE_COUNT*NNUE_ACCUMULATOR_BITS-1:0] read_state(input int thread);
        for (int row = 0; row < STATE_ROWS; row++)
            read_state[row*WORD_BITS +: WORD_BITS] = accumulator_memory[thread*STATE_ROWS+row];
    endfunction
    initial begin
        assert (NNUE_ACCUMULATOR_COUNT >= NNUE_OUTPUT_MAC_LANES
            && NNUE_ACCUMULATOR_COUNT % NNUE_OUTPUT_MAC_LANES == 0)
            else $fatal(1, "NNUE node count must be a multiple of vector width");
        assert (STATE_THREAD_COUNT >= 1 && STATE_THREAD_COUNT <= THREAD_COUNT)
            else $fatal(1, "NNUE thread count is outside the ThreadID domain");
    end
`endif
endmodule
