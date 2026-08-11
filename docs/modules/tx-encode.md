# TX Encode (`tx_encode`)

The output encoder buffers response bytes from the engine and transmits them over UART.

## Behavior

The output encoder crosses engine response bytes into the UART clock domain through a parameterized asynchronous FIFO.

The engine writes bytes when `tx_stream_valid` is asserted and `full` is deasserted. If `full` is asserted, the engine must pause response streaming until space is available.

UART clock and baud rate are parameters; the production settings are defined by the host protocol and board wrapper.

## Ports

| Direction | Port Name | Size | Description |
| --------- | --------- | ---- | ----------- |
| Input | `clk` | 1 | Engine-side clock. |
| Input | `uart_clk` | 1 | UART-side clock. |
| Input | `engine_rst_n` | 1 | Engine-domain synchronous active-low reset. |
| Input | `uart_rst_n` | 1 | UART-domain synchronous active-low reset. |
| Input | `tx_stream` | 8 | Response byte from the engine. |
| Input | `tx_stream_valid` | 1 | Indicates `tx_stream` is valid data that should be transmitted. |
| Output | `uart_tx` | 1 | UART output signal. |
| Output | `full` | 1 | Indicates that the output FIFO is full and no new input should be written. |
