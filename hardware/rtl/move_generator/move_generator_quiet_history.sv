// Quiet-move history lookup, update sequencing, and RAM ownership.

import general_chess_defs::*;

module move_generator_quiet_history #(
    parameter int REWARD_PER_DEPTH = 4,
    parameter int MAXIMUM_REWARD = 63,
    parameter int MALUS_DIVISOR = 2
) (
    input logic clk,
    input logic rst_n,
    input logic clear,
    output logic init_busy,

    input logic lookup_valid,
    input Color lookup_color,
    input logic [11:0] lookup_address,
    output logic signed [8:0] lookup_value,

    input logic update_valid,
    output logic update_ready,
    input Color update_color,
    input Position update_from,
    input Position update_to,
    input PlyIndex update_depth,
    input logic [11:0] update_failed0,
    input logic [11:0] update_failed1,
    input logic [11:0] update_failed2,
    input logic [1:0] update_failed_count
);

    localparam int HISTORY_BITS = 9;
    localparam int HISTORY_WORDS = 4096;
    localparam int HISTORY_LIMIT_SHIFT = HISTORY_BITS - 1;

    typedef enum logic [1:0] {
        UPDATE_IDLE,
        UPDATE_READ,
        UPDATE_CAPTURE,
        UPDATE_WRITE
    } UpdateState;

    UpdateState state;
    logic [11:0] clear_address;
    logic read_en[2];
    logic [11:0] read_address[2];
    logic signed [HISTORY_BITS-1:0] read_data[2];
    logic write_en[2];
    logic [11:0] write_address[2];
    logic signed [HISTORY_BITS-1:0] write_data[2];

    Color active_color;
    logic [11:0] active_address;
    PlyIndex active_depth;
    logic [11:0] failed0;
    logic [11:0] failed1;
    logic [11:0] failed2;
    logic [1:0] failed_count;
    logic [1:0] update_entry;
    logic update_is_malus;
    logic signed [HISTORY_BITS-1:0] captured_value;
    logic update_blocked;

`ifndef SYNTHESIS
    initial begin
        if (REWARD_PER_DEPTH < 1 || MAXIMUM_REWARD < 1
                || MAXIMUM_REWARD > 127 || MALUS_DIVISOR < 1)
            $fatal(1, "history update parameters do not fit their arithmetic");
    end
`endif

    assign update_ready = !init_busy && state == UPDATE_IDLE;
    assign lookup_value = read_data[lookup_color];
    assign update_blocked = lookup_valid && lookup_color == active_color;

    always_comb begin
        for (int color = 0; color < 2; color++) begin
            read_en[color] = 1'b0;
            read_address[color] = 12'd0;
            write_en[color] = init_busy;
            write_address[color] = clear_address;
            write_data[color] = '0;
        end

        if (!init_busy && state == UPDATE_READ && !update_blocked) begin
            read_en[active_color] = 1'b1;
            read_address[active_color] = active_address;
        end
        if (!init_busy && lookup_valid) begin
            read_en[lookup_color] = 1'b1;
            read_address[lookup_color] = lookup_address;
        end
        if (!init_busy && state == UPDATE_WRITE && !update_blocked) begin
            automatic logic [6:0] reward_magnitude;
            automatic logic [6:0] magnitude;
            automatic logic signed [7:0] signed_bonus;
            automatic logic signed [16:0] gravity_product;
            automatic logic signed [10:0] updated_history;
            reward_magnitude = (int'(active_depth) * REWARD_PER_DEPTH >= MAXIMUM_REWARD)
                ? 7'(MAXIMUM_REWARD) : 7'(int'(active_depth) * REWARD_PER_DEPTH);
            magnitude = update_is_malus
                ? (reward_magnitude / MALUS_DIVISOR) : reward_magnitude;
            signed_bonus = update_is_malus
                ? -$signed({1'b0, magnitude}) : $signed({1'b0, magnitude});
            // Gravity makes established history progressively harder to change:
            // H' = H + B - H*|B|/256 for rewards and depth-scaled maluses.
            gravity_product = $signed(captured_value) * $signed({1'b0, magnitude});
            updated_history = 11'($signed(captured_value) + signed_bonus
                - (gravity_product >>> HISTORY_LIMIT_SHIFT));
            write_en[active_color] = 1'b1;
            write_address[active_color] = active_address;
            if (updated_history > 11'sd255)
                write_data[active_color] = 9'sd255;
            else if (updated_history < -11'sd256)
                write_data[active_color] = 9'sh100;
            else
                write_data[active_color] = updated_history[8:0];
        end
    end

    move_generator_history_table #(
        .HISTORY_WORDS(HISTORY_WORDS),
        .HISTORY_BITS(HISTORY_BITS)
    ) history_table (
        .clk,
        .rd_en(read_en), .rd_addr(read_address), .rd_data(read_data),
        .wr_en(write_en), .wr_addr(write_address), .wr_data(write_data)
    );

    always_ff @(posedge clk) begin
        if (!rst_n) begin
            init_busy <= 1'b1;
            clear_address <= 12'd0;
            state <= UPDATE_IDLE;
        end else begin
            if (clear) begin
                init_busy <= 1'b1;
                clear_address <= 12'd0;
                state <= UPDATE_IDLE;
            end else if (init_busy) begin
                if (clear_address == 12'hfff)
                    init_busy <= 1'b0;
                else
                    clear_address <= clear_address + 12'd1;
            end

            if (!init_busy) begin
                case (state)
                    UPDATE_IDLE: begin
                        if (update_valid) begin
                            active_color <= update_color;
                            active_address <= {update_from, update_to};
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
                        if (!update_blocked)
                            state <= UPDATE_CAPTURE;
                    end
                    UPDATE_CAPTURE: begin
                        captured_value <= read_data[active_color];
                        state <= UPDATE_WRITE;
                    end
                    default: begin
                        if (!update_blocked) begin
                            if (update_entry < failed_count) begin
                                case (update_entry)
                                    2'd0: active_address <= failed0;
                                    2'd1: active_address <= failed1;
                                    default: active_address <= failed2;
                                endcase
                                update_entry <= update_entry + 2'd1;
                                update_is_malus <= 1'b1;
                                state <= UPDATE_READ;
                            end else begin
                                state <= UPDATE_IDLE;
                            end
                        end
                    end
                endcase
            end
        end
    end

endmodule : move_generator_quiet_history

