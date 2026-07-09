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

`python tools/fpga_chess.py gen-data` runs the deterministic data generators and fails if tracked outputs would change; without `--update`, changed outputs are restored so the command is safe as a check. The PST and Zobrist generators emit both `.hex` reference data and generated SystemVerilog lookup packages used by the portable RTL.

`python tools/fpga_chess.py gen-data --update` leaves regenerated `.hex` files in place when an intentional data update is being made.

`python tools/fpga_chess.py compile --set portable-rtl` compiles an RTL source set with ModelSim/Questa into a clean simulator library under `work/build/compile/`.

`python tools/fpga_chess.py test` compiles and runs all current SystemVerilog testbenches with ModelSim/Questa and reports pass/fail counts when the transcript prints them.

`python tools/fpga_chess.py synth --target quartus-de1-soc` generates a Quartus project under `work/build/quartus-de1-soc/`, uses `main` as the current top-level entity, imports matching DE1-SoC pin assignments from the board template, and runs map, fit, assembler, and timing analysis.

Quartus synthesis automatically detects the number of processors available to the current process, records that value in `NUM_PARALLEL_PROCESSORS`, and passes it explicitly to `quartus_map`, `quartus_fit`, and `quartus_sta` with `--parallel=<processors>`.

The generated Quartus project adds the repo root and target build directory as `SEARCH_PATH` entries and includes generated data outputs as project files so memory/table assets are visible to Quartus from the build directory.

Targets may define `map_effort` and `fit_effort` in the manifest; the DE1-SoC target uses fast map and fitter effort to keep first-pass synthesis runtime bounded at the possible cost of lower Fmax or higher resource use.

The DE1-SoC synthesis source set uses the same portable RTL path as generic synthesis plus the board-level `main.sv` wrapper. The board target configures one search context and eight allocated plies in `main.sv` to keep area bounded, but it still instantiates the real search controller, board-update pipeline, move generator, static evaluator, transposition-table path, and UART command layer.

Current synthesis note: Quartus 20.1 completes analysis and synthesis of the real DE1-SoC design, including the current exhaustive combinational `move_generator`. The July 2026 result infers the 1024-entry compact TT as a 96,256-bit M10K-backed `altsyncram`; the TT hierarchy uses 469 combinational ALUTs and 685 registers instead of the earlier register-array result's 147,929 ALUTs and 96,925 registers. Moving the eight-read Zobrist constant lookup from combinational case logic into four replicated synchronous true-dual-port M10K ROMs reduced the fit estimate from 104,507 ALMs (326%) to 92,057 ALMs (287%), while block-memory data bits rose from 104,944 to 255,920. The full design still fails fitting, but this is down from 219,568 ALMs, or 685%, before the TT RAM-inference fix. No simplified wrapper or stub is used for this result.

`python tools/fpga_chess.py synth --target vivado-generic --part <xilinx-part>` generates a generic Vivado batch synthesis project under `work/build/vivado-generic/` with a clock-only XDC and no board pin constraints.

## Adding Tests or Targets

To add a new RTL test, add or reuse a source set, add the testbench file and top module under `tests`, then run `python tools/fpga_chess.py test --name <test-name>`.

To add a new board target, create a new `synthesis_targets` entry with its own source set, top module, constraints, and vendor tool settings; generated project files should still be written only under `work/build/`.

Vendor-specific IP should stay in target-specific source sets or behind stable wrappers so the portable RTL source sets remain usable by both Intel/Altera and Xilinx flows.
