# Documentation

These docs specify the intended final design of the FPGA chess engine and its supporting software. Documents under `architecture/`, `modules/`, and `protocols/` are normative: they describe the design regardless of whether every part is complete in the current implementation. Progress, experiments, alternatives, measurements, and open questions belong under `development/`.

Implementation details are documented only when they establish a contract, explain a non-obvious invariant, or materially constrain another subsystem. Source code and tests remain authoritative for incidental signal names, state-machine encoding, test coverage, and target-specific measurements.

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
| [modules/nnue-evaluator.md](modules/nnue-evaluator.md)                                                                                                                                                                 | Incremental NNUE update and evaluation architecture.                   |
| [modules/transposition-table.md](modules/transposition-table.md)                                                                                                                                                       | TT lookup, store, entry, score, and replacement semantics.             |
| [modules/search-controller.md](modules/search-controller.md)                                                                                                                                                           | Search orchestration and shared-pipeline scheduling.                   |
| [modules/repetition-checker.md](modules/repetition-checker.md)                                                                                                                                                         | Threefold-repetition history and lookup contract.                      |
| [modules/tt-memory.md](modules/tt-memory.md)                                                                                                                                                                           | TT storage backends, external-memory protocol, cache, and clock crossing. |
| [modules/sdr-sdram-controller.md](modules/sdr-sdram-controller.md)                                                                                                                                                     | Vendor-neutral JEDEC SDR SDRAM controller contract.                    |
| [modules/engine.md](modules/engine.md), [modules/rx-decode.md](modules/rx-decode.md), [modules/tx-encode.md](modules/tx-encode.md), [modules/timer.md](modules/timer.md), and [modules/de1-soc.md](modules/de1-soc.md) | Top-level command, byte-stream, timing, and board-wrapper interfaces.  |

## Directories

| Directory                      | Contents                                                                       |
| ------------------------------ | ------------------------------------------------------------------------------ |
| [architecture/](architecture/) | System architecture, shared data model, search, evaluation, and time management. |
| [modules/](modules/)           | Subsystem interfaces, behavior, ownership, and invariants.                     |
| [protocols/](protocols/)       | Binary encoding and laptop-FPGA communication.                                 |
| [development/](development/)   | Workflows, implementation status, experiments, open questions, and measurements. |

## Development Docs

| Document | Purpose |
| -------- | ------- |
| [development/build-test-synthesis.md](development/build-test-synthesis.md) | Unified Python CLI, manifests, simulator tests, generated-data checks, and synthesis flows. |
| [development/notes.md](development/notes.md) | Open questions, speculative ideas, and low-commitment design notes. |
| [development/testing-metrics.md](development/testing-metrics.md) | Metrics worth tracking for correctness, performance, and hardware utilization. |
| [development/engine-profiling.md](development/engine-profiling.md) | Cycle-accurate engine-only runtime profiling, metrics, and report artifacts. |
| [development/evaluation-tuning.md](development/evaluation-tuning.md) | PyTorch material/PST tuning commands, configuration, and artifacts. |
