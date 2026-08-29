# DE1-SoC and UCI Host Setup

The DE1-SoC target communicates with the Python UCI host through an external 3.3-V USB-UART adapter. Run all commands from the repository root with Python 3.10 or newer.

## Hardware Connection

Connect the adapter with power removed from the board and adapter.

| USB-UART adapter | DE1-SoC GPIO | Role |
| ---------------- | ------------ | ---- |
| RX | `GPIO_0[7]` | FPGA transmit output |
| TX | `GPIO_0[9]` | FPGA receive input |
| GND | GPIO ground | Common signal reference |

Use a 3.3-V TTL adapter that supports 2,000,000 baud. Do not connect an RS-232-level or 5-V serial interface, and do not connect the adapter's supply output to the board.

## Build and Program

Build and program the volatile DE1-SoC image with Quartus:

```text
python -m tools.hardware_build synth --target quartus-de1-soc
python -m tools.hardware_build flash --target quartus-de1-soc
```

The FPGA image is lost when the board is powered off and must be programmed again after the next power-up.

## Run the UCI Host

Install the host dependencies:

```text
python -m pip install python-chess pyserial
```

List the serial ports visible to the host:

```text
python -m software.engine --list-ports
```

Start the engine with an explicit port:

```text
python -m software.engine --port <serial-port>
```

Typical port names are `COM5` on Windows and `/dev/ttyUSB0`, `/dev/ttyACM0`, or a `/dev/serial/by-id/` path on Linux. Linux users may need to grant their account access to the serial device through the distribution's serial-port group.

The port may instead be set through `FPGA_CHESS_PORT`. When neither an argument nor the environment variable is supplied, the host waits briefly for one clearly identifiable USB-UART adapter and refuses to guess when multiple candidates are similarly plausible.

## Connection Behavior

Each connection resets the protocol with UART BREAK, waits for board initialization, verifies clean status, and starts a new game. The UCI handshake reports synthesized engine settings as fixed options.

The host advertises the standard UCI `Ponder` option. `go ponder` searches the speculative position to the hardware depth ceiling without consuming the normal clock budget, and `ponderhit` restarts the saved search limit on the same transposition-table-warmed position.

The UART byte protocol, reset sequence, and error behavior are specified in [Host-FPGA Protocol](../protocols/host-fpga-protocol.md).

## Troubleshooting

- If no port appears, check the USB-UART driver, cable, and operating-system serial permissions.
- If auto-detection reports multiple candidates, pass `--port` or set `FPGA_CHESS_PORT` explicitly.
- If the connection times out, confirm that adapter TX connects to `GPIO_0[9]`, adapter RX connects to `GPIO_0[7]`, both sides share ground, and the adapter supports 2,000,000 baud.
- Reconnect the host after reprogramming or resetting the FPGA so the normal BREAK and initialization sequence runs again.
