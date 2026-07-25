# Engine Runtime Profiling

`python -m tools.hardware_build profile` runs one cycle-accurate, engine-only search under Verilator or ModelSim/Questa and reports runtime measurements that are intentionally too expensive to synthesize into the FPGA. The default `auto` backend prefers Verilator when it is installed.

## Simulated Hardware

The profiling testbench instantiates the vendor-neutral `engine`, production external-TT frontend and 1024-line on-chip cache, asynchronous memory bridge, and production DE1 SDR SDRAM controller. A simulator-only sparse SDRAM chip model supplies the complete 64 MiB address space used by all 5,592,405 TT entries. UART, PLL IP, board displays, and the `de1_soc` wrapper are not simulated.

The SDRAM model starts cleared, so the controller skips its serial power-on validity sweep in this testbench only. Runtime bank, row, CAS, full-page burst, byte-mask, refresh, CDC, and backpressure behavior still passes through the production RTL. The model checks the 200 us startup delay, precharge/refresh/mode sequence, CAS-2 mode word, tRP, tRCD, tRAS, tRC, write recovery, and the 7.8125 us refresh deadline against the IS42S16320D-compatible command stream. Normal simulation and synthesis retain the sweep.

## Commands

```text
python -m tools.hardware_build profile
python -m tools.hardware_build profile --fen "r3k2r/8/8/8/8/8/8/R3K2R w KQkq - 0 1" --depth 4
python -m tools.hardware_build profile --nodes 10000 --threads 4 --stack-depth 32
python -m tools.hardware_build profile --time-ms 100 --event-trace --waveform
python -m tools.hardware_build profile --simulator modelsim --depth 3
```

The default is the normal starting position searched for 50 ms of simulated engine time with the current DE1 configuration: one thread, 24 stack plies, a 35.714286 MHz engine clock, and a 100 MHz SDRAM clock. Exactly one of `--depth`, `--nodes`, or `--time-ms` may select another limit. Use `--output` for a fixed artifact directory, `--timeout` for the simulator wall-clock limit, and `--force-rebuild` to ignore the simulator build cache. `--simulator verilator` or `--simulator modelsim` selects a backend explicitly.

## Artifacts

Each run writes `report.txt`, schema-versioned `report.json`, `metrics.tsv`, the encoded `board.hex`, and simulator logs under `work/build/profile/<timestamp>/` by default. `--event-trace` adds `events.jsonl`, and `--waveform` retains `wave.fst` under Verilator or `wave.wlf` under ModelSim; both can become large and are disabled by default.

Verilator builds an `-O3` and link-time-optimized native executable cached by RTL contents, hardware generics, execution-thread count, waveform setting, and Verilator installation. Compilation uses all available host cores, while execution defaults to one thread: this engine's tightly coupled clock domains do not partition effectively, and an eight-thread test was slower than one thread. `--simulator-threads` permits experimentation on another host or hardware configuration. ModelSim signal logging is disabled unless requested, and `--waveform` will run either backend more slowly.

The backends produce the same search result and measurement events. Because the engine and memory clocks occasionally edge at the same simulator timestamp, their event kernels may attribute one terminal sampling cycle to adjacent SDRAM state bins differently; the total sampled SDRAM cycles remains unchanged.

## Measurement Windows

Search measurements begin when the search controller accepts the search request and end when it presents the response. The report labels cycles outside that window as command/position setup, result serialization, and background TT-store completion. Component issue utilization uses search cycles as its denominator. Per-thread phase counters include the idle phase and must sum to the search-cycle count for every configured thread. TT frontend, CDC, and SDRAM traffic counters include the labeled post-search drain so accepted best-effort stores are not lost from the memory report.

The report includes engine/controller states, per-thread phases and move-order states, ply occupancy, component issues and completions, interface stalls, concurrency, move buckets and ordering distributions, PVS/LMR activity, TT hits and hit use, cache probes, store drops, CDC backpressure, SDRAM traffic, and row locality. Move-generator operation latency is tracked independently per requesting thread from each accepted noisy/direct or quiet request through its corresponding independent response, and from accepted bucket pop through its common pop response. Generator-state totals include both class pipelines. If a time/node limit terminates the search with an operation in flight, its partial observed latency remains in the totals rather than causing a profiler error. Noisy/quiet work statistics count destination squares examined, destinations that produced at least one potential source, candidates successfully emitted into ordering buckets, and cycles per candidate/destination. Promotion choices count as separate emitted candidates. A bucket's `peak queued` value is the largest number of moves simultaneously stored in that ordering bucket. Simulation-speed fields report logical FPGA search time, measured search cycles per wall-second, and slowdown relative to the configured FPGA clock. `n/a` is printed for a rate with no observations.

The per-depth table attributes cycles, newly searched nodes, TT/cache activity, and maximum reached ply to each iterative-deepening target. Its status marks every fully finished iteration as `complete` and any in-progress iteration stopped by a time or node limit as `partial`. Node growth compares the new nodes searched at one target depth with the preceding target. The reported deepest search ply and per-depth maximum ply include tactical continuations entered by quiescence search, so they may exceed the nominal completed depth.

Board-update issues include both speculative candidate pushes and the reversal that restores a parent board after a searched child. Legal move ordinals count only forward candidates accepted as legal; illegal candidates that leave the mover in check and reversal operations are excluded.

Move-order effectiveness reports beta cutoffs by searched legal-move rank and by ordering bucket. A bucket cutoff rate uses popped candidates from that bucket as its denominator; direct TT/PV moves and any move that cannot be matched reliably to a bucket are reported separately as unbucketed.

The existing `ENABLE_SEARCH_STATS` counters are small optional hardware-debug counters exposed through the engine protocol. The profiler also reads internal simulator events and maintains 64-bit testbench counters; these profiler counters do not exist in synthesis builds.

## Interpretation

Thread wait phases describe where a thread cannot progress, while interface stall counters describe a specific ready/valid bottleneck; these categories can overlap and should not be summed as exclusive causes. An SDRAM row hit is classified when the production controller accepts a backend request. TT ordering-only hits include valid hits whose depth or bound cannot immediately return a search score.

The profiler does not assert an expected best move, score, or node count. It fails only for invalid inputs, simulator/tool errors, timeouts, incomplete metric output, engine/memory errors, or broken measurement invariants.
