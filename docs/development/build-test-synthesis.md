# Build, Test, and Synthesis

The repo-level entrypoint is `python tools/fpga_chess.py`. All scripts are written with pure Python standard library so the same commands work on Windows and Linux when the relevant EDA tools are on `PATH`.

## Manifests

Build metadata lives in `hardware/build/manifest.json`.

`source_sets` are ordered lists of RTL files and `@other-set` references; order is significant because packages and imported helper functions must compile before dependent modules.

`tests` map a test name to a source set, testbench file, and simulator top module.

`generated_data` maps deterministic generator scripts to the files they are expected to produce.

`synthesis_targets` define the vendor tool, top module, source set, constraints, and target device information used to generate temporary project files.

## Commands

`python tools/fpga_chess.py list` prints the known source sets, tests, generated data, and synthesis targets.

`python tools/fpga_chess.py validate` validates the manifest structure, source-set graph, and required input files.

`python tools/fpga_chess.py gen-data` runs the deterministic data generators and fails if tracked outputs would change; without `--update`, changed outputs are restored so the command is safe as a check. The PST and Zobrist generators emit both `.hex` reference data and generated SystemVerilog lookup packages used by the portable RTL.

`python tools/fpga_chess.py gen-data --update` leaves regenerated tracked outputs in place when an intentional data update is being made.

`python tools/fpga_chess.py compile --set portable-rtl` compiles an RTL source set with ModelSim/Questa into a clean simulator library under `work/build/compile/`.

`python tools/fpga_chess.py test` compiles and runs all current SystemVerilog testbenches with ModelSim/Questa. Use repeated `--name <test>` options to select tests and `--jobs <count>` to run independent tests concurrently.

`python tools/fpga_chess.py check` verifies generated data, runs the host-side Python unit tests, and runs all SystemVerilog tests. It accepts `--jobs <count>` concurrency control for RTL tests.

`python tools/fpga_chess.py synth --target quartus-de1-soc` generates a Quartus project under `work/build/quartus-de1-soc/`, uses `de1_soc` as the top-level entity, imports matching DE1-SoC pin assignments from the board template, and runs map, fit, assembler, and timing analysis. Pass `--jobs <count>` to override the automatic Quartus processor count.

The generated Quartus project adds the repo root and target build directory as `SEARCH_PATH` entries and includes generated data outputs as project files so memory/table assets are visible to Quartus from the build directory.

Targets may define `map_effort` and `fit_effort` in the manifest; the DE1-SoC target uses fast map and fitter effort to keep first-pass synthesis runtime bounded at the possible cost of lower Fmax or higher resource use.

The DE1-SoC synthesis source set uses the same portable RTL path as generic synthesis plus the board-level `de1_soc.sv` wrapper.

`python tools/fpga_chess.py synth --target vivado-generic --part <xilinx-part>` generates a generic Vivado batch synthesis project under `work/build/vivado-generic/` with a clock-only XDC and no board pin constraints.

`python tools/fpga_chess.py synth-report` prints the results of the most recently modified synthesis target without running an EDA tool. Pass `--target <name>` to select a specific result. The report includes the target, device, timestamp, total and per-stage tool time, run status, device resource usage and percentages reported by the vendor, clock/timing results, and hierarchical per-component utilization when the vendor generated those reports. A failed or interrupted synthesis is identified and any partial reports remain available; if Quartus stops before generating resource reports, the command instead summarizes its log progress, runtime, parsed/elaborated entity counts, warnings, errors, and termination state while clearly marking utilization and Fmax unavailable.

Each new synthesis run writes `synthesis.json` beside its vendor reports so timestamps, status, and measured stage durations do not depend on vendor-specific log formatting. Quartus hierarchy data is read from its map/fit reports, while the generated Vivado flow requests hierarchical utilization explicitly. Runs created before this metadata was added can still be inspected, but their exact status and duration are reported as unavailable.

## Adding Tests or Targets

To add a new RTL test, add or reuse a source set, add the testbench file and top module under `tests`, then run `python tools/fpga_chess.py test --name <test-name>`.

To add a new board target, create a new `synthesis_targets` entry with its own source set, top module, constraints, and vendor tool settings; generated project files should still be written only under `work/build/`.

Vendor-specific IP should stay in target-specific source sets or behind stable wrappers so the portable RTL source sets remain usable by both Intel/Altera and Xilinx flows.
