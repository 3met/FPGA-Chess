# Timer (`timer`)

Status: implemented.

The timer counts elapsed milliseconds for search time control.

## Parameters

| Parameter Name | Description |
| -------------- | ----------- |
| `CLOCK_FREQ` | Clock frequency in Hertz. |

## Ports

| Direction | Port Name | Size | Description |
| --------- | --------- | ---- | ----------- |
| Input | `clk` | 1 | Clock. |
| Input | `rst` | 1 | Synchronous reset to zero. |
| Input | `run` | 1 | Timer runs only when asserted and remains paused otherwise. |
| Output | `time_ms` | `TIME_BITS` | Current elapsed time in milliseconds. |

`TIME_BITS = 24` limits representable elapsed time to `16,777,215 ms`, about 4.66 hours.
