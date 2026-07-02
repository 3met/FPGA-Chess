# Engine Testing Metrics

These metrics measure correctness, search quality, and hardware utilization.

| Metric | Purpose |
| ------ | ------- |
| Cycles per engine state | Find FSM stalls and unexpected waits. |
| Pipeline utilization | Measure accepted requests per cycle for board update, move generation, static evaluation, TT lookup, and TT store. |
| Cycles per node | Compare search throughput across builds. |
| Nodes per second | Compare host-visible engine speed. |
| Effective branching factor | Measure move ordering and pruning quality. |
| TT hit rate | Measure transposition-table effectiveness. |
| TT lookup/store stalls | Measure external-memory pressure. |
| Search end reason distribution | Confirm time, depth, node, kill, and error endings behave as expected. |
| Perft correctness | Validate legal move generation and board update/reverse behavior. |
