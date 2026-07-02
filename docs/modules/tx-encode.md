# TX Encode (`tx_encode`)

Status: partially implemented; this document describes the final target contract.

The output encoder buffers response bytes from the engine and transmits them over UART.

## Behavior

The output encoder contains an 8-bit FIFO with parameterized depth. The documented default depth is 1024 words.

The engine writes bytes when `tx_stream_valid` is asserted and `full` is deasserted. If `full` is asserted, the engine must pause response streaming until space is available.

## Ports

| Direction | Port Name | Size | Description |
| --------- | --------- | ---- | ----------- |
| Input | `clk` | 1 | Clock. |
| Input | `rst_n` | 1 | Synchronous active-low reset. |
| Input | `tx_stream` | 8 | Response byte from the engine. |
| Input | `tx_stream_valid` | 1 | Indicates `tx_stream` is valid data that should be transmitted. |
| Output | `uart_tx` | 1 | UART output signal. |
| Output | `full` | 1 | Indicates that the output FIFO is full and no new input should be written. |

## Current RTL Notes

The current RTL directly drives the UART transmitter and does not yet implement the FIFO or drive `full`.
