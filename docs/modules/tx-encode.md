# TX Encode (`tx_encode`)

Status: implemented first portable CDC FIFO wrapper.

The output encoder buffers response bytes from the engine and transmits them over UART.

## Behavior

The output encoder contains an 8-bit asynchronous FIFO with parameterized depth. The default depth is 1024 words.

The engine writes bytes when `tx_stream_valid` is asserted and `full` is deasserted. If `full` is asserted, the engine must pause response streaming until space is available.

The default UART side uses `UART_CLOCK_FREQ = 50_000_000` and `BAUD_RATE = 2_000_000`, which gives exactly 25 UART clock cycles per bit.

## Ports

| Direction | Port Name | Size | Description |
| --------- | --------- | ---- | ----------- |
| Input | `clk` | 1 | Engine-side clock. |
| Input | `uart_clk` | 1 | UART-side clock. |
| Input | `rst_n` | 1 | Synchronous active-low reset. |
| Input | `tx_stream` | 8 | Response byte from the engine. |
| Input | `tx_stream_valid` | 1 | Indicates `tx_stream` is valid data that should be transmitted. |
| Output | `uart_tx` | 1 | UART output signal. |
| Output | `full` | 1 | Indicates that the output FIFO is full and no new input should be written. |

## Current RTL Notes

The current RTL uses `async_fifo` for the engine-to-UART clock crossing and drains the FIFO whenever the UART transmitter can accept another byte.
