# Documentation

These docs describe the FPGA chess engine architecture, module contracts, protocols, usage, and development workflows.

Implementation details are documented only when they establish a contract, explain a non-obvious invariant, or materially constrain another subsystem. Source code and tests remain authoritative for incidental signal names, state-machine encoding, test coverage, and target-specific measurements.

## Structure

| Directory | Contents |
| --------- | -------- |
| [architecture/](architecture/) | System architecture, shared data model, search, evaluation, and time management. |
| [modules/](modules/) | Subsystem interfaces, behavior, ownership, and invariants. |
| [protocols/](protocols/) | Binary encoding and laptop-FPGA communication. |
| [usage/](usage/) | Board wiring, programming, and host setup. |
| [development/](development/) | Build, verification, profiling, and evaluation-tuning workflows. |

## Starting Points

| Topic | Document |
| ----- | -------- |
| System overview | [architecture/chip-design.md](architecture/chip-design.md) |
| Shared RTL types | [architecture/data-model.md](architecture/data-model.md) |
| Search and evaluation | [architecture/search-design.md](architecture/search-design.md) and [architecture/evaluation-design.md](architecture/evaluation-design.md) |
| DE1-SoC and UCI setup | [usage/de1-soc-uci.md](usage/de1-soc-uci.md) |
| Host protocol | [protocols/host-fpga-protocol.md](protocols/host-fpga-protocol.md) and [protocols/binary-encoding.md](protocols/binary-encoding.md) |
| Build and verification | [development/build-test-synthesis.md](development/build-test-synthesis.md) |
| Runtime profiling | [development/engine-profiling.md](development/engine-profiling.md) |
| Evaluation tuning | [development/evaluation-tuning.md](development/evaluation-tuning.md) |
