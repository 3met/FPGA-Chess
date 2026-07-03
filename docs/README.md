# Documentation

These docs describe the intended final RTL architecture unless a section explicitly says otherwise. Some modules are planned and may not exist in RTL yet; keep those specs because they define target integration contracts.

## Documentation Status

| Status | Meaning |
| ------ | ------- |
| Final design | Target behavior for the completed RTL. |
| Planned | Required design that may not be implemented yet. |
| Current RTL note | Temporary implementation detail or mismatch to preserve during development. |
| Open design item | Decision still intentionally unsettled. |

## Reading Order

| Order | Document | Purpose |
| ----- | -------- | ------- |
| 1 | [architecture/chip-design.md](architecture/chip-design.md) | High-level chip architecture and state ownership. |
| 2 | [architecture/data-model.md](architecture/data-model.md) | Shared internal datatypes and constants. |
| 3 | [protocols/binary-encoding.md](protocols/binary-encoding.md) | Common byte and bit encodings used between host and FPGA. |
| 4 | [protocols/laptop-fpga-communication.md](protocols/laptop-fpga-communication.md) | Host-to-FPGA command and response protocol. |
| 5 | [architecture/evaluation-design.md](architecture/evaluation-design.md) and [architecture/search-design.md](architecture/search-design.md) | Evaluation and search conventions. |
| 6 | [architecture/time-management.md](architecture/time-management.md) | Search time-control policy. |
| 7 | [modules/board-update-pipeline.md](modules/board-update-pipeline.md) | Board-state update pipeline. |
| 8 | [modules/move-generator.md](modules/move-generator.md) | Move generation interface and behavior. |
| 9 | [modules/static-evaluator.md](modules/static-evaluator.md) | Static evaluation interface and latency. |
| 10 | [modules/tt-lookup.md](modules/tt-lookup.md) and [modules/tt-store.md](modules/tt-store.md) | Required transposition-table access pipelines. |
| 11 | [modules/search-controller.md](modules/search-controller.md) | Search orchestration. |
| 12 | [modules/engine.md](modules/engine.md), [modules/rx-decode.md](modules/rx-decode.md), [modules/tx-encode.md](modules/tx-encode.md), [modules/timer.md](modules/timer.md), and [modules/main.md](modules/main.md) | Top-level command, byte-stream, timing, and board-wrapper interfaces. |

## Directories

| Directory | Contents |
| --------- | -------- |
| [architecture/](architecture/) | Chip design, data model, search, evaluation, and time-management notes. |
| [modules/](modules/) | Per-module target contracts, including planned modules. |
| [protocols/](protocols/) | Binary encoding and laptop-FPGA communication. |
| [development/](development/) | Roadmap, open questions, metrics, and speculative design notes. |

## Development Workflows

| Document | Purpose |
| -------- | ------- |
| [development/build-test-synthesis.md](development/build-test-synthesis.md) | Unified Python CLI, manifests, simulator tests, generated data checks, and synthesis flows. |
