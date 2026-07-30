# Search Design

## Search Model

Each hardware search thread runs its own iterative-deepening alpha/beta loop. A thread that completes an iteration immediately retries a failed aspiration pass or starts its next depth without waiting for any other thread. Threads cooperate through Lazy SMP and share only the transposition table.

Thread count, allocated stack depth, and optional instrumentation are parameterized at build time.

Search uses side-to-move point-of-view scores internally. Raw evaluation inputs are White-relative, so the search controller normalizes leaf/static scores by negating them when Black is to move.

The full/default search uses iterative deepening with aspiration windows, principal variation search (PVS), null-move pruning, late-move reductions (LMR), transposition tables, and quiescence search with captures and promotions only when the side to move is not in check. A checked qsearch node has no stand-pat option and searches every legal evasion, returning a mate score if none exists. Every search mode uses a half-pawn root margin around the previous completed score from depth two onward; a fail-low or fail-high repeats that depth once with the full window. If a time or node budget expires after a narrow-window failure, the previous completed iteration is returned instead of the failed bound. The first legal move at a main-search node uses the full alpha/beta window. Later moves use a null window; an ordinary scout is repeated at full depth after a non-cutting alpha raise, while every alpha-raising reduced scout is repeated even when it appears to cut off. Qsearch inherits its caller's window but does not apply PVS, null-move pruning, or LMR to its own moves.

After the TT probe, a non-root main-search scout node may search a synthetic null child before generating moves when the side is not in check, the remaining depth is at least three, the parent was not entered by a null move, the node has not already attempted null pruning, beta is outside the losing-mate range, and the reduced subtree cannot reach the 50-move threshold. The reduction is two plies below depth seven and three plies from depth seven onward, so the child receives remaining depth `d - 1 - R` and window `[-beta, -beta + 1]`. A fail-high returns the parent's beta bound; a fail-low resumes ordinary move ordering. Null children do not count as legal moves or searched legal nodes, participate in repetition history, update move ordering or history state, or become best moves. No material-based zugzwang guard or verification search is applied.

LMR approximates `R = round(A + ln(d) * ln(m) / B)` with `ln(x) ~= ln(2) * floor(log2(x))`. `LMR_A_Q8` and `LMR_B_Q8` are unsigned Q8 synthesis parameters, defaulting to 192 (`0.75`) and 614 (approximately `2.4`); a zero denominator is rejected during elaboration. Constant-folded results populate a small depth-bucket by move-bucket ROM, so runtime selection uses floor-log2 buckets and a lookup rather than logarithms, division, or multiplication. The selected reduction is registered when the board request is issued and clamped to `0..d-1`, allowing a reduced child to enter qsearch directly.

An eligible move has parent remaining depth `d >= 3`, is the third or later legal searched move (`m >= 3`), is not at the root, and is not already a full-depth recovery. Captures, promotions, checks, and evasions follow the same all-moves policy. Rejected pseudo-legal candidates do not increment the saturating 8-bit legal-move count, and a recovery of the same move does not increment it a second time. The speculative child uses remaining depth `d - 1 - R` and the normal PVS scout window. Every alpha-raising reduced scout, including an apparent beta cutoff, is verified at full depth; ordinary unreduced PVS beta cutoffs remain final. Its TT probe and store carry the actual depth, while recovery restores `d - 1` and the parent retains its nominal depth.

## Thread State

Each thread owns its search stack, alpha/beta values, depth counters, node counters, current board state, move history stack records, scheduler phase, pipeline wait state, and per-pipeline in-flight flags.

Each thread also owns its current iterative-deepening target, root aspiration window, and completed-iteration result. The primary thread alone publishes the engine result and controls completion of a depth-limited search; helper completion never delays primary progress.

Search node counts advance exactly when a speculative real-move push has passed the king-safety check and the controller enters its legal child position. The root, synthetic null children, and rejected pseudo-legal candidates are not counted; legal children count even when repetition, terminal scoring, or a TT cutoff avoids static evaluation.

