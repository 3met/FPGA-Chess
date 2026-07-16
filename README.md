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
| `tools/hardware_build/` | Python build, test, data-generation, and synthesis tools for the RTL. |
| `software/` | Python host-side UCI engine, FPGA protocol encoder/decoder, serial transport, and helper scripts. |

The Python software is divided by responsibility: `software/engine/` contains the FPGA protocol, serial transport, FEN encoder, and UCI host; `software/benchmarks/` contains the live-FPGA session, named positions, sanity/perft checks, and puzzle rating tool; and `software/tests/` contains hardware-independent unit tests. The few modules directly under `software/` are compatibility entrypoints for older commands.

## Build, Test, and Synthesis

Use `python -m tools.hardware_build list` to show known source sets, SystemVerilog tests, generated data, and synthesis targets.

Use `python -m tools.hardware_build validate` to validate the manifest, its source-set references, and required input files.

Use `python -m tools.hardware_build gen-data` to verify deterministic generated data is current; use `--update` only when intentionally accepting regenerated `.hex` output.

Use `python -m tools.hardware_build compile --set portable-rtl` for a fast ModelSim/Questa compile-order check.

Use `python -m tools.hardware_build test` to compile and run the current SystemVerilog testbenches. Pass `--name <test>` more than once to select tests, `--jobs <count>` to run independent tests concurrently, or `--timeout <seconds>` to adjust the per-simulation wall-clock limit (600 seconds by default).

Use `python -m tools.hardware_build check` for the usual comprehensive check: generated data, host-side Python unit tests, and all RTL tests. It accepts `--jobs <count>` and `--timeout <seconds>` for the RTL tests; a stalled simulation is reported as a failed test rather than leaving the command running indefinitely.

Use `python -m tools.hardware_build synth --target quartus-de1-soc` for the current Quartus DE1-SoC synthesis smoke path, and `python -m tools.hardware_build synth --target vivado-generic --part <xilinx-part>` for generic Vivado synthesis. Pass `--jobs <count>` to cap Quartus parallel processor use.

After a successful DE1-SoC Quartus synthesis, use `python -m tools.hardware_build flash --target quartus-de1-soc` to program its `.sof` over JTAG. This is a volatile configuration that is cleared on power-down; the tool identifies the target by JTAG ID rather than assuming a chain position. Pass `--device-index <position>` to override that detection, `--cable <name-or-number>` to choose a Quartus cable, or `--dry-run` to inspect the command first.

Use `python -m tools.hardware_build synth-report` to print utilization by resource and component, device percentages, clock/timing results, and timestamp/runtime metadata from the latest synthesis without rerunning it. Pass `--target <name>` to select a specific target.

The CLI is pure Python standard library and writes generated projects, simulator libraries, transcripts, and reports under ignored `work/build/`.

Required tools depend on the command: ModelSim/Questa provides `vlib`, `vlog`, and `vsim` for `compile`, `test`, and `check`; Quartus provides `quartus_map`, `quartus_fit`, `quartus_asm`, and `quartus_sta` for `quartus-de1-soc`, plus `quartus_pgm` for `flash`; Vivado provides `vivado` for `vivado-generic`.

## Host UCI Engine

Run `python -m software.engine` to expose the FPGA as a UCI chess engine. The host defaults to `FPGA_CHESS_PORT` when set, otherwise it auto-detects a single or clearly identifiable USB UART port; pass `--port <serial-port>` on headless systems with multiple adapters. The host requires `python-chess` for legal UCI position validation and `pyserial` for UART communication; install them with `python -m pip install python-chess pyserial`. It serializes commands using the protocol in `docs/protocols/`. Normal FPGA scores are reported as UCI centipawns; scores at or beyond the FPGA mate threshold are reported as signed UCI `mate` distances in moves.

For manual bring-up, enter `fpga help` on the host's standard input. The non-UCI `fpga` commands report status and cached results, display or synchronize the local board, issue a UART BREAK reset, and run hardware perft. Their replies are emitted as UCI `info string` lines, so they are also safe to observe through a UCI console. `go perft <depth>` performs a software-side root divide: it generates legal root moves locally, runs FPGA perft below each child, and prints a move-by-move node table plus the total.

## UCI Test and Benchmark Tools

`python -m software.benchmarks` runs opt-in checks only against the checked-in FPGA host and its connected FPGA. The host auto-detects the serial port or uses `FPGA_CHESS_PORT`. For example: `python -m software.benchmarks all --depth 3`. `sanity` verifies `uci`, `isready`, deterministic fixed-depth node counts across `ucinewgame` on three named middlegame FENs, and a 500 ms `go movetime` response window of 475–525 ms on those same positions. `perft` runs the committed fast move-generation regression; `rate` evaluates an external Lichess CSV.

The named sanity and perft vectors are in `software/benchmarks/positions.py`; print the perft FEN/depth/reference-node list without touching hardware with `python -m software.benchmarks perft --list`. The perft suite expects this host's non-standard `go perft <depth>` output to end with `Nodes searched: <count>`; it is therefore a host/FPGA integration check, not a generic UCI feature. Rating input defaults to the ignored `puzzles/lichess_db_puzzle.csv` file and is never downloaded automatically. `rate` ignores puzzles below 1000 by default; pass `--min-rating 0` to restore the full data set. Its first run creates an ignored, rating-specific byte-offset index next to the CSV, then later runs load only the requested rows. It reports exact-solution accuracy plus a logistic estimate derived from the Lichess puzzle ratings and a 95% confidence interval; this is a reproducible comparative benchmark, not an official playing rating. These live-engine commands are deliberately not part of `python -m tools.hardware_build check`.
