# RX Decode (`rx_decode`)

The input decoder receives UART bytes, buffers command/data bytes, and exposes a byte stream to the engine. Kill remains an in-band command for the engine parser, while UART BREAK is reserved for out-of-band remote reset.

## Behavior

The input decoder crosses UART bytes into the engine clock domain through a parameterized asynchronous FIFO.

If the FIFO is empty, `rx_stream_valid` is deasserted. The decoder does not emit a synthetic idle command byte as valid data.

Normal bytes are dropped and `error` is latched if the FIFO is full. The host is responsible for avoiding overflow by respecting engine readiness. UART BREAK is recognized even when the normal FIFO is full, holds `remote_reset` asserted in the engine clock domain for the full BREAK interval, and clears the RX FIFO.

UART clock and baud rate are parameters; the production settings are defined by the host protocol and board wrapper. The receiver samples around each bit center and reports framing errors.

## Ports

| Direction | Port Name         | Size | Description                                                      |
| --------- | ----------------- | ---- | ---------------------------------------------------------------- |
| Input     | `clk`             | 1    | Engine-side clock.                                               |
| Input     | `uart_clk`        | 1    | UART-side clock.                                                 |
| Input     | `engine_rst_n`    | 1    | Engine-domain synchronous active-low reset.                      |
| Input     | `uart_rst_n`      | 1    | UART-domain synchronous active-low reset.                        |
| Input     | `uart_rx`         | 1    | UART input signal.                                               |
| Input     | `mark_read`       | 1    | Indicates that the current decoded byte has been consumed.       |
| Output    | `rx_stream`       | 8    | Decoded UART command/data byte.                                  |
| Output    | `rx_stream_valid` | 1    | Indicates `rx_stream` contains valid data.                       |
| Output    | `remote_reset`    | 1    | Asserted while a synchronized UART BREAK is active.              |
| Output    | `error`           | 1    | Latched UART framing error or RX FIFO overflow.                  |
