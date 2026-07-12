# Documentation

These docs describe the RTL architecture.

## Key Documents

| Document                                                                                                                                                                                                               | Purpose                                                                |
| ---------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- | ---------------------------------------------------------------------- |
| [architecture/chip-design.md](architecture/chip-design.md)                                                                                                                                                             | High-level chip architecture, block boundaries, and state ownership.   |
| [architecture/data-model.md](architecture/data-model.md)                                                                                                                                                               | Shared datatypes, constants, and encoding assumptions used across RTL. |
| [protocols/binary-encoding.md](protocols/binary-encoding.md)                                                                                                                                                           | Common byte and bit encodings used between host and FPGA.              |
| [protocols/laptop-fpga-communication.md](protocols/laptop-fpga-communication.md)                                                                                                                                       | Host-to-FPGA command and response protocol.                            |
| [architecture/evaluation-design.md](architecture/evaluation-design.md) and [architecture/search-design.md](architecture/search-design.md)                                                                              | Evaluation and search conventions.                                     |
| [architecture/time-management.md](architecture/time-management.md)                                                                                                                                                     | Search time-control policy.                                            |
| [modules/board-update-pipeline.md](modules/board-update-pipeline.md)                                                                                                                                                   | Board-state update pipeline contract.                                  |
| [modules/move-generator.md](modules/move-generator.md)                                                                                                                                                                 | Move-generation interface, ordering, and legality behavior.            |
| [modules/static-evaluator.md](modules/static-evaluator.md)                                                                                                                                                             | Static-evaluation interface and latency.                               |
| [modules/tt-lookup.md](modules/tt-lookup.md) and [modules/tt-store.md](modules/tt-store.md)                                                                                                                            | Transposition-table lookup and store pipelines.                        |
| [modules/search-controller.md](modules/search-controller.md)                                                                                                                                                           | Search orchestration and shared-pipeline scheduling.                   |
| [modules/engine.md](modules/engine.md), [modules/rx-decode.md](modules/rx-decode.md), [modules/tx-encode.md](modules/tx-encode.md), [modules/timer.md](modules/timer.md), and [modules/de1-soc.md](modules/de1-soc.md) | Top-level command, byte-stream, timing, and board-wrapper interfaces.  |

## Directories

| Directory                      | Contents                                                                       |
| ------------------------------ | ------------------------------------------------------------------------------ |
| [architecture/](architecture/) | Chip design, shared data model, search, evaluation, and time-management notes. |
| [modules/](modules/)           | Per-module design notes.                                                       |
| [protocols/](protocols/)       | Binary encoding and laptop-FPGA communication.                                 |
| [development/](development/)   | Build/test flow, open questions, metrics, and active documentation TODOs.      |

## Development Docs

| Document | Purpose |
| -------- | ------- |
| [development/build-test-synthesis.md](development/build-test-synthesis.md) | Unified Python CLI, manifests, simulator tests, generated-data checks, and synthesis flows. |
| [development/notes.md](development/notes.md) | Open questions, speculative ideas, and low-commitment design notes. |
| [development/pending-changes.md](development/pending-changes.md) | Small documentation backlog for issues not yet folded into the main specs. |
| [development/testing-metrics.md](development/testing-metrics.md) | Metrics worth tracking for correctness, performance, and hardware utilization. |
