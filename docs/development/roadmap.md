# Roadmap

This roadmap tracks documentation-level design work and implementation milestones. Status values should be `not started`, `in progress`, `blocked`, or `done`.

| Task | Description | Status | Notes |
| ---- | ----------- | ------ | ----- |
| Normalize board indexing docs/RTL | Ensure `a1 = 0` everywhere and fix or remove stale lookup tables. | not started | `BOARD_RANK` appears reversed. |
| Normalize evaluation convention | Make raw evaluation and PST/material state White-relative, with search-boundary POV conversion. | not started | Current board update pipeline PST is active-color-relative. |
| Complete board update pipeline hashing | Implement full incremental Zobrist update logic. | not started | Placeholder constants exist. |
| Implement RX/TX FIFOs | Add buffered stream wrappers around UART receive/transmit. | not started | Docs use parameterized FIFOs with 1024-word default depth. |
| Implement engine FSM | Parse command payloads and stream fixed-size responses. | not started | Planned module only. |
| Implement search controller | Add alpha/beta search, per-thread stacks, and pipeline scheduling. | not started | Planned module only. |
| Implement TT pipelines | Add required TT lookup/store pipelines and external-memory integration. | not started | Default logical entry is compact 96 bits; 128-bit full-key profile is optional. |
| Python UCI host | Parse UCI, validate legal commands, serialize FPGA protocol, and log activity. | not started | Host owns legality for incoming UCI commands. |
| Move-generator legality tests | Add complex move-generation tests for pins, checks, castling, en passant, and promotion. | not started | Needed before search integration. |
