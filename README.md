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
| `software/` | Python host-side helpers. |

## Build, Test, and Synthesis

Use `python tools/fpga_chess.py list` to show known source sets, SystemVerilog tests, generated data, and synthesis targets.

Use `python tools/fpga_chess.py gen-data` to verify deterministic generated data is current; use `--update` only when intentionally accepting regenerated `.hex` output.

Use `python tools/fpga_chess.py compile --set portable-rtl` for a fast ModelSim/Questa compile-order check.

Use `python tools/fpga_chess.py test` to compile and run the current SystemVerilog testbenches.

Use `python tools/fpga_chess.py synth --target quartus-de1-soc` for the current Quartus DE1-SoC synthesis smoke path, and `python tools/fpga_chess.py synth --target vivado-generic --part <xilinx-part>` for generic Vivado synthesis.

The CLI is pure Python standard library and writes generated projects, simulator libraries, transcripts, and reports under ignored `work/build/`.

Required tools depend on the command: ModelSim/Questa provides `vlib`, `vlog`, and `vsim` for `compile` and `test`; Quartus provides `quartus_map`, `quartus_fit`, and `quartus_sta` for `quartus-de1-soc`; Vivado provides `vivado` for `vivado-generic`.
