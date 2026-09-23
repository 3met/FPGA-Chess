// Quiet-history lookup and an independent best-effort update pipeline.

import chess_defs::*;

module move_generator_quiet_history #(
    parameter int HISTORY_ENTRY_COUNT = 8192,
    parameter int HISTORY_ENTRY_BITS = 8,
    parameter int REWARD_PER_DEPTH = 2,
    parameter int MAXIMUM_REWARD = 31,
    parameter int MALUS_DIVISOR = 2
) (
    input logic clk,
    input logic rst_n,
    input logic clear,
    output logic init_busy,

    input logic lookup_valid,
    input ThreadID lookup_thread,
    input Color lookup_color,
    input Position lookup_from,
    input Position lookup_to,
    output logic signed [HISTORY_ENTRY_BITS-1:0] lookup_value,

    input logic update_valid,
    output logic update_ready,
    input ThreadID update_thread,
    input Color update_color,
    input Position update_from,
    input Position update_to,
    input PlyIndex update_depth,
    input logic [11:0] update_failed0,
    input logic [11:0] update_failed1,
    input logic [11:0] update_failed2,
    input logic [1:0] update_failed_count
);

    localparam int HISTORY_ADDRESS_BITS = $clog2(HISTORY_ENTRY_COUNT);
    localparam int HISTORY_LIMIT_SHIFT = HISTORY_ENTRY_BITS - 1;
    localparam int KEY_BITS = $bits(ThreadID) + 13;
    localparam int REWARD_BITS = (MAXIMUM_REWARD < 1) ? 1 : $clog2(MAXIMUM_REWARD + 1);
    localparam int REWARD_PER_DEPTH_BITS = (REWARD_PER_DEPTH < 1)
        ? 1 : $clog2(REWARD_PER_DEPTH + 1);
    localparam int DEPTH_REWARD_BITS = $bits(PlyIndex) + REWARD_PER_DEPTH_BITS;
    localparam int PRODUCT_BITS = HISTORY_ENTRY_BITS + REWARD_BITS;
    // The constrained bonus can move a history entry at most one step beyond
    // its signed range, so one guard bit is sufficient for saturation.
    localparam int UPDATE_BITS = HISTORY_ENTRY_BITS + 1;
    localparam logic signed [HISTORY_ENTRY_BITS-1:0] HISTORY_MINIMUM =
        {1'b1, {(HISTORY_ENTRY_BITS-1){1'b0}}};
    localparam logic signed [HISTORY_ENTRY_BITS-1:0] HISTORY_MAXIMUM =
        {1'b0, {(HISTORY_ENTRY_BITS-1){1'b1}}};

    typedef enum logic [1:0] {
        UPDATE_IDLE,
        UPDATE_READ,
        UPDATE_CAPTURE,
        UPDATE_WRITE
    } UpdateState;

    // XOR folding is only wiring, preserves all move bits for the default
    // 13-bit address, and spreads thread/color aliases without added latency.
    function automatic logic [HISTORY_ADDRESS_BITS-1:0] history_hash(
        input ThreadID thread_id,
        input Color color,
        input Position from_pos,
        input Position to_pos
    );
        automatic logic [KEY_BITS-1:0] key = {thread_id, color, from_pos, to_pos};
        automatic logic [HISTORY_ADDRESS_BITS-1:0] result = '0;
        for (int bit_index = 0; bit_index < KEY_BITS; bit_index++)
            result[bit_index % HISTORY_ADDRESS_BITS] ^= key[bit_index];
        return result;
    endfunction

    UpdateState state;
    logic [HISTORY_ADDRESS_BITS-1:0] clear_address;
    logic read_en;
    logic [HISTORY_ADDRESS_BITS-1:0] read_address;
    logic signed [HISTORY_ENTRY_BITS-1:0] read_data;
    logic write_en;
    logic [HISTORY_ADDRESS_BITS-1:0] write_address;
    logic signed [HISTORY_ENTRY_BITS-1:0] write_data;

    ThreadID active_thread;
    Color active_color;
    Position active_from;
    Position active_to;
    PlyIndex active_depth;
    logic [11:0] failed0;
    logic [11:0] failed1;
    logic [11:0] failed2;
    logic [1:0] failed_count;
    logic [1:0] update_entry;
    logic update_is_malus;
    logic signed [HISTORY_ENTRY_BITS-1:0] captured_value;
    logic [HISTORY_ADDRESS_BITS-1:0] active_address;
    logic [HISTORY_ADDRESS_BITS-1:0] lookup_address;
    logic write_conflicts_with_lookup;

