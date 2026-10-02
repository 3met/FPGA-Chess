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

If hash collisions prevent building the table, the checker scans active-history keys instead; hash collisions cannot change repetition results or prevent legal history from being searched.

Line-history lookup considers only entries in the active line and reversible range, so stale storage does not affect results.

## Request and Response

A request identifies the thread, current ply, reversible-history boundary, request epoch, and full Zobrist key. The response returns the thread and epoch for routing, a previous-occurrence count saturated at two, and a draw flag. The controller uses the same interface for ordinary children and for speculative children examined while validating history-sensitive TT cutoffs.

The epoch distinguishes a valid response from work invalidated by a search restart or flush. The controller accepts `resp_is_draw` only for the matching live request.

Normal table lookups accept one request per cycle with fixed response latency. The exact RAM-scan path has variable latency and supports one outstanding request per search thread; the controller waits for its tagged response. Flush and history changes discard pending scans.

## Active-Game Updates

New Game or direct position replacement resets active history to the new root. A committed reversible game move appends the resulting full Zobrist key. An irreversible move establishes a new repetition boundary so positions before it are excluded from subsequent search initialization.

Flush cancels in-flight lookup responses without changing the active-game history.
