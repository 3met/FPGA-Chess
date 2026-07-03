# Build, Test, and Synthesis

The repo-level entrypoint is `python tools/fpga_chess.py`; it is intentionally pure Python standard library so the same commands work on Windows and Linux when the relevant EDA tools are on `PATH`.

## Manifests

Build metadata lives in `hardware/build/manifest.json`.

`source_sets` are ordered lists of RTL files and `@other-set` references; order is significant because packages and imported helper functions must compile before dependent modules.

`tests` map a test name to a source set, testbench file, and simulator top module.

`generated_data` maps deterministic generator scripts to the files they are expected to produce.

`synthesis_targets` define the vendor tool, top module, source set, constraints, and target device information used to generate temporary project files.

## Commands

`python tools/fpga_chess.py list` prints the known source sets, tests, generated data, and synthesis targets.

`python tools/fpga_chess.py gen-data` runs the deterministic data generators and fails if tracked outputs would change; without `--update`, changed outputs are restored so the command is safe as a check.

`python tools/fpga_chess.py gen-data --update` leaves regenerated `.hex` files in place when an intentional data update is being made.

`python tools/fpga_chess.py compile --set portable-rtl` compiles an RTL source set with ModelSim/Questa into a clean simulator library under `work/build/compile/`.

`python tools/fpga_chess.py test` compiles and runs all current SystemVerilog testbenches with ModelSim/Questa and reports pass/fail counts when the transcript prints them.

`python tools/fpga_chess.py synth --target quartus-de1-soc` generates a Quartus project under `work/build/quartus-de1-soc/`, uses `main` as the current top-level entity, imports matching DE1-SoC pin assignments from the board template, and runs map, fit, and timing analysis.

`python tools/fpga_chess.py synth --target vivado-generic --part <xilinx-part>` generates a generic Vivado batch synthesis project under `work/build/vivado-generic/` with a clock-only XDC and no board pin constraints.

## Adding Tests or Targets

To add a new RTL test, add or reuse a source set, add the testbench file and top module under `tests`, then run `python tools/fpga_chess.py test --name <test-name>`.

To add a new board target, create a new `synthesis_targets` entry with its own source set, top module, constraints, and vendor tool settings; generated project files should still be written only under `work/build/`.

Vendor-specific IP should stay in target-specific source sets or behind stable wrappers so the portable RTL source sets remain usable by both Intel/Altera and Xilinx flows.
