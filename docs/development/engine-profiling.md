# Engine Runtime Profiling

Use the profiler to measure search throughput, pipeline stalls, and transposition-table (TT) behavior in cycle-accurate simulation. Run commands from the repository root with Python 3.10 or newer and either Verilator or ModelSim/Questa on `PATH`. No FPGA is required.

## Run a Profile

Profile the standard position suite and save a baseline:

```text
python -m tools.hardware_build profile --name baseline
```

Profile a single position:

```text
python -m tools.hardware_build profile-position --name castling --fen "r3k2r/8/8/8/8/8/8/R3K2R w KQkq - 0 1" --depth 8
```

Both commands print a summary and save the full measurements. Suite positions and their names are defined in [`profile_positions.py`](../../tools/hardware_build/profile_positions.py).

| Option | Use |
| ------ | --- |
| `--depth <plies>` | Search to a fixed depth, smaller than the configured stack depth. |
| `--nodes <count>` | Search with a node limit. |
| `--time-ms <milliseconds>` | Set the simulated search-time limit. This is the default limit type. |
| `--target <target>` | Use a synthesis target's engine profile; defaults to `quartus-de1-soc`. |
| `--engine-config <path>` | Use another engine profile. |
| `--threads <count>`, `--stack-depth <plies>`, `--engine-clock-hz <Hz>` | Override the corresponding hardware settings for this run. |
| `--simulator auto\|verilator\|modelsim` | Select the simulator; `auto` prefers Verilator. |
| `--jobs <count>` | Run suite positions concurrently; applies to `profile` only. |
| `--simulator-threads <count>` | Set Verilator execution threads within each position simulation. |
| `--timeout <seconds>` | Limit simulator wall time per position; disabled by default. |
| `--force-rebuild` | Rebuild the cached simulator. |
| `--event-trace`, `--waveform` | Save event traces or complete waveforms for debugging. |

Choose at most one of `--depth`, `--nodes`, and `--time-ms`. Simulated search time and simulator wall time are separate: a short search can take much longer to simulate.

For example, compare a baseline with a longer search while limiting concurrent simulations:

```text
python -m tools.hardware_build profile --name longer-search --time-ms 100 --jobs 4
```

`--threads` changes the simulated engine. `--jobs` and `--simulator-threads` control host CPU usage. Suite concurrency defaults to available CPUs for Verilator, accounting for simulator threads, and one position for ModelSim. Keep the default single Verilator execution thread unless measurements show an improvement; this design partitions poorly across simulator threads.

Simulator builds are cached. The first Verilator run can include compiler optimization training before the final build; those training searches are excluded from the report. Omit traces and waveforms when measuring simulation speed.

## View Saved Results

```text
python -m tools.hardware_build profile-view baseline
python -m tools.hardware_build profile-view baseline --topic search moves
python -m tools.hardware_build profile-view baseline --topic tt --position undermining
python -m tools.hardware_build profile-view baseline --topic all
python -m tools.hardware_build profile-view --list-runs
```

`profile-view` reads saved results without running a simulator. With no run name, it selects the latest completed run. With no topic, it shows `summary`. Topics may be combined or supplied through repeated `--topic` options. Use `--list-topics` to list them. `--position` selects one suite position; omit it for aggregate results.

| Topic | Contents |
| ----- | -------- |
| `summary` | Search throughput, results, depths, faults, simulated search time, and total profiling wall time. |
| `search` | Per-depth results and subsections for PVS, LMR, reverse and ordinary futility pruning, null moves, quiescence, TT cutoffs, terminal positions, and draws. |
| `moves` | Move generation counts, latency, and efficiency; ordering bucket activity, occupancy, searched move ranks, and beta cutoffs. |
| `pipeline` | Thread lifecycle and separate board-update, move-generation, NNUE, repetition, and TT/memory pipeline sections. |
| `tt` | Probes, cache behavior, request latency, FIFO occupancy, backpressure, and SDRAM traffic. |
| `simulation` | Simulator speed and time spent on setup, search, response serialization, and drain. |

## Files and Run Names

Named runs live under `work/build/profile/<name>/`; unnamed runs receive a timestamp. A name must start with a letter or digit and contain only letters, digits, dots, underscores, or hyphens. Trailing dots and reserved names, including `compile` and Windows device names, are rejected.

| Path within a run | Contents |
| ----------------- | -------- |
| `report.json` | Complete measurements. |
| `reports/<topic>.txt` | Text reports for each topic. |
| `run.json` | Completion metadata. |
| `positions/<position-name>/` | Per-position reports and logs for suite runs. |

Simulator logs and requested traces or waveforms are saved with the reports. Waveforms use FST for Verilator and WLF for ModelSim. The viewer generates its text from `report.json`.

