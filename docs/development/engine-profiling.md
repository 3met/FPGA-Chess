# Engine Runtime Profiling

`python -m tools.hardware_build profile` runs the named test-position suite under Verilator or ModelSim/Questa and prints a short aggregate summary. `python -m tools.hardware_build profile-position` profiles one FEN and prints its summary. Measurements are collected in the testbench rather than synthesized into the FPGA.

## Simulated Hardware

The profiling testbench instantiates the vendor-neutral engine and the production external-TT path, including its cache, clock-domain bridge, and DE1 SDR SDRAM controller. A sparse chip model supplies persistent SDRAM contents, checks command timing, and models SDRAM read access, representative FPGA input delay, and routed forwarded-clock delay. Engine and memory frequencies, phases, and duty cycles come from the selected engine profile, including `--engine-config` overrides. The memory IO clock inherits the memory frequency; its phase is relative to the controller clock before DDR inversion. Every returned memory word is checked against that storage. UART, PLL, displays, and the board wrapper are outside the profiling boundary. Clock periods and duty intervals use a shared picosecond grid; the `profile-clocks` RTL bench checks signed phase wrapping and duty-cycle rounding.

## Usage

```text
python -m tools.hardware_build profile --name baseline
python -m tools.hardware_build profile --name experiment --time-ms 100 --jobs 8
python -m tools.hardware_build profile --nodes 10000 --threads 4 --stack-depth 32
python -m tools.hardware_build profile-position --fen "r3k2r/8/8/8/8/8/8/R3K2R w KQkq - 0 1" --depth 4
```

Use `--name` to save a run under `work/build/profile/<name>/`; unnamed runs receive a timestamped name. Names use letters, digits, underscores, hyphens, and dots and must be valid on Windows and Linux; `compile` is reserved for simulator builds. Existing names are rejected unless `--replace` is supplied. Replacement clears the entire previous run, including logs, traces, and waveforms. Interrupted runs can also be replaced. `--output` selects an explicit artifact directory instead of a name; replacement is allowed only for directories allocated by the profiler. `--replace` requires an explicit name or output directory.

```text
python -m tools.hardware_build profile --name baseline --replace
python -m tools.hardware_build profile-view baseline
python -m tools.hardware_build profile-view baseline --topic tt
python -m tools.hardware_build profile-view --topic search pipeline
python -m tools.hardware_build profile-view baseline --topic tt --position undermining
python -m tools.hardware_build profile-view baseline --topic all
python -m tools.hardware_build profile-view --list-runs
python -m tools.hardware_build profile-view --list-topics
```

`profile-view` reads saved measurements without running a simulator. It defaults to the summary topic and the latest completed run under `work/build/profile/`, and prints the selected run name and path. `--topic` accepts multiple topics and may be repeated. `--position` selects a named suite position; omit it for aggregate results. Runs stored with `--output` can be viewed using `profile-view --run <directory>`. Incomplete runs are excluded from listing and latest-run selection.

| Topic | Measurements |
| ----- | ------------ |
| `summary` | Throughput, results, depths, faults, average simulated search time per position, and overall profiling wall time. Suite position details are shown only for failures. |
| `search` | Per-depth measurements, move generation, ordering, and pruning. |
| `pipeline` | Thread lifecycle, component activity, and stalls. |
| `tt` | TT probes, cache size/access counts/hit rates/wait times/idle time, probe/store latency distributions, FIFO occupancy distributions, memory backpressure, and SDRAM traffic. |
| `simulation` | Simulator speed, elapsed time, setup, serialization, and drain overhead. |

Use at most one of `--depth`, `--nodes`, or `--time-ms` to override the search limit. `--timeout` sets a wall-clock limit per position. `--target` selects the engine profile; `--engine-config`, `--threads`, `--stack-depth`, and `--engine-clock-hz` override it. `--simulator` selects the backend and `--jobs` controls concurrency. Use `--event-trace` or `--waveform` for additional diagnostics.

Verilator simulator builds use host CPU instructions when its configured C++ compiler supports `-march=native`, with a portable fallback otherwise. GCC builds also use profile-guided optimization: an instrumented simulator runs short opening, tactical, and pawn-endgame searches before the final compilation. This adds preparation time on a cache miss; cached runs skip both training and compilation. Training searches do not enter the profiling measurements. The compile cache includes compiler, CPU feature, and training configuration information so a run on another host rebuilds when necessary. These optimizations change simulation wall time without changing simulated clocks or hardware behavior. Independent suite positions can run concurrently with `--jobs`; omit waveforms and event traces when measuring simulation speed.

## Artifacts and Measurements

Each run saves complete measurements in `report.json`, topic reports in `reports/<topic>.txt`, and completion metadata in `run.json`, alongside simulator logs and optional traces. Suites also save the same measurements and topic reports under `positions/<position-name>/`. Topic text is generated from JSON, so viewing results does not depend on the saved text files. Suite ratios use aggregate counts; peak occupancy and maximum latency remain maxima across positions.

