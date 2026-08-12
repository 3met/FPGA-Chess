# Search Design

## Search Model

Each hardware search thread runs an independent iterative-deepening alpha/beta search. Threads use Lazy SMP and cooperate through the transposition table; they do not synchronize at iteration boundaries. The primary thread publishes the engine result, while helper threads contribute TT information without delaying it.

Thread count, stack depth, and optional instrumentation are build parameters. Search uses side-to-move point-of-view scores internally. White-relative material/PST values are negated when Black is to move before the side-to-move-relative NNUE correction is added.

## Search Algorithm

The default search combines iterative deepening, aspiration windows, principal variation search (PVS), null-move pruning, late-move reductions (LMR), transposition-table cutoffs, and quiescence search.

Aspiration failures repeat the same depth with a full window. If a time or node budget expires during an incomplete or failed pass, the engine returns the primary thread's most recent fully completed iteration. A legal root move from a partial first iteration may be used when no completed result exists.

PVS searches the first legal move with the full window and later moves with a scout window, repeating a scout at full window when needed. LMR may first search eligible later moves at reduced depth; an alpha-raising reduced result is verified at full depth before it can affect the parent. The reduction policy is parameterized and computed without changing the search semantics.

Null-move pruning may search a reduced synthetic child at eligible non-root nodes that are not in check. Null children change only turn-dependent state, cannot follow another null move, and do not count as legal moves, update move ordering, enter repetition history, or become best moves.

Quiescence search considers captures and promotions. A checked quiescence node has no stand-pat option and searches all legal evasions; otherwise quiet moves are omitted. Quiescence does not apply PVS, LMR, or null-move pruning to its own moves.

Search nodes are counted when a speculative real move passes king-safety validation and becomes a legal child. The root, null children, and rejected pseudo-legal candidates are not counted. A legal child still counts when repetition, terminal scoring, or a TT cutoff avoids deeper evaluation.

## Thread State and Scheduling

Each thread owns its search stack, current board and incremental state, alpha/beta values, depth and node counters, iterative-deepening result, scheduler phase, and per-pipeline in-flight state. Stack records contain the information required to restore a parent rather than a complete board at every ply.

The controller schedules thread work across board update, move generation, NNUE evaluation, repetition checking, and TT lookup/store. Requests and responses carry routing metadata, allowing completions from different threads and subsystems to overlap safely. The orchestration contract is defined in [search-controller.md](../modules/search-controller.md).

## Move Generation and Legality

The move generator produces ordered pseudo-legal candidates and rejects castling paths that are invalid before the final board can be examined. Ordinary legality is checked after speculative board update by testing whether the moving side left its king in check. An illegal candidate is discarded without changing the accepted thread state.

Host-supplied positions and moves are assumed legal because the host validates UCI input before encoding FPGA commands. Search-generated moves always pass through hardware legality filtering.

## Transposition Table and Repetition

The TT shares results between Lazy SMP threads and provides move-ordering hints. Lookup, score, and replacement rules are defined in [transposition-table.md](../modules/transposition-table.md); physical storage is defined in [tt-memory.md](../modules/tt-memory.md).

Repetition history is not part of the Zobrist key, so a stored score may be unsafe after the reversible history changes. The controller conservatively validates history-sensitive TT cutoffs and may retain a rejected entry's move only as an ordering hint. Repetition storage and lookup behavior are defined in [repetition-checker.md](../modules/repetition-checker.md).

## Mate and Draw Scores

`MATE_THRESHOLD` is `0x4000`, `MATE_SCORE` is `0x4100`, and search infinity is `0x7fff`. Non-mate evaluations are clamped inside `[-0x3fff, 0x3fff]`, so bit 14 separates every finite score from the mate interval. The `0x100` gap from the threshold to `MATE_SCORE` supports mate distances through 256 plies, or mate in 128 moves.

A winning mate at root-relative ply `ply` is encoded as `MATE_SCORE - ply`; a losing mate is `-MATE_SCORE + ply`. TT stores normalize mate scores relative to the stored node and restore them relative to the current root.

Draw scores are zero. The controller detects checkmate, stalemate, the 50-move rule, and threefold repetition. It does not detect insufficient material, avoiding a separate full-board material scan. The halfmove clock is part of `FullBoard`; repetition uses a separate history of full 64-bit Zobrist keys.
