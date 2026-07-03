# Roadmap

This roadmap tracks documentation-level design work and implementation milestones. Status values should be `not started`, `in progress`, `blocked`, or `done`.

| Task                                   | Description                                                                                     | Status      | Notes                                                                           |
| -------------------------------------- | ----------------------------------------------------------------------------------------------- | ----------- | ------------------------------------------------------------------------------- |
| Normalize evaluation convention        | Make raw evaluation and PST/material state White-relative, with search-boundary POV conversion. | done | Board update pipeline and static evaluator docs now use White-relative state.    |
| Complete board update pipeline hashing | Implement full incremental Zobrist update logic.                                                | done | Board update pipeline maintains 64-bit tile, turn, castling, and en passant key components. |
| Implement RX/TX FIFOs                  | Add buffered stream wrappers around UART receive/transmit.                                      | done | RX/TX use parameterized CDC FIFOs with 1024-word default depth and 2 Mbps UART defaults. |
| Implement engine FSM                   | Parse command payloads and stream fixed-size responses.                                         | done | V1 protocol FSM is implemented with typed search-controller request/response boundary and deterministic placeholder search integration. |
| Implement search controller            | Add alpha/beta search, per-thread stacks, and pipeline scheduling.                              | not started | Planned module only; a minimal stub exists only to terminate the engine V1 boundary. |
| Implement TT pipelines                 | Add required TT lookup/store pipelines and external-memory integration.                         | in progress | First portable load/store slice is implemented; external-memory wrapper, BRAM cache, and 128-bit profile remain planned. |
| Python UCI host                        | Parse UCI, validate legal commands, serialize FPGA protocol, and log activity.                  | not started | Host owns legality for incoming UCI commands.                                   |
| Move-generator legality tests          | Add complex move-generation tests for pins, checks, castling, en passant, and promotion.        | done | Regression bench covers pins, checks, castling, en passant, promotion ordering, qsearch filtering, targeted generation, and no-legal-move positions. |
