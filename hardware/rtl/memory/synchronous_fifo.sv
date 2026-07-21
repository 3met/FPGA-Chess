module synchronous_fifo #(
    parameter int DATA_WIDTH = 1,
    parameter int DEPTH = 256
) (
    input logic clk,
    input logic rst_n,
    input logic clear,
    input logic push_valid,
    output logic push_ready,
    input logic [DATA_WIDTH-1:0] push_data,
    output logic pop_valid,
    input logic pop_ready,
    output logic [DATA_WIDTH-1:0] pop_data,
    output logic [$clog2(DEPTH + 1)-1:0] count
);
    localparam int PTR_BITS = DEPTH > 1 ? $clog2(DEPTH) : 1;
    typedef logic [PTR_BITS-1:0] FifoPtr;
    typedef logic [$clog2(DEPTH + 1)-1:0] FifoCount;

    (* ramstyle = "M10K, no_rw_check" *)
    (* ram_style = "block" *)
    logic [DATA_WIDTH-1:0] memory[0:DEPTH-1];
    FifoPtr write_ptr;
    FifoPtr read_ptr;
    FifoCount memory_count;
    logic read_pending;
    logic [DATA_WIDTH-1:0] read_data;
    logic push;
    logic pop;
    logic fetch;

`ifndef SYNTHESIS
    initial begin
        if (DATA_WIDTH < 1) $error("synchronous_fifo DATA_WIDTH must be positive");
        if (DEPTH < 2) $error("synchronous_fifo DEPTH must be at least two");
    end
`endif

    function automatic FifoPtr next_ptr(input FifoPtr ptr);
        if (ptr == FifoPtr'(DEPTH - 1)) return FifoPtr'(0);
        return ptr + FifoPtr'(1);
    endfunction

    assign count = memory_count + FifoCount'(pop_valid) + FifoCount'(read_pending);
    assign push_ready = count < FifoCount'(DEPTH);
    assign push = push_valid && push_ready;
    assign pop = pop_valid && pop_ready;
    assign fetch = (!pop_valid || pop) && !read_pending && memory_count != FifoCount'(0);
    assign pop_data = read_data;

    // The held output word gives consumers a conventional ready/valid port,
    // while all queued storage behind it uses a synchronous-read block RAM.
    always_ff @(posedge clk) begin
        if (!rst_n || clear) begin
            write_ptr <= FifoPtr'(0);
            read_ptr <= FifoPtr'(0);
            memory_count <= FifoCount'(0);
            read_pending <= 1'b0;
            pop_valid <= 1'b0;
        end else begin
            if (push) begin
                memory[write_ptr] <= push_data;
                write_ptr <= next_ptr(write_ptr);
            end

            if (fetch) begin
                read_data <= memory[read_ptr];
                read_ptr <= next_ptr(read_ptr);
            end

            case ({push, fetch})
                2'b10: memory_count <= memory_count + FifoCount'(1);
                2'b01: memory_count <= memory_count - FifoCount'(1);
                default: begin
                end
            endcase

            read_pending <= fetch;
            if (read_pending) pop_valid <= 1'b1;
            else if (pop) pop_valid <= 1'b0;
        end
    end
endmodule : synchronous_fifo
