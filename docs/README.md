# Documentation

These docs describe the intended RTL architecture unless a section explicitly says otherwise. Some modules are still planned or partially implemented, so those docs should be treated as interface contracts rather than as a claim that the RTL already matches them.

## Status Labels

| Label | Meaning |
| ----- | ------- |
| Final design | Intended completed behavior. |
| Planned | Required design that may not exist in RTL yet. |
| Current RTL note | Important implementation detail or temporary mismatch in today's RTL. |
| Open design item | Intentionally unsettled decision. |

## Reading Order

| Order | Document | Purpose |
| ----- | -------- | ------- |
| 1 | [architecture/chip-design.md](architecture/chip-design.md) | High-level chip architecture, block boundaries, and state ownership. |
| 2 | [architecture/data-model.md](architecture/data-model.md) | Shared datatypes, constants, and encoding assumptions used across RTL. |
| 3 | [protocols/binary-encoding.md](protocols/binary-encoding.md) | Common byte and bit encodings used between host and FPGA. |
| 4 | [protocols/laptop-fpga-communication.md](protocols/laptop-fpga-communication.md) | Host-to-FPGA command and response protocol. |
| 5 | [architecture/evaluation-design.md](architecture/evaluation-design.md) and [architecture/search-design.md](architecture/search-design.md) | Evaluation and search conventions. |
| 6 | [architecture/time-management.md](architecture/time-management.md) | Search time-control policy. |
| 7 | [modules/board-update-pipeline.md](modules/board-update-pipeline.md) | Board-state update pipeline contract. |
| 8 | [modules/move-generator.md](modules/move-generator.md) | Move-generation interface, ordering, and legality behavior. |
| 9 | [modules/static-evaluator.md](modules/static-evaluator.md) | Static-evaluation interface and latency. |
| 10 | [modules/tt-lookup.md](modules/tt-lookup.md) and [modules/tt-store.md](modules/tt-store.md) | Transposition-table lookup and store pipelines. |
| 11 | [modules/search-controller.md](modules/search-controller.md) | Search orchestration and shared-pipeline scheduling. |
| 12 | [modules/engine.md](modules/engine.md), [modules/rx-decode.md](modules/rx-decode.md), [modules/tx-encode.md](modules/tx-encode.md), [modules/timer.md](modules/timer.md), and [modules/de1-soc.md](modules/de1-soc.md) | Top-level command, byte-stream, timing, and board-wrapper interfaces. |

## Directories

| Directory | Contents |
| --------- | -------- |
| [architecture/](architecture/) | Chip design, shared data model, search, evaluation, and time-management notes. |
| [modules/](modules/) | Per-module contracts and current RTL notes. |
| [protocols/](protocols/) | Binary encoding and laptop-FPGA communication. |
| [development/](development/) | Build/test flow, open questions, metrics, and active documentation TODOs. |

## Development Docs

| Document | Purpose |
| -------- | ------- |
| [development/build-test-synthesis.md](development/build-test-synthesis.md) | Unified Python CLI, manifests, simulator tests, generated-data checks, and synthesis flows. |
| [development/notes.md](development/notes.md) | Open questions, speculative ideas, and low-commitment design notes. |
| [development/pending-changes.md](development/pending-changes.md) | Small documentation backlog for issues not yet folded into the main specs. |
| [development/testing-metrics.md](development/testing-metrics.md) | Metrics worth tracking for correctness, performance, and hardware utilization. |
