# RX Decode (`rx_decode`)

Status: partially implemented; this document describes the final target contract.

The input decoder receives UART bytes, buffers normal command/data bytes, and exposes a byte stream to the engine. Asynchronous kill/reset commands may bypass normal buffering so the host can interrupt a long search.

## Behavior

The input decoder contains an 8-bit FIFO with parameterized depth. The documented default depth is 1024 words.

If the FIFO is empty, `rx_stream_valid` is deasserted. The decoder should not emit a synthetic idle command byte as valid data.

Normal bytes may be dropped or flagged as overflow if the FIFO is full. The host is responsible for avoiding overflow by respecting engine readiness. Kill and remote reset are exceptions and should be recognized even when the normal FIFO is full.

## Ports

| Direction | Port Name | Size | Description |
| --------- | --------- | ---- | ----------- |
| Input | `clk` | 1 | Clock. |
| Input | `rst_n` | 1 | Synchronous active-low reset. |
| Input | `uart_rx` | 1 | UART input signal. |
| Input | `mark_read` | 1 | Indicates that the current decoded byte has been consumed. |
| Output | `rx_stream` | 8 | Decoded UART command/data byte. |
| Output | `rx_stream_valid` | 1 | Indicates `rx_stream` contains valid data. |
| Output | `kill` | 1 | Asserted for one cycle when an asynchronous kill command is received; normal buffered input is cleared if required by the command policy. |
| Output | `remote_reset` | 1 | Asserted for one cycle when a remote reset command is received. |
| Output | `rx_error` | 1 | Indicates UART framing error, FIFO overflow, or unsupported asynchronous control encoding. |

## Current RTL Notes

The current RTL directly exposes UART receiver bytes and does not yet implement the FIFO, kill, remote reset, or overflow behavior.