Existing run directories are rejected. To rerun a baseline, use `--name baseline --replace`; this deletes its previous reports, logs, traces, and waveforms. Interrupted runs can be replaced too, but cannot be viewed or selected as completed runs.

Use `--output <directory>` instead of `--name` to choose another location, then view it with `profile-view --run <directory>`. `--replace` requires an explicit name or output directory and only replaces directories created by the profiler.

## Read the Measurements

The simulated design includes the portable engine and production external-TT path: cache, clock-domain bridge, and SDR SDRAM controller. Engine and memory clocks come from the selected profile. The SDRAM model checks timing and returned data and models memory and IO delays. UART, PLL, displays, and the board wrapper are outside the measurement boundary. Instrumentation runs in the testbench.

For comparisons, use the same positions and search limit and record any engine-profile overrides. Engine throughput measures simulated hardware performance; simulator speed measures how fast the host runs that simulation. Total profiling wall time includes configuration, simulator preparation, and all position simulations. Search timing runs from request acceptance to response presentation; setup, serialization, and TT-store drain are reported separately.

### Search and Pipeline

The board-update section separates real candidate pushes, synthetic null pushes, and reversals. Legal and illegal counts classify completed real candidates before later pruning or TT validation decisions; they are not node counts. Unfinished candidates are reported separately. Counts measure attempts across threads and repeated searches, rather than distinct moves. Illegal candidates, synthetic nulls, and reversals do not count as search nodes.

Illegal causes are exclusive: a checked parent is classified as failure to escape check, including rejected king moves; otherwise a rejected king move is a move into check, a rejected en passant capture exposes the king, and any other rejected move exposes the king by moving a pinned piece. Cause percentages use all illegal candidates; the overall rejection percentage uses completed real candidates. These counters are collected during simulation and require a new profile run to measure existing workloads.

Each pipeline section groups its request activity, available completion measurements, and backpressure. Activity percentages use search cycles; memory backpressure includes post-search drain as labeled. Detailed move-generation work remains in `moves`, and cache, latency, queues, and SDRAM measurements remain in `tt`.

PVS scout and re-search counters measure issued real main-search move pushes, excluding quiescence and null moves. They include speculative attempts that may later fail legality checks.

Search heuristic counters include null-move probes issued and null returns that cause a beta cutoff. Missing counters are shown as unrecorded rather than zero.

Per-depth measurements follow the primary thread; helpers may be searching another depth. Thread lifecycle phases partition the search duration. Indented rows partition their parent phase but still express percentages of the full search duration, so do not add them to parent totals. Control and dispatch include initialization, transitions, and request waits. Stall categories can overlap unless labeled exclusive.

### TT and Memory

| Measurement | Meaning |
| ----------- | ------- |
| Cache hit | Both the cache tag and a position way match. An ordering hit supplies a move but cannot supply a usable score. |
| Cache wait | Engine cycles from frontend acceptance to the cache-bank read, including staging, queuing, and arbitration. Excludes cache-result and external-memory latency. |
| Cache operation idle | Cycles without the named read or write operation on either bank. Another operation may still use the shared port. |
| Probe latency | Time from frontend acceptance to response, including an early response before the remaining memory words drain. |
| Store latency | Time from frontend acceptance to SDRAM write acknowledgement, or to the decision that no replacement is needed. Cache-hit stores write through to SDRAM. |
| FIFO occupancy | Entries or memory words queued, sampled before transfers on the producer clock. Includes empty search cycles; excludes setup and drain. CDC counts use actual pointers. |
| Controller idle | Memory cycles in the idle state without a pending request. Timing waits, refresh, and completion count as busy. |
| Data-bus idle | Memory cycles without read or write payload. |
| Payload bandwidth | Delivered read/write bytes divided by sampled memory time, including idle time and controller overhead. |
| Row hit/miss/conflict | SDRAM open-row state when a request is accepted, independent of TT cache hits. The closed-row policy produces misses. |
| Writebacks queued alongside probe reads | Search cycles with both queues nonempty and the TT frontend idle. Measures queue overlap. |

Cache accesses, waits, request latency, and SDRAM traffic include search and post-search drain. Dropped and unfinished requests are reported separately and excluded from completion-latency and wait averages. Empty latency groups have undefined statistics.

Suite counts add across positions. Ratios, averages, and percentiles use pooled counts or histograms; maxima remain maxima. Percentiles use nearest rank. Do not average per-position hit rates or percentiles to reproduce suite results.

Profiling fails on invalid input, simulator errors, timeouts, incomplete output, engine or memory faults, and measurement-invariant failures. It does not assert a particular best move, score, or node count; use [the test workflow](build-test-synthesis.md) for correctness checks.
