# Time Management

A clock search is selected when either side's remaining time is supplied. The UCI host sends the side-to-move clock, increment, `movestogo`, and `Move Overhead` to the FPGA. Missing side-to-move time or increment is treated as zero. Fixed `movetime` searches also use overhead; depth, node, and perft limits do not use time management.

Time values are milliseconds using `TimeType`. Allocation policy is selected by the engine's search profile under `hardware/config/search/`.

## Initial Budgets

Clock allocation reserves move overhead and derives a base budget from usable time, increment, and moves to go. A zero `movestogo` selects sudden-death allocation. The hard budget is capped by usable time and shared by all search threads.

A hard timeout interrupts active search and returns the primary thread's last completed iteration. Fixed `movetime` bypasses adaptive allocation and uses the requested duration minus overhead, clamped at zero.

## Adaptive Stopping

After a completed primary iteration, the soft budget adjusts according to the best move's share of root nodes, move stability, and score drops. A single legal root move receives a shorter soft budget. The soft budget never exceeds the hard deadline.

The primary thread stops at a completed iteration when the soft deadline is reached, and avoids starting another depth when too little of that budget remains. Helper threads do not control soft stopping or the published result.

The [time-management module](../modules/time-management.md) measures elapsed time and computes budgets; the [search controller](../modules/search-controller.md) enforces stopping and selects the result.
