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
| `software/` | Python host-side helpers. |
