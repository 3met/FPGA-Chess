# FPGA Chess

FPGA Chess is an experimental chess engine project targeting FPGA hardware. The design explores pipeline-parallel board updates, move-generation, search, and evaluation logic using SystemVerilog, with Python utilities for host-side encoding, communication, and testing.

## Layout

| Path | Purpose |
| ---- | ------- |
| `docs/` | Architecture notes and module specifications. Start with [docs/README.md](docs/README.md). |
| `hardware/rtl/` | SystemVerilog RTL. |
| `hardware/rtl/move_generator/` | Move-generation RTL implementation files. |
| `hardware/tb/` | SystemVerilog testbenches. |
| `hardware/data/` | Generated lookup data such as piece-square tables. |
| `hardware/build/` | Build manifests for source sets, tests, generated data, and synthesis targets. |
| `tools/fpga_chess.py` | Unified Python build, test, data-generation, and synthesis CLI. |
| `software/` | Python host-side UCI engine, FPGA protocol encoder/decoder, serial transport, and helper scripts. |

## Build, Test, and Synthesis

Use `python tools/fpga_chess.py list` to show known source sets, SystemVerilog tests, generated data, and synthesis targets.

Use `python tools/fpga_chess.py validate` to validate the manifest, its source-set references, and required input files.

Use `python tools/fpga_chess.py gen-data` to verify deterministic generated data is current; use `--update` only when intentionally accepting regenerated `.hex` output.

Use `python tools/fpga_chess.py compile --set portable-rtl` for a fast ModelSim/Questa compile-order check.

Use `python tools/fpga_chess.py test` to compile and run the current SystemVerilog testbenches. Pass `--name <test>` more than once to select tests, `--jobs <count>` to run independent tests concurrently, or `--timeout <seconds>` to adjust the per-simulation wall-clock limit (600 seconds by default).

Use `python tools/fpga_chess.py check` for the usual comprehensive check: generated data, host-side Python unit tests, and all RTL tests. It accepts `--jobs <count>` and `--timeout <seconds>` for the RTL tests; a stalled simulation is reported as a failed test rather than leaving the command running indefinitely.

Use `python tools/fpga_chess.py synth --target quartus-de1-soc` for the current Quartus DE1-SoC synthesis smoke path, and `python tools/fpga_chess.py synth --target vivado-generic --part <xilinx-part>` for generic Vivado synthesis. Pass `--jobs <count>` to cap Quartus parallel processor use.

Use `python tools/fpga_chess.py synth-report` to print utilization by resource and component, device percentages, clock/timing results, and timestamp/runtime metadata from the latest synthesis without rerunning it. Pass `--target <name>` to select a specific target.

The CLI is pure Python standard library and writes generated projects, simulator libraries, transcripts, and reports under ignored `work/build/`.

Required tools depend on the command: ModelSim/Questa provides `vlib`, `vlog`, and `vsim` for `compile`, `test`, and `check`; Quartus provides `quartus_map`, `quartus_fit`, `quartus_asm`, and `quartus_sta` for `quartus-de1-soc`; Vivado provides `vivado` for `vivado-generic`.

## Host UCI Engine

Run `python software/fpga_engine.py` to expose the FPGA as a UCI chess engine. The host defaults to `FPGA_CHESS_PORT` when set, otherwise it auto-detects a single or clearly identifiable USB UART port; pass `--port <serial-port>` on headless systems with multiple adapters. The host requires `python-chess` for legal UCI position validation and `pyserial` for UART communication; it serializes commands using the protocol in `docs/protocols/`.
