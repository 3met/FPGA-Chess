# Search Design

## Search Model

Each hardware search thread runs iterative-deepening alpha/beta search. Threads cooperate through Lazy SMP and share only the transposition table.

The number of threads, allocated stack depth, external perft support, Zobrist hashing, TT traffic, and board-update PST ROM use are parameterized at build time.

Search uses side-to-move point-of-view scores internally. Raw evaluation inputs are White-relative, so the search controller normalizes leaf/static scores by negating them when Black is to move.

The full/default search uses iterative deepening with principal variation search (PVS), transposition tables, and quiescence search with captures and promotions only. The first legal move at a main-search node uses the full alpha/beta window. Later moves use a null window and are searched again with the full window only when the scout result raises alpha without reaching beta. Qsearch inherits its caller's window but does not apply PVS to its own captures and promotions.

## Thread State

Each thread owns its search stack, alpha/beta values, depth counters, node counters, current board state, move history stack records, scheduler phase, pipeline wait state, and per-pipeline in-flight flags.

Search uses stack records for reverse traversal rather than storing a full board state at every ply. A push move sends the current board state and move into the board update pipeline, and a reverse move uses the stored move record to recover the previous state.

For the base design, a thread may have at most one in-flight request per major pipeline. Current controller RTL tags board-update, move-generation, and static-evaluation requests with fixed-latency thread tag shift registers and routes completions through those tags; TT responses carry `thread_id` solely as routing metadata, and TT lookup results are captured into per-thread pending records before dispatcher-selected application. Completed child scores are held as per-thread return-pending work and folded into parent nodes only after dispatcher selection, so result routing is no longer tied directly to the thread that happened to be current when a pipeline completed. The controller tracks per-pipeline in-flight flags and dispatch cursors, issues independent ready threads into board, move, eval, TT lookup, and TT store paths when work is available, and tests assert overlapping move-generator requests plus overlap between different tagged pipelines.

## Pipeline Scheduling

The search controller feeds five shared pipelines: board update, move generation, static evaluation, TT lookup, and TT store.

Board update, move generation, and static evaluation are high-area pipelines and should be kept busy by scheduling work across the available threads. These pipelines allow one accepted request per cycle when work is available. TT pipelines are constrained by external memory bandwidth.

Pipeline arbitration prioritizes captured TT lookup responses, parent-return folding, TT lookups, and normal ready search progress over TT stores, because lookups and returned child values block search progress while stores can usually be delayed. Current controller RTL captures lookup responses by thread, leaves accepted-but-not-issued stores as per-thread `STORE_WAIT` pending work, and retries delayed work from the concurrent run scheduler when higher-priority contexts are not available.

## Move Generation and Legality

The move generator accepts a legal input position and emits one ordered pseudo-legal candidate per dispatch. It cheaply rejects invalid castling paths; ordinary strict legality is checked after speculative board update. Every candidate is consumed for the node even when the updated result is rejected.

After a search push completes, the controller tests whether the side that moved left its king attacked. If so, it ignores the updated board, hash, and evaluation and requests another candidate from the unchanged node. The stateless board pipeline needs no reverse operation, and its unused history entry is overwritten by the next push at the same ply. Castling through check remains an early move-generator rejection because its origin and transit conditions are not visible in the final board. Checkmate-versus-stalemate scoring registers the terminal check result before root selection and return-state updates so the full-board scan does not share their timing path.

Host-supplied game-position commands are assumed valid because the Python host validates UCI inputs before sending FPGA commands. Search-generated moves still need legality filtering because pseudo-legal candidate generation can produce moves that leave the moving side in check.

## Transposition Table Use

The TT is required for Lazy SMP communication between threads. The primary TT is stored in external memory behind a vendor-neutral wrapper, with a BRAM cache when the target FPGA has enough block memory to make caching useful.

Scores stored in the TT should use the same side-to-move point-of-view convention as the search controller. The TT replacement policy is single-entry depth/age replacement. Store into an invalid entry, a stale entry that is not much deeper than the new result, a shallower entry, or a same-depth non-exact entry when the new result is exact.

## Mate and Draw Scores

Use `MATE_SCORE = 32000` and `MATE_THRESHOLD = 31000`. Non-mate evaluation scores must be clamped inside `[-MATE_THRESHOLD + 1, MATE_THRESHOLD - 1]`.

A winning forced mate at search ply `ply` is encoded as `MATE_SCORE - ply`. A losing forced mate is encoded as `-MATE_SCORE + ply`. This makes faster mates score higher and delayed losses score better than immediate losses.

TT stores should normalize mate scores to be relative to the stored node rather than the root ply. TT lookups should restore scores relative to the current root search.

Draw scores are `DRAW_EVAL_SCORE = 0`. The controller detects checkmate, stalemate, the 50-move rule, and repetition draws; it deliberately does not detect insufficient material to avoid the area cost of a full-board material scan. The 50-move rule uses `halfmove_clock` from `FullBoard`. Repetition detection uses a separate history of reversible-position hashes because repetition history is intentionally not part of `FullBoard`.

For threefold repetition, the engine uses authoritative 64-bit Zobrist keys. A shared checker builds two collision-free 256-entry pre-root tables, one for each root-relative side-to-move parity, and stores per-thread search-line keys in one simple-dual-port RAM bank per adjacent pair of plies. Runtime requests have a five-cycle fixed latency and an initiation interval of one cycle. The current node is excluded from both histories, stale line entries are masked by the current ply and irreversible boundary, and a draw is reported after two saturated previous occurrences. Repetition-draw detection is disabled when `ENABLE_ZOBRIST = 0`.

The default 32-entry search stack represents plies 0 through 31. Its line history therefore uses 16 logical banks; the second slot in the last bank is unused. Static construction occurs before search timing begins and may retry programmable hash seeds. On Cyclone V, the two 256-by-67 static tables use four M10Ks, the 100-by-64 active history uses two, and each independently readable 64-bit line bank uses two. The full eight-thread/32-entry checker therefore uses 38 M10Ks; the DE1-SoC one-thread/eight-entry engine profile uses 14. The high count relative to stored bits is the unavoidable width and shallow-bank underutilization required for parallel reads.
