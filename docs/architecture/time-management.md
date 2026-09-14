# Time Management

The UCI host sends `wtime`, `btime`, `winc`, `binc`, `movestogo`, and the current `Move Overhead` option with a clock search. The option defaults to 10 ms. Fixed `movetime` searches also carry the overhead; fixed-depth, fixed-node, and perft commands do not use time management.

All time values use the 24-bit millisecond `TimeType`; representable durations must be less than `16,777,216 ms`, about 4.66 hours. The main policy constants are centralized in `hardware/config/search/default.json`.

## Initial Budgets

For the side to move, usable time `T` excludes overhead. A positive `movestogo` uses the first base formula; zero means the sudden-death formula.

```text
T = max(0, remaining_time - move_overhead)

if moves_to_go > 0:
    base = T / (moves_to_go + 2) + 4 * increment / 5
else:
    base = T / 20 + 4 * increment / 5

hard = min(4 * base, 4 * T / 5)
```

The hard budget is shared by every Lazy-SMP thread and is checked continuously during search. A hard timeout aborts the active passes and returns only the primary thread's last completed iteration. `movetime` bypasses adaptive allocation and uses `max(0, movetime - move_overhead)` as its fixed hard deadline.

## Adaptive Soft Budget

After each completed primary-thread depth, the controller adjusts the base budget using only the best move's share of root nodes, best-move stability, and a significant score drop.

```text
factor = 4

if best_move_nodes * 2 < total_root_nodes:
    factor += 1
else if best_move_nodes * 4 > total_root_nodes * 3:
    factor -= 1

if best_move != previous_depth_best_move:
    factor += 1
else if best_move_stable_depths >= 3:
    factor -= 1

if score < previous_depth_score - 64 evaluation units:
    factor += 2

factor = clamp(factor, 2, 8)
soft = min(hard, base * factor / 4)
```

Sixty-four evaluation units are 50 centipawns in the engine's 1/128-pawn score scale. Initial allocation, soft scaling, and the next-depth threshold share one iterative divider because setup latency is negligible and arbitrary tuned denominators must not create combinational timing paths. If the root has exactly one legal move, `soft` is capped at 10 ms. The primary thread stops after a completed depth once the soft deadline is reached and does not start another depth after three fifths of the soft budget has elapsed. Helper threads do not control the result or soft stopping.