Search uses stack records for reverse traversal rather than storing a full board state at every ply. Each packed record includes the node's actual remaining main-search depth and an 8-bit saturating count of legal moves already searched. The actual depth controls qsearch entry and TT depth instead of deriving depth from ply. A push move sends the current board state and move into the board update pipeline, and a reverse move uses the stored move record to recover the previous state. A null push uses the same pipeline and history RAM but toggles only side-to-move state, clears en passant, and increments the halfmove clock; its otherwise-illegal same-square history record identifies the null operation without widening the move-record RAM.

A thread has at most one in-flight request per major pipeline. Requests and responses carry enough routing metadata to associate completion with the issuing thread independently of the controller's current dispatch choice. TT responses and completed child scores are captured as per-thread pending work before being applied, so unrelated pipeline completions may overlap safely.

## Pipeline Scheduling

The search controller feeds five shared pipelines: board update, move generation, static evaluation, TT lookup, and TT store.

Board update, move generation, and static evaluation are high-area pipelines kept busy by scheduling work across the available threads. These pipelines allow one accepted request per cycle when work is available. TT pipelines are constrained by external memory bandwidth.

Pipeline arbitration prioritizes captured TT lookup responses, parent-return folding, TT lookups, and normal ready search progress over TT stores, because lookups and returned child values block search progress while stores can be delayed. Delayed work remains associated with its thread and is retried by the scheduler.

## Move Generation and Legality

The move generator exposes independent tagged variable-latency noisy/direct and quiet request/response channels. Each pipeline serially generates explicit pseudo-legal candidates into its four class-owned LIFO bucket RAMs, allowing requests and completions for different threads to overlap without frontend or response serialization, while a common tagged pop frontend preserves global bucket priority. It cheaply rejects invalid castling paths; ordinary strict legality is checked after speculative board update. Popping a move consumes it regardless of whether board update later rejects it, and an attempted direct TT/root move is suppressed by exact encoded equality.

After a search push completes, the controller tests whether the side that moved left its king attacked. If so, it ignores the updated board, hash, and evaluation and requests another candidate from the unchanged node. The stateless board pipeline needs no reverse operation, and its unused history entry is overwritten by the next push at the same ply. Castling through check remains an early move-generator rejection because its origin and transit conditions are not visible in the final board. Checkmate-versus-stalemate scoring registers the terminal check result before root selection and return-state updates so the full-board scan does not share their timing path.

Host-supplied game-position commands are assumed valid because the Python host validates UCI inputs before sending FPGA commands. Search-generated moves still need legality filtering because pseudo-legal candidate generation can produce moves that leave the moving side in check.

## Transposition Table Use

The TT is required for Lazy SMP communication between threads. Its lookup, score, and replacement semantics are defined in [transposition-table.md](../modules/transposition-table.md), and its physical backends are defined in [tt-memory.md](../modules/tt-memory.md).

## Mate and Draw Scores

Use `MATE_SCORE = 32000` and `MATE_THRESHOLD = 31000`. Non-mate evaluation scores must be clamped inside `[-MATE_THRESHOLD + 1, MATE_THRESHOLD - 1]`.

A winning forced mate at search ply `ply` is encoded as `MATE_SCORE - ply`. A losing forced mate is encoded as `-MATE_SCORE + ply`. This makes faster mates score higher and delayed losses score better than immediate losses.

TT stores normalize mate scores relative to the stored node rather than the root ply. TT lookups restore scores relative to the current root search.

Draw scores are `DRAW_EVAL_SCORE = 0`. The controller detects checkmate, stalemate, the 50-move rule, and repetition draws; it deliberately does not detect insufficient material to avoid the area cost of a full-board material scan. The 50-move rule uses `halfmove_clock` from `FullBoard`. Repetition detection uses a separate history of reversible-position hashes because repetition history is intentionally not part of `FullBoard`.

For threefold repetition, the engine uses authoritative 64-bit Zobrist keys. The controller checks the root before starting an iteration and checks every legal child before TT, evaluation, move-generation, or quiescence processing continues. History representation, parity handling, reversible boundaries, and request routing are defined in [repetition-checker.md](../modules/repetition-checker.md).
