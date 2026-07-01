# Load TT Pipeline

The load TT pipeline performs transposition-table lookup requests for search threads.

## Behavior

Each request includes at least `thread_id`, board hash, search depth, alpha/beta context as needed by the search controller, and any metadata needed to route the response. In the base design, `thread_id` is sufficient because each thread may have at most one in-flight load TT request.

The primary TT storage is external SDRAM/DDR. A BRAM cache is used when the target FPGA has enough block memory to make caching useful.

TT loads are latency-sensitive and take priority over TT stores when memory bandwidth conflicts.

Each lookup returns a valid TT response to the requesting thread. The response indicates hit or miss, and on hit includes the stored score, bound type, depth, and best move fields needed by the search controller.

## Design Parameters

- External memory banking and arbitration.
- BRAM cache structure.
- TT entry format.
- Replacement policy.
