# Search Design

## Search Model

Each hardware search thread runs iterative-deepening alpha/beta search. Threads cooperate through Lazy SMP and share only the transposition table.

The number of threads is parameterized at build time. The current documented default is `THREAD_COUNT = 8`, but this is a design parameter and should remain easy to change for each FPGA build.

Search uses side-to-move point-of-view scores internally. Raw evaluation inputs are White-relative, so the search controller normalizes leaf/static scores by negating them when Black is to move.

The first full search target is iterative deepening with plain alpha/beta, required TT lookup/store, and quiescence search over captures and promotions only. More advanced search features such as PVS, aspiration windows, null-move pruning, late-move reductions, and futility pruning are future work unless explicitly promoted into this design.

## Thread State

Each thread owns its search stack, alpha/beta values, depth counters, node counters, current board state, move history stack records, and pipeline wait state.

Search uses stack records for undo rather than storing a full board state at every ply. A push move sends the current board state and move into the board update pipeline, and a reverse move uses the stored move record to recover the previous state.

For the base design, a thread may have at most one in-flight request per major pipeline. This lets pipeline results be routed by `thread_id` alone. If future designs allow multiple in-flight requests from the same thread to the same pipeline, requests must add a generation counter or request ID so stale results can be discarded safely.

## Pipeline Scheduling

The search controller feeds five shared pipelines: board update, move generation, static evaluation, TT lookup, and TT store.

Board update, move generation, and static evaluation are high-area pipelines and should be kept busy by scheduling work across the available threads. These pipelines should target one accepted request per cycle when work is available. TT pipelines are constrained by external memory bandwidth.

Pipeline arbitration prioritizes TT lookups over TT stores, because lookups block search progress while stores can usually be delayed.

## Move Generation and Legality

The move generator accepts a legal input position and emits one ordered candidate move per dispatch. It also reports whether the candidate is legal. If the candidate is illegal, it is still consumed for that node, and the thread should dispatch move generation again to obtain the next candidate.

Illegal-move filtering is intended to cover cases such as pinned pieces, king moves into attacked squares, check restrictions, double-check restrictions, en passant discovered checks, and castling through check. The board update pipeline should not be responsible for selecting a replacement move after an illegal move is rejected.

Host-supplied game-position commands are assumed valid because the Python host validates UCI inputs before sending FPGA commands. Search-generated moves still need legality filtering because pseudo-legal candidate generation can produce moves that leave the moving side in check.

## Transposition Table Use

The TT is the required shared Lazy SMP structure between threads. TT lookup can provide cutoffs, scores, and move-ordering hints. TT stores publish completed node results for use by other threads.

The primary TT is stored in external memory behind a vendor-neutral wrapper, with a BRAM cache when the target FPGA has enough block memory to make caching useful.

The live Zobrist key should be 64 bits. TT storage should be parameterized separately: the recommended default is a compact 96-bit entry with a 48-bit verification key, while a 128-bit full-key entry is allowed when the external-memory interface naturally moves 128-bit records. This is wider than the current 32-bit RTL key, but it materially reduces false-hit risk. Scores stored in the TT should use the same side-to-move point-of-view convention as the search controller.

The first TT replacement policy is single-entry depth/age replacement. Store into an invalid entry, a stale entry that is not much deeper than the new result, a shallower entry, or a same-depth non-exact entry when the new result is exact. A future 2-way bucket profile may be added after measuring memory bandwidth and collision behavior.

## Mate and Draw Scores

Use `MATE_SCORE = 32000` and `MATE_THRESHOLD = 31000`. Non-mate evaluation scores must be clamped inside `[-MATE_THRESHOLD + 1, MATE_THRESHOLD - 1]`.

A winning forced mate at search ply `ply` is encoded as `MATE_SCORE - ply`. A losing forced mate is encoded as `-MATE_SCORE + ply`. This makes faster mates score higher and delayed losses score better than immediate losses.

TT stores should normalize mate scores to be relative to the stored node rather than the root ply:

```text
if score >= MATE_THRESHOLD: tt_score = score + ply
if score <= -MATE_THRESHOLD: tt_score = score - ply
otherwise: tt_score = score
```

TT lookups should restore scores relative to the current root search:

```text
if tt_score >= MATE_THRESHOLD: score = tt_score - ply
if tt_score <= -MATE_THRESHOLD: score = tt_score + ply
otherwise: score = tt_score
```

Draw scores are `DRAW_EVAL_SCORE = 0`. A fully legal implementation must detect checkmate, stalemate, the 50-move rule, insufficient material, and repetition draws. The 50-move rule uses `halfmove_clock` from `FullBoard`. Repetition detection uses a separate history of reversible-position hashes because repetition history is intentionally not part of `FullBoard`.

For threefold repetition, the engine should track hashes for the active game history since the last irreversible move and each search thread should track hashes along its current search line. A search node is drawn if the current position has occurred at least twice earlier in the combined relevant history, making the current occurrence the third. The repetition hash must include side to move, castling rights, and en passant availability.

## Open Design Items

- Exact ready-thread arbitration policy.
- TT memory banking and cache structure.
- Exact storage shape for active-game and per-thread repetition hash histories.
- Whether future designs allow multiple in-flight requests per thread per pipeline.
