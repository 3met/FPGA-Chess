# Roadmap

This roadmap tracks documentation-level design work and implementation milestones. Status values should be `not started`, `in progress`, `blocked`, or `done`.

| Task                                   | Description                                                                                     | Status      | Notes                                                                           |
| -------------------------------------- | ----------------------------------------------------------------------------------------------- | ----------- | ------------------------------------------------------------------------------- |
| Normalize evaluation convention        | Make raw evaluation and PST/material state White-relative, with search-boundary POV conversion. | done | Board update pipeline and static evaluator docs now use White-relative state.    |
| Complete board update pipeline hashing | Implement full incremental Zobrist update logic.                                                | done | Board update pipeline maintains 64-bit tile, turn, castling, and en passant key components. |
| Implement RX/TX FIFOs                  | Add buffered stream wrappers around UART receive/transmit.                                      | not started | Docs use parameterized FIFOs with 1024-word default depth.                      |
| Implement engine FSM                   | Parse command payloads and stream fixed-size responses.                                         | not started | Planned module only.                                                            |
| Implement search controller            | Add alpha/beta search, per-thread stacks, and pipeline scheduling.                              | not started | Planned module only.                                                            |
| Implement TT pipelines                 | Add required TT lookup/store pipelines and external-memory integration.                         | not started | Default logical entry is compact 96 bits; 128-bit full-key profile is optional. |
| Python UCI host                        | Parse UCI, validate legal commands, serialize FPGA protocol, and log activity.                  | not started | Host owns legality for incoming UCI commands.                                   |
| Move-generator legality tests          | Add complex move-generation tests for pins, checks, castling, en passant, and promotion.        | not started | Needed before search integration.                                               |
