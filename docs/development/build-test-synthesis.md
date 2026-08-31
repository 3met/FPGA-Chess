# Build, Test, and Synthesis

The repository entrypoint is `python -m tools.hardware_build`. It uses only the Python standard library and supports Windows and Linux when the required simulator or vendor tools are on `PATH`.

## Manifest

Build metadata lives in `hardware/build/manifest.json`.

| Section | Purpose |
| ------- | ------- |
| `source_sets` | Ordered RTL file groups and references to other groups. Compile order is significant. |
| `tests` | Test names, source sets, testbench files, and simulator top modules. |
| `generated_data` | Deterministic generators and their expected tracked outputs. |
| `synthesis_targets` | Vendor, device, top module, source set, constraints, and target-specific settings. |
| `programming_targets` | Programming backend and artifact information, kept separate from synthesis configuration. |

Generated projects, simulator libraries, logs, and reports are written under `work/build/`.

## Engine Configuration

Reusable search policies live under `hardware/config/search/`. Engine profiles live under `hardware/config/engine/` and select structural settings such as thread count, stack depth, clock frequency, TT sizing, and instrumentation. Synthesis targets reference an engine profile while vendor, device, source, constraint, and fitter settings remain in the build manifest.

Synthesis and runtime profiling resolve profiles through the same path so they use matching structural and search settings. A board target may define its own engine profile while reusing an existing search policy.

## Commands

| Command | Purpose |
| ------- | ------- |
| `python -m tools.hardware_build list` | List source sets, tests, generated data, and targets. |
| `python -m tools.hardware_build validate` | Validate the manifest graph and required files. |
| `python -m tools.hardware_build gen-data` | Regenerate deterministic data and fail if tracked outputs drift. |
| `python -m tools.hardware_build gen-data --update` | Keep intentional generated-data changes. |
| `python -m tools.hardware_build compile --set portable-rtl` | Compile one RTL source set with ModelSim/Questa. |
| `python -m tools.hardware_build test` | Run SystemVerilog tests. Use repeated `--name` options to select tests. |
| `python -m tools.hardware_build check` | Run generated-data checks, core Python suites, and all RTL tests. |
| `python -m tools.hardware_build profile` | Profile the standard named position suite and print aggregate results. |
| `python -m tools.hardware_build profile-position --fen "..."` | Profile one position and print its detailed results; see [engine-profiling.md](engine-profiling.md). |
| `python -m tools.hardware_build synth --target <target>` | Synthesize a configured target. |
| `python -m tools.hardware_build flash --target quartus-de1-soc` | Program a volatile Quartus image through JTAG. |
| `python -m tools.hardware_build synth-report` | Summarize the selected or most recent synthesis result. |
| `python -m tools.hardware_build timing-paths --target quartus-de1-soc` | Report the worst or tightest setup paths from an existing Quartus fit. |

Test and check commands accept `--jobs <count>` and an RTL `--timeout <seconds>`. `check --tuning` includes the optional tuning tests when `requirements-tuning.txt` is installed.

Synthesis verifies generated data before invoking the vendor flow. Common options include `--clean`, `--stream-logs`, `--jobs <count>`, and `--update-generated-data`. Results and timing metadata are stored beside the vendor reports for `synth-report`.

The DE1-SoC profile runs the engine at 75 MHz with one search thread and a 32-ply stack. Synthesis generates its Quartus project under `work/build/quartus-de1-soc/` and derives the PLL and engine constants from the profile. The portable RTL and TT memory protocol remain independent of board-specific clocks, pins, and external-memory wiring.

Generic Vivado targets accept `--part <xilinx-part>`. `vivado-generic` checks the portable design with clock-only constraints, while `vivado-nnue` isolates the NNUE evaluator for resource and timing checks.

## Adding Tests or Targets

To add an RTL test, add or reuse the smallest complete source set, register the testbench and top module in the manifest, and run it by name. Python tests belong under the matching subsystem directory in `tests/`.

Testbenches should use deterministic directed scenarios tied to a documented module contract, drive synchronous inputs away from the DUT sampling edge, and keep setup traffic distinct from behavioral assertions. Repeated observations of one invariant should produce one summarized result, while protocol waits must remain covered by a bench-level timeout. Every registered RTL bench prints a positive `Pass Count` and a zero `Fail Count` because the test runner requires both completion markers and rejects benches with no passing checks.

To add a board target, define its source set, top module, constraints, device, and vendor settings in the manifest. Keep vendor-specific IP in target source sets or behind stable wrappers so the portable RTL remains usable by Intel/Altera and Xilinx flows.
