# Build, Test, and Synthesis

Run `python -m tools.hardware_build` from the repository root with Python 3.10 or newer. The CLI uses the standard library and supports Windows and Linux. Generated projects, simulator output, logs, and reports live under `work/build/`.

## Requirements

| Task | Required tools |
| ---- | -------------- |
| List or validate build metadata; generate data | Python |
| Compile RTL source sets | ModelSim/Questa: `vlib`, `vlog`, and `vsim` on `PATH` |
| Run RTL tests or profiles | Verilator with a C++ build toolchain, or ModelSim/Questa, on `PATH` |
| Synthesize Intel/Altera targets; program the DE1-SoC | Quartus tools on `PATH` |
| Synthesize Xilinx targets | Vivado on `PATH` |

## Inspect and Validate

```text
python -m tools.hardware_build list
python -m tools.hardware_build validate
```

`list` shows source sets, tests, generated data, and targets from [`hardware/build/manifest.json`](../../hardware/build/manifest.json). `validate` checks the manifest and referenced files. Use `python -m tools.hardware_build <command> --help` for a command's options.

## Run Tests

Run generated-data checks, core Python tests, and all RTL tests:

```text
python -m tools.hardware_build check
```

Run only RTL tests, or select tests by name from `list`:

```text
python -m tools.hardware_build test
python -m tools.hardware_build test --name <test-name> --simulator verilator
```

Repeat `--name` to select multiple tests. Both `test` and `check` accept these options:

| Option | Use |
| ------ | --- |
| `--simulator auto\|verilator\|modelsim\|both` | `auto` prefers Verilator; `both` runs every selected bench in both simulators. |
| `--jobs <count>` | Set the number of concurrent RTL tests. |
| `--timeout <seconds>` | Set the wall-clock limit per RTL simulation. |

A selected backend's failure is reported as a failure. Simulator builds are cached and logs are kept under `work/build/sim/`.

`check` includes host, build-tool, benchmark, search-tuning, and mocked live-FPGA Python tests. To include evaluation-tuning tests, install `requirements-tuning.txt` and run `check --tuning`.

Compile source sets without running a testbench:

```text
python -m tools.hardware_build compile --set portable-rtl
```

This command requires ModelSim/Questa. Repeat `--set` to select more source sets.

## Generate Hardware Data

```text
python -m tools.hardware_build gen-data
```

The command runs the manifest's deterministic generators and fails if their outputs differ from tracked files. Use `gen-data --update` to keep intentional changes. Synthesis checks generated data before invoking vendor tools; `synth --update-generated-data` keeps regenerated changes as part of that build.

## Synthesize and Inspect Results

```text
python -m tools.hardware_build synth --target quartus-de1-soc
python -m tools.hardware_build synth-report --target quartus-de1-soc
python -m tools.hardware_build timing-paths --target quartus-de1-soc
```

Quartus reuses valid build results. Use `--clean` to delete the target build directory and force a full build, `--jobs <count>` to limit parallel processors, `--seed <seed>` to choose a fitter seed, or `--stream-logs` to show vendor output while building.

`synth-report` shows utilization and timing from an existing result; omit `--target` to select the most recently modified result. Add `--verbose` for the complete component hierarchy. `timing-paths` reads an existing Quartus fit and reports failing setup paths, or the tightest passing paths when timing is met; `--limit <count>` controls the number shown.

Generic Xilinx targets require a device part:

```text
python -m tools.hardware_build synth --target vivado-generic --part <xilinx-part>
python -m tools.hardware_build synth --target vivado-nnue --part <xilinx-part>
```

`vivado-generic` checks the portable design with clock-only constraints; `vivado-nnue` isolates the NNUE evaluator. These targets do not provide a complete Xilinx board build.

## Program the FPGA

After a successful DE1-SoC build:

```text
python -m tools.hardware_build flash --target quartus-de1-soc
```

This programs the volatile `.sof` image over JTAG. Use `--dry-run` to inspect the programmer command, `--file <path>` to select an image, `--cable <name-or-number>` to select a cable, or `--device-index <index>` to override JTAG device detection. See [DE1-SoC setup](../usage/de1-soc-uci.md) for wiring and host connection.

## Select Engine Settings

Search policies live under `hardware/config/search/`; engine profiles under `hardware/config/engine/` select the policy, hardware capacities, clocks, and instrumentation. The `history_heuristic` object selects the history table entry count and signed entry width. History reset priors and the three ascending quiet-bucket boundaries may be negative. The prior and positive reward must fit the configured signed entry width. Vendor, device, constraints, and fitter settings belong to the manifest target.

For a target with an engine profile, use another profile without editing the manifest:

```text
python -m tools.hardware_build synth --target quartus-de1-soc --engine-config <path>
```

Synthesis and [runtime profiling](engine-profiling.md) resolve engine profiles through the same configuration loader. Each build generates its own `rtl_config.sv`; do not edit generated packages. Standalone compilation, tests, and module synthesis use the manifest's standalone type configuration.

## Check a Connected FPGA

Install the host dependencies and program the board as described in [DE1-SoC setup](../usage/de1-soc-uci.md), then run:

```text
python -m tests.live_fpga --port <serial-port>
```

This runs timing, repetition, fifty-move rule, and perft checks against hardware. If `--port` is omitted, it uses `FPGA_CHESS_PORT` or USB-UART auto-detection. Use `--startup-timeout`, `--search-timeout`, and `--verbose` to diagnose connection or search failures. `--depth` controls the repetition search depth, subject to the suite's minimum. These hardware checks are separate from `check`.

## Add a Test or Target

Register RTL tests in the manifest with the smallest complete source set, testbench files, and top module. Each bench must print a positive `Pass Count` and zero `Fail Count`; missing completion markers fail the run. Use deterministic scenarios, explicit fixture policies, shared enum names, and a bench-level timeout. Place Python tests under the matching subsystem in `tests/`.

Register new synthesis targets with their source set, top module, device, constraints, and vendor settings. Keep vendor-specific IP in target source sets or behind wrappers so portable RTL remains usable by Intel/Altera and Xilinx.
