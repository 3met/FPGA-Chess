### Timer Parameters

| Parameter Name | Description                                 |
| -------------- | ------------------------------------------- |
| `CLOCK_FREQ`   | Clock frequency in Hertz.                   |

### Timer Ports

| Direction | Port Name | Size (bits) | Description                                                       |
| --------- | --------- | ----------- | ----------------------------------------------------------------- |
| Input     | `rst`     | 1           | Synchronous reset to the timer. Sets the time to zero.            |
| Input     | `start`   | 1           | Timer only runs if `start` is asserted. Remains paused otherwise. |
| Output    | `time_ms` | 24          | The current time in milliseconds.                                 |

Note: The 24-bit output port limits searches to a duration of 4.5 hours.
