# Time Management

Time management applies to `Search on Clock`. Fixed-time, fixed-depth, fixed-node, and perft commands use their explicit limits instead.

All time values use the 24-bit millisecond `TimeType`; representable durations must be less than `16,777,215 ms`, about 4.66 hours.

## Parameters

| Name                | Default | Description                                                                           |
| ------------------- | ------- | ------------------------------------------------------------------------------------- |
| `MOVE_OVERHEAD_MS`  | `20`    | Time reserved for host/FPGA latency and command turnaround.                           |
| `MIN_SEARCH_MS`     | `10`    | Minimum nonzero search budget when any usable time remains.                           |

## Budget Calculation

For the side to move:

```text
usable_time = max(0, clock_time - MOVE_OVERHEAD_MS)
target_end  = min(usable_time, increment * 3 / 4 + usable_time / 32)
```

If `usable_time` is nonzero, every checkpoint should be at least `MIN_SEARCH_MS`, clamped to `usable_time` if the clock is nearly empty.

## Iterative-Deepening Exit Rules

The controller uses `target_end` as its clock-search budget and checks it between nodes. It stops immediately on reaching that limit and reports the best fully completed iteration; if an iteration has not completed, it may return a legal root move discovered by the partial iteration.
