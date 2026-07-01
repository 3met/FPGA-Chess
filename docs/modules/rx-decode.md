### Input Decoder

The input decoder contains a 8-bit, 1024 word FIFO

| Direction | Port Name         | Size (bits) | Description                                                                                                           |
| --------- | ----------------- | ----------- | --------------------------------------------------------------------------------------------------------------------- |
| Input     | `uart_rx`         | 1           | UART input signal.                                                                                                    |
| Input     | `mark_read`       | 1           | Indicates that the `decoded` output has been read                                                                     |
| Output    | `rx_stream`       | 8           | Stream of decoded UART command/data. If FIFO is empty, IDLE command is output.                                        |
| Output    | `rx_stream_valid` | 1           | Indicates whether `rx_stream` operation/data is valid.                                                                |
| Output    | `kill`            | 1           | Indicator to kill the current operation. Also indicates that the input buffer has been cleared. Asserted for 1 cycle. |
| Output    | `remote_reset`    | 1           | Indicates an attempt to remotely reset the engine. Asserted for 1 cycle.                                              |
| Output    | `rx_error`        | 1           | Indicates there was an error on the received UART communication.                                                      |
