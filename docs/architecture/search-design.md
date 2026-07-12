# Search Design

## Search Model

Each hardware search thread runs iterative-deepening alpha/beta search. Threads cooperate through Lazy SMP and share only the transposition table.

The number of threads, allocated stack depth, external perft support, Zobrist hashing, TT traffic, and board-update PST ROM use are parameterized at build time. The controller defaults are `SEARCH_THREAD_COUNT = THREAD_COUNT`, `SEARCH_STACK_DEPTH = MAX_PLY_COUNT`, `ENABLE_PERFT = 1`, `ENABLE_ZOBRIST = 1`, `ENABLE_TT = 1`, and `ENABLE_PST = 1`, currently 8 threads and 32 plies for simulation and generic RTL testing.

Current RTL note: shared pipelines have explicit multi-thread isolation tests, and the search controller initializes all configured root thread contexts as active and ready for each iterative-deepening pass. It then runs a concurrent scheduler with active-thread count, root round-robin cursor, child-return round-robin cursor, TT-response round-robin cursor, and per-pipeline dispatch cursors for board update, move generation, static evaluation, TT lookup, and TT store issue. Different configured threads can occupy different tagged pipelines at the same time. The controller also applies deterministic per-thread root move hints and a stable score-plus-move tie-break for reproducible best-result selection. The `quartus-de1-soc` synthesis target uses the real controller with one search context and eight allocated plies.

Search uses side-to-move point-of-view scores internally. Raw evaluation inputs are White-relative, so the search controller normalizes leaf/static scores by negating them when Black is to move.

The full/default search uses iterative deepening with plain alpha/beta, transposition tables, and quiescence search with captures and promotions only. A target may disable TT traffic for synthesis bring-up; in that profile the search still runs alpha/beta/qsearch but loses TT cutoffs, TT move ordering, and TT-based thread cooperation.

## Thread State

Each thread owns its search stack, alpha/beta values, depth counters, node counters, current board state, move history stack records, scheduler phase, pipeline wait state, and per-pipeline in-flight flags.

Search uses stack records for reverse traversal rather than storing a full board state at every ply. A push move sends the current board state and move into the board update pipeline, and a reverse move uses the stored move record to recover the previous state.

For the base design, a thread may have at most one in-flight request per major pipeline. Current controller RTL tags board-update, move-generation, and static-evaluation requests with fixed-latency thread tag shift registers and routes completions through those tags; TT requests carry `thread_id` in the request/response records, and TT lookup responses are captured into per-thread pending records before dispatcher-selected application. Completed child scores are held as per-thread return-pending work and folded into parent nodes only after dispatcher selection, so result routing is no longer tied directly to the thread that happened to be current when a pipeline completed. The controller tracks per-pipeline in-flight flags and dispatch cursors, issues independent ready threads into board, move, eval, TT lookup, and TT store paths when work is available, and tests assert overlapping move-generator requests plus overlap between different tagged pipelines.

## Pipeline Scheduling

The search controller feeds five shared pipelines: board update, move generation, static evaluation, TT lookup, and TT store.

Board update, move generation, and static evaluation are high-area pipelines and should be kept busy by scheduling work across the available threads. These pipelines allow one accepted request per cycle when work is available. TT pipelines are constrained by external memory bandwidth.

Pipeline arbitration prioritizes captured TT lookup responses, parent-return folding, TT lookups, and normal ready search progress over TT stores, because lookups and returned child values block search progress while stores can usually be delayed. Current controller RTL captures lookup responses by thread, leaves accepted-but-not-issued stores as per-thread `STORE_WAIT` pending work, and retries delayed work from the concurrent run scheduler when higher-priority contexts are not available.

## Move Generation and Legality

The move generator accepts a legal input position and emits one ordered candidate move per dispatch. It also reports whether the candidate is legal. If the candidate is illegal, it is still consumed for that node, and the thread should dispatch move generation again to obtain the next candidate.

Illegal-move filtering is intended to cover cases such as pinned pieces, king moves into attacked squares, check restrictions, double-check restrictions, en passant discovered checks, and castling through check. The board update pipeline does not create a replacement move after an illegal move is rejected.

Host-supplied game-position commands are assumed valid because the Python host validates UCI inputs before sending FPGA commands. Search-generated moves still need legality filtering because pseudo-legal candidate generation can produce moves that leave the moving side in check.

## Transposition Table Use

The TT is required for Lazy SMP communication between threads. The primary TT is stored in external memory behind a vendor-neutral wrapper, with a BRAM cache when the target FPGA has enough block memory to make caching useful.

Scores stored in the TT should use the same side-to-move point-of-view convention as the search controller. The TT replacement policy is single-entry depth/age replacement. Store into an invalid entry, a stale entry that is not much deeper than the new result, a shallower entry, or a same-depth non-exact entry when the new result is exact.

## Mate and Draw Scores

Use `MATE_SCORE = 32000` and `MATE_THRESHOLD = 31000`. Non-mate evaluation scores must be clamped inside `[-MATE_THRESHOLD + 1, MATE_THRESHOLD - 1]`.

A winning forced mate at search ply `ply` is encoded as `MATE_SCORE - ply`. A losing forced mate is encoded as `-MATE_SCORE + ply`. This makes faster mates score higher and delayed losses score better than immediate losses.

TT stores should normalize mate scores to be relative to the stored node rather than the root ply. TT lookups should restore scores relative to the current root search.

Draw scores are `DRAW_EVAL_SCORE = 0`. A fully legal implementation must detect checkmate, stalemate, the 50-move rule, insufficient material, and repetition draws. The 50-move rule uses `halfmove_clock` from `FullBoard`. Repetition detection uses a separate history of reversible-position hashes because repetition history is intentionally not part of `FullBoard`.

For threefold repetition, the engine uses authoritative 64-bit Zobrist keys. A shared checker builds two collision-free 256-entry pre-root tables, one for each root-relative side-to-move parity, and stores per-thread search-line keys in one simple-dual-port RAM bank per adjacent pair of plies. Runtime requests have a five-cycle fixed latency and an initiation interval of one cycle. The current node is excluded from both histories, stale line entries are masked by the current ply and irreversible boundary, and a draw is reported after two saturated previous occurrences. Repetition-draw detection is disabled when `ENABLE_ZOBRIST = 0`.

The default 32-entry search stack represents plies 0 through 31. Its line history therefore uses 16 logical banks; the second slot in the last bank is unused. Static construction occurs before search timing begins and may retry programmable hash seeds. On Cyclone V, the two 256-by-67 static tables use four M10Ks, the 100-by-64 active history uses two, and each independently readable 64-bit line bank uses two. The full eight-thread/32-entry checker therefore uses 38 M10Ks; the DE1-SoC one-thread/eight-entry engine profile uses 14. The high count relative to stored bits is the unavoidable width and shallow-bank underutilization required for parallel reads.

Current RTL note: the active history, both static tables, and every line-history bank use the portable synchronous simple-dual-port wrapper. Quartus infers `altsyncram` M10Ks for these instances; AMD/Xilinx tools use the same synchronous template with the recognized `ram_style="block"` attribute.
