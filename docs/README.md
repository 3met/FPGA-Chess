# Documentation

These docs are organized around current implementation contracts. Start with the architecture docs, then module specs, then protocols.

## Reading Order

| Order | Document | Purpose |
| ----- | -------- | ------- |
| 1 | [architecture/current-architecture.md](architecture/current-architecture.md) | Current internal architecture and state ownership. |
| 2 | [architecture/data-model.md](architecture/data-model.md) | Shared internal datatypes and constants. |
| 3 | [modules/board-controller.md](modules/board-controller.md) | Board-state update pipeline. |
| 4 | [modules/move-generator.md](modules/move-generator.md) | Move generation interface and behavior. |
| 5 | [modules/static-evaluator.md](modules/static-evaluator.md) | Static evaluation interface and latency. |
| 6 | [modules/search-controller.md](modules/search-controller.md) | Search orchestration. |

## Directories

| Directory | Contents |
| --------- | -------- |
| [architecture/](architecture/) | Current design, data model, search, evaluation, and time-management notes. |
| [modules/](modules/) | Per-module contracts. |
| [protocols/](protocols/) | Binary encoding and laptop-FPGA communication. |
| [development/](development/) | Roadmap, metrics, and working notes. |
