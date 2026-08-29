# Engine Runtime Profiling

`python -m tools.hardware_build profile` runs the named test-position suite under Verilator or ModelSim/Questa and prints aggregate statistics. `python -m tools.hardware_build profile-position` profiles one FEN. Measurements are collected in the testbench rather than synthesized into the FPGA.

## Simulated Hardware

The profiling testbench instantiates the vendor-neutral engine and the production external-TT path, including its cache, clock-domain bridge, and DE1 SDR SDRAM controller. A sparse simulator memory model supplies the SDRAM contents. UART, PLL, displays, and the board wrapper are outside the profiling boundary.

## Usage

```text
python -m tools.hardware_build profile
python -m tools.hardware_build profile --time-ms 100 --jobs 8
python -m tools.hardware_build profile --nodes 10000 --threads 4 --stack-depth 32
python -m tools.hardware_build profile-position --fen "r3k2r/8/8/8/8/8/8/R3K2R w KQkq - 0 1" --depth 4
```

At most one of `--depth`, `--nodes`, or `--time-ms` selects the search limit. `--target` selects the engine profile, while `--engine-config`, `--threads`, `--stack-depth`, and `--engine-clock-hz` override it. `--simulator` selects the backend, `--jobs` controls suite concurrency, and `--output` selects the artifact directory. Use `--event-trace` or `--waveform` only when the additional diagnostic output is needed.

Verilator and ModelSim must produce the same engine result and measurement events, although clock-edge scheduling may attribute an occasional sample to an adjacent internal state.

## Artifacts and Measurements

Reports, machine-readable metrics, simulator logs, and optional traces are written under `work/build/profile/`. Suite runs include an aggregate report and per-position artifacts.

Search measurements begin when the controller accepts the search request and end when it presents the response. Setup, response serialization, and post-search TT-store drain are labeled separately. Per-thread phase totals and other exclusive state totals are checked against the measured window so instrumentation drift fails loudly.

The reports cover search throughput, pipeline stalls, thread activity, move ordering and pruning, TT and cache behavior, SDRAM traffic, and simulator speed. Per-depth data follows the primary thread's target depth; helper threads may be searching another depth during the same interval.

Profiler counters are 64-bit testbench state and do not exist in synthesis builds. The smaller optional `ENABLE_SEARCH_STATS` counters remain the hardware-visible diagnostic interface.

## Interpretation

Thread phases describe why a thread cannot advance. Interface stall categories may overlap unless the report labels them exclusive, so overlapping percentages should not be added. TT ordering hits are valid entries that supply a move but cannot return a score because their depth or bound is insufficient.

SDRAM payload bandwidth reports transferred 16-bit TT data over simulated search and drain time, not the device's theoretical bus rate. Row hits, misses, and conflicts describe the controller's open-row state when a backend request is accepted.

The profiler does not enforce a particular best move, score, or node count. It fails for invalid input, simulator errors, timeouts, incomplete output, engine or memory faults, and broken measurement invariants.
