# Time Management

Time management applies to `Search on Clock`. Fixed-time, fixed-depth, fixed-node, and perft commands use their explicit limits instead.

All time values use the 24-bit millisecond `TimeType`; representable durations must be less than `16,777,215 ms`, about 4.66 hours.

## Parameters

| Name                | Default | Description                                                                           |
| ------------------- | ------- | ------------------------------------------------------------------------------------- |
| `MOVE_OVERHEAD_MS`  | `20`    | Time reserved for host/FPGA latency and command turnaround.                           |
| `MIN_SEARCH_MS`     | `10`    | Minimum nonzero search budget when any usable time remains.                           |
| `STABLE_EVAL_DELTA` | `32`    | Evaluation delta, in 1/128 pawn units, considered similar for stable-move early exit. |

## Budget Calculation

For the side to move:

```text
usable_time = max(0, clock_time - MOVE_OVERHEAD_MS)
earliest_end = min(usable_time, increment / 2 + usable_time / 64)
target_end   = min(usable_time, increment * 3 / 4 + usable_time / 32)
late_end     = min(usable_time, increment + usable_time / 16)
hard_end     = min(usable_time, increment + usable_time / 8)
```

If `usable_time` is nonzero, every checkpoint should be at least `MIN_SEARCH_MS`, clamped to `usable_time` if the clock is nearly empty.

The engine should never intentionally search past `hard_end`.

## Iterative-Deepening Exit Rules

The search controller checks time at iteration boundaries and may also check it between nodes.

| Checkpoint | Behavior |
| ---------- | -------- |
| Before `earliest_end` | Always start the next iteration if another depth is allowed. |
| At or after `earliest_end` | Stop after a completed iteration if the best move has been stable for five completed iterations and evaluations are similar. |
| At or after `target_end` | Stop after a completed iteration if the best move has been stable for three completed iterations and evaluations are similar. |
| At or after `late_end` | Stop after the current iteration unless the current best move changed this iteration or the score dropped by at least one pawn. |
| At or after `hard_end` | Stop immediately and return the best fully completed result. Do not wait for the current iteration to finish. |

Evaluations are similar when the absolute difference is at most `STABLE_EVAL_DELTA`.

If no iteration has completed before `hard_end`, return the best legal move found so far. If no legal move has been found, keep searching only long enough to produce one legal move unless the game is already known to be over.
