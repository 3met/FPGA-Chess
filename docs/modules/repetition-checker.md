# Repetition Checker (`repetition_checker`)

The repetition checker determines whether a search position has occurred at least twice previously, making the current occurrence a draw by threefold repetition. It compares full 64-bit Zobrist keys; compact indexing is used only to select storage and never establishes equality.

## History Model

Repetition history has two parts:

- Active-game history contains positions reached before the search root.
- Per-thread line history contains positions reached from the root along each active search line.

The current root position is included in the active-game table. A root request subtracts its current occurrence from the returned count, while matching descendant requests count it when the reversible boundary includes ply zero. Search writes a line key when it accepts a child position. A request supplies the current ply and the earliest reversible ply; entries outside that range are ignored.

Only positions with the same side-to-move parity can repeat. Active history is partitioned by parity relative to the root, and line history reads only plies matching the requested position's parity.

## Search Initialization

Before search begins, the checker builds a compact static table from the reversible portion of active-game history. Each entry contains a full key and a count saturated at two.

The table uses a programmable hash seed. If two distinct active-history keys collide, initialization retries with another seed. Search begins only after initialization succeeds. Failure to find a collision-free seed is reported to the controller as an initialization failure rather than allowing an ambiguous repetition result.

The per-thread line history is banked by ply so all prior same-parity positions for one request can be read in parallel. Stale data need not be cleared because the request ply and reversible boundary mask entries that are not part of the active line.

## Request and Response

A request identifies the thread, current ply, reversible-history boundary, request epoch, and full Zobrist key. The response returns the thread and epoch for routing, a previous-occurrence count saturated at two, and a draw flag. In addition to ordinary searched children, the controller queries the speculative child of a positive deep TT score when enough reversible history exists to require validation. Any previous occurrence rejects that score because even a nonterminal second occurrence can put a forced continuation one cycle away from a draw.

The epoch distinguishes a valid response from work invalidated by a search restart or flush. The controller accepts `resp_is_draw` only for the matching live request.

The checker accepts one request per cycle after initialization. Its response latency is fixed so requests from different threads may occupy the pipeline concurrently.

## Active-Game Updates

New Game or direct position replacement resets active history to the new root. A committed reversible game move appends the resulting full Zobrist key. An irreversible move establishes a new repetition boundary so positions before it are excluded from subsequent search initialization.

Flush cancels in-flight lookup responses without changing the active-game history.
