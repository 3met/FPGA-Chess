# Engine Runtime Profiling

`python -m tools.hardware_build profile` runs the named test-position suite under Verilator or ModelSim/Questa and prints aggregate statistics. `python -m tools.hardware_build profile-position` runs one explicitly supplied FEN and prints the detailed statistics for that position. Both commands collect measurements in the testbench rather than synthesizing large instrumentation counters into the FPGA. The default `auto` backend prefers Verilator when available.

## Simulated Hardware

The profiling testbench instantiates the vendor-neutral engine and the production external-TT path, including its cache, clock-domain bridge, and DE1 SDR SDRAM controller. A sparse simulator memory model supplies the SDRAM contents. UART, PLL, displays, and the board wrapper are outside the profiling boundary.

## Usage

```text
python -m tools.hardware_build profile
python -m tools.hardware_build profile --time-ms 100 --jobs 8
python -m tools.hardware_build profile --nodes 10000 --threads 4 --stack-depth 32
python -m tools.hardware_build profile --target quartus-de1-soc
python -m tools.hardware_build profile --simulator modelsim --depth 3
python -m tools.hardware_build profile-position --fen "r3k2r/8/8/8/8/8/8/R3K2R w KQkq - 0 1" --depth 4
python -m tools.hardware_build profile-position --fen "rnbqkbnr/pppppppp/8/8/8/8/PPPPPPPP/RNBQKBNR w KQkq - 0 1" --time-ms 100 --event-trace --waveform
```

At most one of `--depth`, `--nodes`, or `--time-ms` selects the search limit; omitting all three uses 50 ms. The suite applies the same limit and hardware configuration to every position in `PROFILE_POSITIONS` from `software/benchmarks/positions.py`. `--target` selects the synthesis target whose engine profile is resolved and defaults to `quartus-de1-soc`; synthesis and profiling use the same resolver and RTL-parameter mapping. `--engine-config` explicitly replaces the target's engine profile, while `--threads`, `--stack-depth`, and `--engine-clock-hz` override structural values for experiments. Reports embed the synthesis target, resolved profile, and digest, and the digest participates in simulator build caching. The Verilator cache automatically retains the ten most recently used completed executables and removes generated compilation intermediates after linking. Independent Verilator simulations run concurrently: `--jobs` sets their count, while the default uses the CPUs available to the process divided by `--simulator-threads`. Since this design partitions poorly inside Verilator, the default of one simulator thread and multiple position processes normally gives the best throughput. ModelSim defaults to one job to avoid assuming multiple simulator licenses, but accepts an explicit `--jobs` value. Use `--output` to choose the artifact directory, `--timeout` to opt into a per-position simulator wall-time limit, and `--force-rebuild` to bypass the simulator build cache. Simulations have no wall-time limit when `--timeout` is omitted.

Event traces and waveforms are optional because they can be large and slow simulation. `--simulator verilator` and `--simulator modelsim` select a backend explicitly; the two backends must produce the same engine result and measurement events even if clock-edge scheduling assigns an occasional sample to an adjacent internal state.

## Artifacts and Measurements

Single-position runs write a text report, JSON report, tab-separated metrics, encoded board data, and simulator logs under `work/build/profile/<timestamp>/` by default. Suite runs print and save a detailed aggregate report with the same measurement sections, write aggregate JSON at that root, and save each position's detailed artifacts under `positions/<name>/`. Detailed per-position reports are not printed. Optional event traces and waveforms are stored with each position's artifacts.

Search measurements begin when the controller accepts the search request and end when it presents the response. Setup, response serialization, and post-search TT-store drain are labeled separately. Per-thread phase totals and other exclusive state totals are checked against the measured window so instrumentation drift fails loudly.

The reports cover search throughput and node growth, pipeline issues and stalls, thread lifecycle, move ordering, PVS/LMR activity, RFP cutoff counts, qsearch delta-pruned move counts, TT and cache behavior, clock-domain backpressure, SDRAM traffic and row locality, and simulator speed. Per-depth data is attributed to the primary thread's target depth; helper threads may be searching another depth during the same interval. Quiescence continuations can make the maximum reached ply exceed the nominal iteration depth.

Profiler counters are 64-bit testbench state and do not exist in synthesis builds. The smaller optional `ENABLE_SEARCH_STATS` counters remain the hardware-visible diagnostic interface.

## Interpretation

Thread phases describe why a thread cannot advance. Interface stall categories may overlap unless the report labels them exclusive, so overlapping percentages should not be added. TT ordering hits are valid entries that supply a move but cannot return a score because their depth or bound is insufficient.

SDRAM payload bandwidth reports transferred 16-bit TT data over simulated search and drain time, not the device's theoretical bus rate. Row hits, misses, and conflicts describe the controller's open-row state when a backend request is accepted.

The profiler does not enforce a particular best move, score, or node count. It fails for invalid input, simulator errors, timeouts, incomplete output, engine or memory faults, and broken measurement invariants.
