# Miscellaneous Notes

These notes contain open questions, speculative ideas, and implementation reminders. They are not final RTL requirements unless they are promoted into the architecture, protocol, or module docs.

## Open Questions

- Decide external-memory banking, cache structure, and physical packing for compact 96-bit TT entries.
- Decide exact 7-segment display/debug behavior for the board wrapper.

## Additional Functionality to Test

- Exact repetition-history memory layout for active game state and per-thread search lines.
- TT hit, miss, replacement, and load/store conflict behavior.

## Speculative Evaluation Ideas

- Game-phase interpolation between opening/middlegame/endgame tables.
- Polynomial or cheaper fixed-point interpolation for game phase.
- Pawn chains, connected pawns, isolated pawns, doubled pawns, weak pawns, and holes.
- Attacker/defender counts and center-control bonuses.
- King safety from nearby friendly pawns, nearby enemy pieces, and enemy-controlled surrounding squares.
- Rook on open or half-open file.
- Trapped bishop penalties.
- Increase rook value as pawn count decreases.
- Decrease knight value as pawn count decreases.

## Future Search Ideas

- Principal variation search.
- Quiescence search refinements beyond the required captures-and-promotions baseline, still excluding checking non-captures unless promoted into the search design.
- Root move diversity between Lazy SMP threads.

## Error Detection Ideas

- Log unknown opcodes.
- Log FIFO overflow.
- Distinguish UART framing errors from protocol errors.
- Add optional host-side protocol tracing around every FPGA command and response.

## Current RTL Notes

The current `static_evaluator` RTL adds V1 positional terms to the board update pipeline's White-relative incremental material plus PST state.
