# Transposition Table

The TT shares search scores and move-ordering hints between threads. It is heuristic: stores, external writes, and cache fills may be dropped without affecting search correctness. All targets provide external memory; simulation uses a burst-memory model. The device engine profile selects store, outstanding-read, response-word, and writeback queue depths; entry-index queues and their routing metadata share the outstanding-read limit. Physical storage and CDC are described in [tt-memory.md](tt-memory.md).

## Entries and Lookup

An entry is a complete group of three ways. Each way stores a configurable position tag, signed evaluation score, searched depth, bound type, relative search age, and source/destination squares. Logical width derives from the sum of these field types. Each external way is independently padded to the memory-word boundary; entry count derives from memory capacity and the resulting three-way footprint. An invalid bound identifies an empty way.

A probe carries the full Zobrist key, thread identity, requested depth/window, and root-relative ply. Every accepted probe returns one response tagged for its thread. A hit requires a valid bound and matching position tag in any way; age does not invalidate older search results. The two-way set-associative cache stores individual TT ways. Cache misses read the complete external entry. Compact tags can admit false hits between positions sharing the same external entry and tag.

Matching scores are restored from node-relative mate distance to the requesting root ply. The search controller checks depth and bound before accepting a cutoff. Root hits provide move ordering only. Scores are also withheld when the current halfmove clock plus remaining search depth reaches the fifty-move boundary, because the position key does not encode that clock. Repetition-sensitive cutoff validation remains described in [search-design.md](../architecture/search-design.md).

## Moves

TT moves store only the starting and ending square. Equal squares encode an omitted move, which is impossible for a legal standard-chess move. Decoding supplies queen promotion; ordinary moves ignore that field. The search producer checks the source board to omit an underpromotion move while retaining its score, depth, bound, and tag.

## Replacement

The age counter advances once per root search and wraps modularly. One replacement datapath serves both cache-hit stores and complete external store responses; cache-hit stores have priority. Registers separate the cache comparison, replacement, and publication stages without an intervening store-hit FIFO.

When a valid way matches the incoming position tag, only that way can change. Replacement permits a deeper result, an allowed equal-depth refresh, or a result from a newer search within the configured depth tolerance. Equal-depth bounds cannot displace an exact result; another exact result can refresh it.

When no way matches, an empty way is preferred. Otherwise the victim minimizes signed `depth - 8 * relative_age`, following [Stockfish's depth-minus-age policy](https://github.com/official-stockfish/Stockfish/blob/master/src/tt.cpp). Ties choose the first way. The other two ways are preserved. An accepted replacement publishes only the selected updated way to the cache and external memory.

## Reset and New Game

Reset serially invalidates both slots in every cache set and initializes LRU state. The external controller invalidates each way before releasing readiness. New Game stops new requests, drains outstanding metadata and memory traffic, clears one validity-containing memory word per way through a CDC toggle handshake, and sweeps cached ways. These serial operations minimize area.
