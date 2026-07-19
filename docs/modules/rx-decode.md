# RX Decode (`rx_decode`)

The input decoder receives UART bytes, buffers command/data bytes, and exposes a byte stream to the engine. Kill remains an in-band command for the engine parser, while UART BREAK is reserved for out-of-band remote reset.

## Behavior

The input decoder contains an 8-bit asynchronous FIFO with parameterized depth. The default depth is 1024 words.

If the FIFO is empty, `rx_stream_valid` is deasserted. The decoder should not emit a synthetic idle command byte as valid data.

Normal bytes are dropped and `error` is latched if the FIFO is full. The host is responsible for avoiding overflow by respecting engine readiness. UART BREAK is recognized even when the normal FIFO is full, pulses `remote_reset` in the engine clock domain, and clears the RX FIFO.

The default UART side uses `UART_CLOCK_FREQ = 50_000_000` and `BAUD_RATE = 2_000_000`, which gives exactly 25 UART clock cycles per bit.

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
| Output    | `kill`            | 1    | Reserved for a future out-of-band policy.                        |
| Output    | `remote_reset`    | 1    | Asserted for one engine-clock cycle when UART BREAK is detected. |
| Output    | `error`           | 1    | Latched UART framing error or RX FIFO overflow.                  |
