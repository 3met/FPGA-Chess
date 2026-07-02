# Documentation

These docs describe the intended final RTL architecture unless a section explicitly says otherwise. Some modules are planned specs and may not exist in RTL yet; keep those specs because they define the target integration contract.

## Documentation Status

| Status | Meaning |
| ------ | ------- |
| Final design | Target behavior for the completed RTL. |
| Planned | Required design that may not be implemented yet. |
| Current RTL note | Temporary implementation detail or mismatch worth preserving during development. |
| Open design item | Decision still intentionally unsettled. |

## Reading Order

| Order | Document | Purpose |
| ----- | -------- | ------- |
| 1 | [architecture/chip-design.md](architecture/chip-design.md) | High-level chip architecture and state ownership. |
| 2 | [architecture/data-model.md](architecture/data-model.md) | Shared internal datatypes and constants. |
| 3 | [protocols/binary-encoding.md](protocols/binary-encoding.md) | Common byte and bit encodings used between host and FPGA. |
| 4 | [protocols/laptop-fpga-communication.md](protocols/laptop-fpga-communication.md) | Host-to-FPGA command and response protocol. |
| 5 | [modules/board-controller.md](modules/board-controller.md) | Board-state update pipeline. |
| 6 | [modules/move-generator.md](modules/move-generator.md) | Move generation interface and behavior. |
| 7 | [modules/static-evaluator.md](modules/static-evaluator.md) | Static evaluation interface and latency. |
| 8 | [modules/load-tt.md](modules/load-tt.md) and [modules/store-tt.md](modules/store-tt.md) | Required transposition-table access pipelines. |
| 9 | [modules/search-controller.md](modules/search-controller.md) | Search orchestration. |
| 10 | [modules/engine.md](modules/engine.md), [modules/rx-decode.md](modules/rx-decode.md), and [modules/tx-encode.md](modules/tx-encode.md) | Top-level command and byte-stream interfaces. |

## Directories

| Directory | Contents |
| --------- | -------- |
| [architecture/](architecture/) | Chip design, data model, search, evaluation, and time-management notes. |
| [modules/](modules/) | Per-module target contracts, including planned modules. |
| [protocols/](protocols/) | Binary encoding and laptop-FPGA communication. |
| [development/](development/) | Roadmap, open questions, metrics, and speculative design notes. |
