# Engine Testing Metrics

These metrics are useful for validating correctness, comparing search quality, and tracking hardware utilization over time.

| Metric                         | Purpose                                                                                                            |
| ------------------------------ | ------------------------------------------------------------------------------------------------------------------ |
| Cycles per engine state        | Find FSM stalls and unexpected waits.                                                                              |
| Pipeline utilization           | Measure accepted requests per cycle for board update, move generation, NNUE evaluation, TT lookup, and TT store. |
| Cycles per node                | Compare search throughput across builds.                                                                           |
| Nodes per second               | Compare host-visible engine speed.                                                                                 |
| Effective branching factor     | Measure move ordering and pruning quality.                                                                         |
| TT hit rate                    | Measure transposition-table effectiveness.                                                                         |
| TT lookup/store stalls         | Measure external-memory pressure.                                                                                  |
| Search end reason distribution | Confirm time, depth, node, canceled, and error endings behave as expected.                                         |
| Perft correctness              | Validate legal move generation and board update/reverse behavior.                                                  |

The engine-only runtime profiler described in [engine-profiling.md](engine-profiling.md) measures these search-time behaviors through the production external-memory path without adding synthesized counters.
