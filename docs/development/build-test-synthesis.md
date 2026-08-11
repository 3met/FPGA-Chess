# Build, Test, and Synthesis

The repo-level entrypoint is `python -m tools.hardware_build`. The package is split into focused modules for manifest handling, data generation, simulation, synthesis, reporting, shared helpers, and command-line parsing. All scripts are written with pure Python standard library so the same commands work on Windows and Linux when the relevant EDA tools are on `PATH`.

## Manifests

Build metadata lives in `hardware/build/manifest.json`.

`source_sets` are ordered lists of RTL files and `@other-set` references; order is significant because packages and imported helper functions must compile before dependent modules. Higher-level sets reference the smallest complete subsystem sets instead of repeating their files or transitive dependencies.

`tests` map a test name to a source set, testbench file, and simulator top module.

`generated_data` maps deterministic generator scripts to the files they are expected to produce.

`synthesis_targets` define the vendor tool, top module, source set, constraints, and target device information used to generate temporary project files.

## Commands

`python -m tools.hardware_build list` prints the known source sets, tests, generated data, and synthesis targets.

`python -m tools.hardware_build validate` validates the manifest structure, source-set graph, and required input files.

`python -m tools.hardware_build gen-data` runs the deterministic data generators and fails if tracked outputs would change; without `--update`, changed outputs are restored so the command is safe as a check. The PST and Zobrist generators emit both `.hex` reference data and generated SystemVerilog lookup packages used by the portable RTL.

`python -m tools.hardware_build gen-data --update` leaves regenerated tracked outputs in place when an intentional data update is being made.

`python -m tools.hardware_build compile --set portable-rtl` compiles an RTL source set with ModelSim/Questa into a clean simulator library under `work/build/compile/`.

`python -m tools.hardware_build test` compiles and runs all current SystemVerilog testbenches with ModelSim/Questa. Use repeated `--name <test>` options to select tests, `--jobs <count>` to run independent tests concurrently, and `--timeout <seconds>` to adjust the per-simulation wall-clock limit (600 seconds by default).

`python -m tools.hardware_build profile` runs one engine-only search through the external TT, cache, CDC bridge, and DE1 SDR SDRAM controller, then prints detailed runtime statistics and saves text and JSON reports. It prefers a cached Verilator native build when available, with ModelSim selectable as a reference backend. It defaults to a 50 ms simulated search from the normal starting position and accepts `--fen`, one of `--depth`/`--nodes`/`--time-ms`, hardware configuration overrides, and opt-in event-trace or waveform artifacts. See [engine-profiling.md](engine-profiling.md).

`python -m tools.hardware_build check` verifies generated data, runs the core Python suites under `tests/software`, `tests/benchmarks`, and `tests/hardware_build`, and runs all SystemVerilog tests. Add `--tuning` to run `tests/tuning` when the optional dependencies from `requirements-tuning.txt` are installed. The command accepts `--jobs <count>` concurrency control and `--timeout <seconds>` for RTL tests. A simulation that exceeds its limit is terminated and reported as failed.

`python -m tools.hardware_build synth --target quartus-de1-soc` verifies generated data, refreshes the Quartus project and copied generated data under `work/build/quartus-de1-soc/`, preserves Quartus compilation databases for reuse, uses `de1_soc` as the top-level entity, imports matching DE1-SoC pin assignments from the board template, and runs map, fit, assembler, and timing analysis while writing each stage's output to its own log. A successful TimeQuest process still fails the build if its summary contains negative setup or hold slack. Interrupting the build stops the active vendor tool and its worker processes before the CLI exits. Pass `--stream-logs` to also print the live vendor output, `--clean` to discard the existing Quartus build directory, `--update-generated-data` to regenerate and keep changed generated data instead of failing on drift, or `--jobs <count>` to override the automatic Quartus processor count.

`python -m tools.hardware_build flash --target quartus-de1-soc` programs the generated `fpga_chess.sof` into the DE1-SoC through JTAG using `quartus_pgm`. This is volatile FPGA configuration: it is lost when the board powers down and does not modify the configuration flash. Before programming, the Quartus backend scans the JTAG chain and selects the one device whose target-specific `jtag_id` matches; this correctly chooses device 2 on the DE1-SoC because its HPS is device 1. Pass `--device-index <position>` to override detection for an unusual or ambiguous chain, `--cable <name-or-number>` when Quartus cannot select the desired cable, `--file <path>` to program another `.sof`, or `--dry-run` to inspect the command without touching hardware. The target-specific `programming_targets` manifest section keeps programming backends independent from synthesis targets so later vendor support can be added without changing the CLI.

