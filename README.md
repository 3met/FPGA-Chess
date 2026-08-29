# FPGA Chess

FPGA Chess is an experimental chess engine implemented primarily in SystemVerilog. The FPGA performs move generation, board updates, evaluation, iterative-deepening search, and transposition-table access; a Python host exposes the engine through UCI and translates commands to the FPGA byte protocol.

The complete board target is the Intel/Altera DE1-SoC, where the FPGA-side SDR SDRAM stores the transposition table. The portable RTL also has generic Xilinx Vivado synthesis targets for compatibility and resource checks.

## Repository Layout

| Path | Purpose |
| ---- | ------- |
| [`docs/`](docs/README.md) | Architecture, module, protocol, usage, and development documentation. |
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

Python 3.10 or newer is required. ModelSim or Questa supplies `vlib`, `vlog`, and `vsim` for RTL compilation and tests. The Python build CLI itself uses only the standard library and supports Windows and Linux.

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

When `--port` is omitted, the host uses `FPGA_CHESS_PORT` or attempts to identify an unambiguous USB-UART adapter. See [DE1-SoC and UCI Host Setup](docs/usage/de1-soc-uci.md) for wiring, port selection, connection behavior, and pondering. The FPGA command and response format is specified in [Host-FPGA Protocol](docs/protocols/host-fpga-protocol.md).

## Profiling, Tuning, and Benchmarks

Cycle-accurate simulation profiling is documented in [Engine Runtime Profiling](docs/development/engine-profiling.md). Evaluation training is documented in [Evaluation Tuning](docs/development/evaluation-tuning.md).

`python -m software.benchmarks` runs opt-in checks against a connected FPGA. These hardware-dependent commands are not part of the normal `check` workflow. Each benchmark command accepts `--port <serial-port>`; when it is omitted, the host uses `FPGA_CHESS_PORT` or USB-UART auto-detection.