Overall profiling wall time includes configuration, simulator preparation or compilation, and the position simulations, measured before final suite-report output. Simulated search time per position is the average across the suite. Search measurements cover request acceptance through response presentation. Setup, response serialization, and post-search TT-store drain are reported separately.

Reports cover search throughput, pipeline stalls, thread activity, move ordering, pruning, TT/cache behavior, SDRAM traffic, and simulator speed. Per-depth data follows the primary thread; helpers may be searching another depth.

Profiler instrumentation is testbench-only. FSM comparisons use shared RTL enum definitions, histogram storage follows enum widths, and state metrics carry enum names rather than numeric encodings. Reports retain newly added states and lifecycle phases automatically; sampled invalid encodings fail profiling. Optional hardware search statistics are a separate diagnostic interface.

## Interpretation

The pipeline lifecycle table shows exclusive top-level phases that sum to the full search duration for each thread. Indented rows partition their parent phase; their percentages also use full search time, so do not add them to the parent totals. Node control and dispatch includes initialization, request acceptance, node/iteration transitions, and waits to submit requests; it is not a measure of productive work alone. Zero-cycle phases are omitted when unused by every thread. Suite tables pool each thread's cycles across positions. Interface stall categories may overlap unless the report labels them exclusive, so overlapping percentages should not be added. TT ordering hits are valid entries that supply a move but cannot return a score because their depth or bound is insufficient.

The TT cache section reports capacity in individual TT ways and two-way sets across both banks, probe/store cache-access counts and hit rates, and average waits in engine cycles and nanoseconds. A hit requires both the cache tag and a matching position way. Cache measurements include search and post-search drain. Waits run from successful frontend acceptance to the cache-bank read, including registered staging, store FIFO queuing, and bank arbitration; they exclude cache-result and external-memory latency. Dropped stores and unfinished accesses do not enter wait averages. Suite rates and waits use pooled access counts and wait-cycle totals.

Cache operation idle percentages count engine cycles with no probe read, probe write, store read, or store write on either bank. Read activity includes initial lookups and idle-slot admission reads. Probe writes admit matching ways from external reads; store writes publish replacements. Each percentage describes that operation rather than overall shared-port availability: another operation may use the same port. Measurements include search and drain, and suite percentages use pooled cycles.

The TT latency section shows average and P99 completion latency for probes and stores, both overall and split by the initial cache hit/miss result. Values are nanoseconds from exact picosecond timestamps during search and post-search drain. Probes run from frontend acceptance to response, including an early matching-way response before the remaining memory words drain. Stores run from frontend acceptance to SDRAM write acknowledgement, including store and writeback queues; a store requiring no replacement completes at that decision. Cache-hit stores still write through to SDRAM. Completed fast-miss probe responses are included even when no external read could be queued. Dropped stores and unfinished requests are excluded and reported separately. Empty groups display undefined statistics. P99 uses nearest rank, and suites pool request histograms before computing means and percentiles.

The TT FIFO table covers the store queue, probe/store metadata queues, and all five CDC FIFOs. Depth is configured storage capacity; average, median, P90, P99, P99.9, and peak describe sampled occupancy in entries or external memory words. Samples include empty cycles during search and exclude setup and post-search drain. Each FIFO is sampled before transfers on its producer clock: response FIFOs use the memory clock and the other queues use the engine clock. CDC occupancy uses the actual read/write pointers, excluding synchronized-pointer delay. Percentiles use nearest rank; peak is the highest sampled occupancy. Suite statistics pool histogram counts across positions rather than averaging position percentiles.

The TT memory-interface section counts accepted SDRAM requests during search and post-search drain, split into probe reads, store reads, and store writes. Bus width is the physical data-bus width. Store writes include stores that hit the cache. Clock frequency is the simulated memory-interface clock; single data rate means one transfer per clock cycle. Controller idle counts cycles in the idle state with no pending backend request; row timing, refresh, and completion are busy. Data-bus idle counts cycles without read or write payload data. Suite request counts add, while bus width and frequency retain the common interface configuration.

Average payload bandwidth is executed read and write data cycles multiplied by bus width in bytes, divided by the sampled memory-domain duration during search and drain. It includes idle time, row timing, refresh, and completion overhead in the denominator; command and address bits are not payload. This measures average delivered data bandwidth rather than the device's theoretical bus rate. Row hits, misses, and conflicts describe the controller's open-row state when a backend request is accepted. The closed-row runtime policy should report misses for every request; these counters describe row state rather than TT cache hits.

Writebacks queued alongside probe reads counts engine cycles during search when both queues are nonempty and the TT frontend is idle. It describes queue overlap, not arbitration decisions or interrupted writes; in-progress memory writes are not preempted.

The profiler does not enforce a particular best move, score, or node count. It fails for invalid input, simulator errors, timeouts, incomplete output, engine or memory faults, and broken measurement invariants.

The final metrics snapshot occurs on the engine clock falling edge after all rising-edge monitors settle. A sampling-window invariant checks that cache-port observations span exactly the recorded search and drain cycles.
