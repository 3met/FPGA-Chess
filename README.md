# FPGA Chess

FPGA Chess is an experimental chess engine implemented primarily in SystemVerilog. The FPGA performs move generation, board updates, evaluation, iterative-deepening search, and transposition-table access; a Python host exposes the engine through UCI and translates commands to the FPGA byte protocol.

The design targets both Intel/Altera and Xilinx synthesis. The DE1-SoC configuration uses the board's SDR SDRAM for the transposition table.

## Repository Layout

| Path | Purpose |
| ---- | ------- |
| [`docs/`](docs/README.md) | Final-design specifications and development documentation. |
| `hardware/rtl/` | Vendor-neutral chess RTL, memory components, and board wrappers. |
| `hardware/tb/` | SystemVerilog testbenches. |
| `hardware/build/manifest.json` | Source sets, tests, generated data, and synthesis targets. |
| `hardware/data/` | Generated Zobrist and evaluation data. |
| `software/engine/` | UCI host, protocol encoding, FEN handling, and serial transport. |
| `software/benchmarks/` | Live-engine integration checks and puzzle benchmarking. |
| `tests/` | Python tests grouped by software subsystem. |
| `tools/hardware_build/` | Build, simulation, profiling, synthesis, and programming CLI. |
| `tools/tuning/` | Evaluation training and parameter export. |

Start with [the documentation index](docs/README.md) for the architecture and subsystem specifications. Development commands are documented in [Build, Test, and Synthesis](docs/development/build-test-synthesis.md).

## Quick Start

List and validate the build manifest:

```text
python -m tools.hardware_build list
python -m tools.hardware_build validate
```

Run generated-data checks, Python tests, and all RTL simulations:

```text
python -m tools.hardware_build check
```

Add `--tuning` to include the optional evaluation-tuning suite, which requires `requirements-tuning.txt`.

Compile only the portable RTL:

```text
python -m tools.hardware_build compile --set portable-rtl
```

Run a specific RTL test:

```text
python -m tools.hardware_build test --name <test-name>
```

ModelSim or Questa supplies `vlib`, `vlog`, and `vsim` for RTL compilation and tests. The Python build CLI itself uses only the standard library and supports Windows and Linux.

## Synthesis and Hardware

Build the DE1-SoC target with Quartus:

```text
python -m tools.hardware_build synth --target quartus-de1-soc
```

Program the volatile `.sof` over JTAG:

```text
python -m tools.hardware_build flash --target quartus-de1-soc
```

Generate a generic Xilinx synthesis project by supplying a device:

```text
python -m tools.hardware_build synth --target vivado-generic --part <xilinx-part>
```

Generated projects, simulator output, logs, and reports are written below the ignored `work/build/` directory.

## UCI Host

Install the host runtime dependencies:

```text
python -m pip install python-chess pyserial
```

Run the engine:

```text
python -m software.engine --port <serial-port>
```

When `--port` is omitted, the host uses `FPGA_CHESS_PORT` or attempts to identify a suitable USB UART. During the UCI handshake the host reads the FPGA build information and advertises its thread count, clock frequency, and search stack depth as fixed `spin` options whose default, minimum, and maximum are the synthesized value. If build-information discovery fails, the host reports the failure as an `info string` and still completes the handshake with `uciok`. The FPGA command and response format is specified in [Laptop-FPGA Communication](docs/protocols/laptop-fpga-communication.md).

## Profiling, Tuning, and Benchmarks

Cycle-accurate simulation profiling is documented in [Engine Runtime Profiling](docs/development/engine-profiling.md). Evaluation training is documented in [Evaluation Tuning](docs/development/evaluation-tuning.md).

`python -m software.benchmarks` runs opt-in checks against a connected FPGA. These hardware-dependent commands are not part of the normal `check` workflow.