`ifndef SYNTHESIS
    initial begin
        if (HISTORY_ENTRY_COUNT < 2
                || (HISTORY_ENTRY_COUNT & (HISTORY_ENTRY_COUNT - 1)) != 0)
            $fatal(1, "history entry count must be a power of two");
        if (HISTORY_ENTRY_BITS < 2 || REWARD_PER_DEPTH < 1
                || MAXIMUM_REWARD < 1
                || MAXIMUM_REWARD > (2 ** (HISTORY_ENTRY_BITS - 1) - 1)
                || MALUS_DIVISOR < 1)
            $fatal(1, "history parameters do not fit the configured entry width");
    end
`endif

    assign update_ready = 1'b1;
    assign lookup_value = read_data;
    assign active_address = history_hash(
        active_thread, active_color, active_from, active_to
    );
    assign lookup_address = history_hash(
        lookup_thread, lookup_color, lookup_from, lookup_to
    );
    assign write_conflicts_with_lookup = lookup_valid
        && lookup_address == active_address;

    always_comb begin
        read_en = 1'b0;
        read_address = '0;
        write_en = init_busy;
        write_address = clear_address;
        write_data = '0;

        // Generator lookups always own the read port. Update reads wait in
        // their private pipeline and never apply backpressure to generation.
        if (!init_busy && lookup_valid) begin
            read_en = 1'b1;
            read_address = lookup_address;
        end else if (!init_busy && state == UPDATE_READ) begin
            read_en = 1'b1;
            read_address = active_address;
        end

        if (!init_busy && state == UPDATE_WRITE && !write_conflicts_with_lookup) begin
            automatic logic [REWARD_BITS-1:0] reward_magnitude;
            automatic logic [REWARD_BITS-1:0] magnitude;
            automatic logic [DEPTH_REWARD_BITS-1:0] depth_reward;
            automatic logic signed [REWARD_BITS:0] signed_bonus;
            automatic logic signed [PRODUCT_BITS-1:0] gravity_product;
            automatic logic signed [UPDATE_BITS-1:0] updated_history;
            depth_reward = active_depth * REWARD_PER_DEPTH_BITS'(REWARD_PER_DEPTH);
            reward_magnitude = (depth_reward >= DEPTH_REWARD_BITS'(MAXIMUM_REWARD))
                ? REWARD_BITS'(MAXIMUM_REWARD)
                : REWARD_BITS'(depth_reward);
            magnitude = update_is_malus
                ? REWARD_BITS'(reward_magnitude / MALUS_DIVISOR)
                : reward_magnitude;
            signed_bonus = update_is_malus
                ? -$signed({1'b0, magnitude}) : $signed({1'b0, magnitude});
            // Gravity scales with the configured signed range:
            // H' = H + B - H*|B|/2^(entry_bits-1).
            gravity_product = $signed(captured_value) * $signed({1'b0, magnitude});
            updated_history = UPDATE_BITS'($signed(captured_value))
                + UPDATE_BITS'(signed_bonus)
                - UPDATE_BITS'(gravity_product >>> HISTORY_LIMIT_SHIFT);
            write_en = 1'b1;
            write_address = active_address;
            if (updated_history > UPDATE_BITS'($signed(HISTORY_MAXIMUM)))
                write_data = HISTORY_MAXIMUM;
            else if (updated_history < UPDATE_BITS'($signed(HISTORY_MINIMUM)))
                write_data = HISTORY_MINIMUM;
            else
                write_data = HISTORY_ENTRY_BITS'(updated_history);
        end
    end

    move_generator_history_table #(
        .HISTORY_ENTRY_COUNT(HISTORY_ENTRY_COUNT),
        .HISTORY_ENTRY_BITS(HISTORY_ENTRY_BITS)
    ) history_table (
        .clk,
        .rd_en(read_en), .rd_addr(read_address), .rd_data(read_data),
        .wr_en(write_en), .wr_addr(write_address), .wr_data(write_data)
    );

    always_ff @(posedge clk) begin
        if (!rst_n) begin
            init_busy <= 1'b1;
            clear_address <= '0;
            state <= UPDATE_IDLE;
        end else if (clear) begin
            init_busy <= 1'b1;
            clear_address <= '0;
            state <= UPDATE_IDLE;
        end else if (init_busy) begin
            if (clear_address == HISTORY_ADDRESS_BITS'(HISTORY_ENTRY_COUNT - 1))
                init_busy <= 1'b0;
            else
                clear_address <= clear_address + HISTORY_ADDRESS_BITS'(1);
        end else begin
            case (state)
                UPDATE_IDLE: begin
                    // The input is best-effort: ready remains asserted and
                    // any update arriving while this pipeline is occupied
                    // is deliberately dropped.
                    if (update_valid) begin
                        active_thread <= update_thread;
                        active_color <= update_color;
                        active_from <= update_from;
                        active_to <= update_to;
                        active_depth <= update_depth;
                        failed0 <= update_failed0;
                        failed1 <= update_failed1;
                        failed2 <= update_failed2;
                        failed_count <= update_failed_count;
                        update_entry <= 2'd0;
                        update_is_malus <= 1'b0;
                        state <= UPDATE_READ;
                    end
                end
                UPDATE_READ: begin
                    if (!lookup_valid)
                        state <= UPDATE_CAPTURE;
                end
                UPDATE_CAPTURE: begin
                    captured_value <= read_data;
                    state <= UPDATE_WRITE;
                end
                UPDATE_WRITE: begin
                    // A same-address generator lookup wins; drop this one
                    // write instead of exposing ambiguous read-during-write data.
                    if (update_entry < failed_count) begin
                        case (update_entry)
                            2'd0: {active_from, active_to} <= failed0;
                            2'd1: {active_from, active_to} <= failed1;
                            default: {active_from, active_to} <= failed2;
                        endcase
                        update_entry <= update_entry + 2'd1;
                        update_is_malus <= 1'b1;
                        state <= UPDATE_READ;
                    end else begin
                        state <= UPDATE_IDLE;
                    end
                end
                default: state <= UPDATE_IDLE;
            endcase
        end
    end

endmodule : move_generator_quiet_history