The generated Quartus project adds the repo root and target build directory as `SEARCH_PATH` entries and includes generated data outputs as project files so memory/table assets are visible to Quartus from the build directory.

Targets may define a positive integer `seed`; synthesis metadata records it for every target, and Quartus targets apply it to the fitter. Quartus targets may also define `message_disable` with routine informational message IDs or narrowly understood tool-only warnings to suppress from the normal Quartus message stream; RTL, timing, CDC, and I/O warnings should remain unsuppressed. Targets may also define `map_effort` and `fit_effort` in the manifest; the DE1-SoC target uses fast mapping to avoid excessive logic expansion in Quartus 20.1 and standard fitting to preserve timing quality.

The DE1-SoC synthesis source set uses the same portable RTL path as generic synthesis plus the board-level `de1_soc.sv` wrapper. Its `engine_clock_mhz` target setting is the single source of truth for the engine rate: the build generates `engine_build_config.svh` with the exact engine frequency and a fresh nonzero random 64-bit build ID, and records that ID in `synthesis.json`. It also generates a configured copy of the Intel PLL IP under the target build directory. Change `engine_clock_mhz` when selecting a different DE1-SoC engine frequency.

The DE1 PLL template also supplies the fixed 100 MHz SDRAM logic clock and phase-adjusted SDRAM output clock. The portable TT frontend and memory protocol remain vendor-neutral; only this clock wrapper and the physical SDRAM pins are target-specific.

`python -m tools.hardware_build synth --target vivado-generic --part <xilinx-part>` generates a generic Vivado batch synthesis project under `work/build/vivado-generic/` with a clock-only XDC and no board pin constraints.

`python -m tools.hardware_build synth --target vivado-nnue --part <xilinx-part>` synthesizes the NNUE evaluator directly at 40 MHz so its inferred memories and arithmetic are checked on Xilinx devices.

`python -m tools.hardware_build synth-report` prints a compact, aligned summary of the most recently modified synthesis target without running an EDA tool. Pass `--target <name>` to select a specific result or `--verbose` to show the complete component hierarchy. The report includes the target, device, timestamp, friendly total and per-stage tool times, run status, deduplicated device resource usage and percentages reported by the vendor, clock/timing results, and major-component utilization when the vendor generated those reports. A failed or interrupted synthesis is identified and any partial reports remain available; if Quartus stops before generating resource reports, the command instead summarizes its log progress, runtime, parsed/elaborated entity counts, warnings, errors, and termination state while clearly marking utilization and Fmax unavailable.

`python -m tools.hardware_build timing-paths --target quartus-de1-soc` runs TimeQuest against an existing Quartus fit and prints the 15 worst failing setup paths, with at most one path per endpoint. When timing is met, it instead clearly labels and prints the 15 tightest passing setup paths. Pass `--limit <count>` to choose a different bounded number; this avoids producing an impractically large report when a design has many paths. Separate failing and tightest-path summary reports are saved beside the Quartus results.

Each new synthesis run writes `synthesis.json` beside its vendor reports so timestamps, status, and measured stage durations do not depend on vendor-specific log formatting. Quartus hierarchy data is read from its map/fit reports, while the generated Vivado flow requests hierarchical utilization explicitly. Runs created before this metadata was added can still be inspected, but their exact status and duration are reported as unavailable.

## Adding Tests or Targets

To add a new RTL test, add or reuse a source set, add the testbench file and top module under `hardware/tb`, then run `python -m tools.hardware_build test --name <test-name>`. Python tests belong under the matching subsystem directory in `tests/`.

To add a new board target, create a new `synthesis_targets` entry with its own source set, top module, constraints, and vendor tool settings; generated project files should still be written only under `work/build/`.

Vendor-specific IP should stay in target-specific source sets or behind stable wrappers so the portable RTL source sets remain usable by both Intel/Altera and Xilinx flows.
