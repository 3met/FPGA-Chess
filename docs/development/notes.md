# Miscellaneous Notes

These notes contain open questions, speculative ideas, and implementation reminders. They are not final RTL requirements unless promoted into architecture, protocol, or module docs.

## Open Questions

- Check whether the `BOARD_RANK` lookup table should be fixed or removed, because `getRank(pos)` already follows the documented `a1 = 0` convention.
- Decide external-memory banking, cache structure, and physical packing for compact 96-bit TT entries.
- Decide exact 7-segment display/debug behavior for the board wrapper.

## Functionality to Test

- Castling, including blocked path, check on origin, transit-square attack, and destination-square attack.
- En passant, including discovered-check rejection.
- Check, double check, checkmate, and stalemate.
- Promotion and underpromotion ordering.
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
