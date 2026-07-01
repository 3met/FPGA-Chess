### Output Encoder

The output encoder contains an 8-bit, 1024 word FIFO.

| Direction | Port Name         | Size (bits) | Description                                                               |
| --------- | ----------------- | ----------- | ------------------------------------------------------------------------- |
| Input     | `tx_stream`       | 8           | Result stream                                                             |
| Input     | `tx_stream_valid` | 1           | Indicates whether `tx_stream` is valid data that should be transmitted.   |
| Output    | `uart_tx`         | 1           | UART output signal.                                                       |
| Output    | `full`            | 1           | Indicates that the output FIFO is full and no new input should be written |
