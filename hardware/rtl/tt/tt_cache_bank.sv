// Two single-way RAMs share a synchronous set read; LRU uses a separate bit RAM.
module tt_cache_bank #(
    parameter int WAY_BITS = 1,
    parameter int INDEX_BITS = 1
) (
    input logic clk,
    input logic read_enable,
    input logic [INDEX_BITS-1:0] read_index,
    output logic [1:0][WAY_BITS-1:0] read_set,
    output logic read_lru,
    input logic write_enable,
    input logic [INDEX_BITS-1:0] write_index,
    input logic write_slot,
    input logic [WAY_BITS-1:0] write_way,
    input logic lru_write_enable,
    input logic [INDEX_BITS-1:0] lru_write_index,
    input logic lru_write_value
);
    logic [1:0][WAY_BITS-1:0] ram_set;
    logic [WAY_BITS-1:0] forwarded_way;
    logic forward, forwarded_slot;
    logic ram_lru, forward_lru, forwarded_lru;
    // A publication changes one slot without overwriting the other slot's newer data.
    genvar slot;
    generate for (slot = 0; slot < 2; slot++) begin : ways
        sync_read_simple_dual_port_ram #(.NUM_WORDS(1 << INDEX_BITS), .WORD_SIZE(WAY_BITS)) ram (
            .clock(clk), .rden(read_enable), .rdaddress(read_index), .q(ram_set[slot]),
            .wren(write_enable && write_slot == 1'(slot)), .wraddress(write_index), .data(write_way));
    end endgenerate
    // Each retiring read produces at most one touch, so the LRU RAM needs one write port.
    sync_read_simple_dual_port_ram #(.NUM_WORDS(1 << INDEX_BITS), .WORD_SIZE(1)) lru_ram (
        .clock(clk), .rden(read_enable), .rdaddress(read_index), .q(ram_lru),
        .wren(lru_write_enable), .wraddress(lru_write_index), .data(lru_write_value));
    // Forward both data and replacement state independently of RAM collision behavior.
    always_ff @(posedge clk) if (read_enable) begin
        forward <= write_enable && read_index == write_index;
        forwarded_way <= write_way; forwarded_slot <= write_slot;
        forward_lru <= lru_write_enable && read_index == lru_write_index;
        forwarded_lru <= lru_write_value;
    end
    always_comb begin
        read_set = ram_set;
        if (forward) read_set[forwarded_slot] = forwarded_way;
        read_lru = forward_lru ? forwarded_lru : ram_lru;
    end
endmodule
