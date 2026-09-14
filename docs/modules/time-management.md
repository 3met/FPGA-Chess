# Time Management (`time_management`)

The time-management module is a direct child of `search_controller`. It counts elapsed milliseconds and owns the exact control-plane arithmetic for initial clock budgets, adaptive soft budgets, and next-depth thresholds. The search controller supplies policy inputs and consumes only registered budget results.

## Parameters

| Parameter Name | Description |
| -------------- | ----------- |
| `CLOCK_FREQ` | Clock frequency in Hertz; it must be a whole multiple of 1 kHz. |
| Time policy parameters | The allocation constants generated from the selected search profile. |

## Ports

| Direction | Port Name | Size | Description |
| --------- | --------- | ---- | ----------- |
| Input | `clk` | 1 | Clock. |
| Input | `rst_n`, `cancel` | 1 | Synchronous module reset and arithmetic cancellation. |
| Input | `timer_reset`, `timer_run` | 1 | Elapsed-time control; pausing preserves the partial millisecond. |
| Input | `setup_*` | Various | One initial allocation request and its fixed-time or clock inputs. |
| Input | `adaptive_*` | Various | One post-iteration soft-budget allocation request. |
| Output | `busy`, `done` | 1 | Allocation status. |
| Output | `base_ms`, `soft_ms`, `next_depth_ms`, `hard_ms` | Various | Registered search deadlines. |
| Output | `elapsed_ms` | `TIME_BITS` | Saturating elapsed time in milliseconds. |

`TIME_BITS = 24` limits representable elapsed time to `16,777,215 ms`, about 4.66 hours. A single iterative restoring divider is private to this module. It is intentionally shared by all allocation steps because division occurs only during setup or between completed depths, and the moves-to-go divisor is runtime-variable.
