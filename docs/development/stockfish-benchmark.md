# Stockfish Benchmark

Use `python -m tools.stockfish_benchmark` to play the programmed FPGA against Stockfish. The FPGA uses a time control; Stockfish uses a fixed node budget. Run commands from the repository root after completing [board and UCI host setup](../usage/de1-soc-uci.md).

## Start a Match

Fastchess and Stockfish must be on `PATH`, or supplied with `--fastchess <path>` and `--stockfish <path>`. Set `FPGA_CHESS_PORT` when USB-UART auto-detection cannot identify the adapter.

```text
python -m tools.stockfish_benchmark baseline 250
```

The count is paired openings: each opening is played with both colors, so this example schedules 500 games. Omit the name to use a timestamp; use `--matches <count>` when supplying a count without a name.

| Option | Use |
| ------ | --- |
| `--book <path>` | Select a local EPD opening book. |
| `--fpga-tc <time-control>` | Set the FPGA's Fastchess time control. |
| `--stockfish-nodes <count>` | Set Stockfish's per-move node budget. |
| `--stockfish-threads <count>`, `--stockfish-hash <MB>` | Set Stockfish threads and hash memory. |
| `--opening-start <index>` | Select the starting opening index. |
| `--opening-seed <seed>` | Set the seed used to shuffle openings. |
| `--results-root <directory>` | Change the results directory. |

Use `--help` for all options. `Stockfish-unlimited` in the output means strength limiting is disabled; the node cap still applies.

The default book is `../fastchess/books/UHO_Lichess_4852_v1.epd`. If absent, the tool downloads the official Stockfish opening suite into `work/books/`. Opening selection is shuffled with a fixed seed. New matches use shared resign and draw adjudication settings; resumed matches retain their saved settings.

## Stop by Confidence

Instead of a fixed match count, stop when the reported Elo confidence half-width reaches a target:

```text
python -m tools.stockfish_benchmark baseline --elo-error 20
```

The tool checks the number after `+/-` in Fastchess standings after each batch of paired openings and extends the saved tournament as needed. Use `--max-matches <count>` to cap the paired openings; reaching the cap without meeting the target is an error.

Alternatively, supply both `--sprt-elo0 <Elo>` and `--sprt-elo1 <Elo>` for logistic SPRT early stopping. Elo-error stopping cannot be combined with a match count or SPRT.

## Results and Resume

Results default to `work/benchmark-results/<name>/` and include PGN, logs, autosave state, a summary, and run metadata. An existing run name is rejected; `--force` replaces an existing run created by the tool.

Ctrl+C requests a checkpoint, stops the engine processes, and prints a resume command when an autosave exists:

```text
python -m tools.stockfish_benchmark baseline --continue
python -m tools.stockfish_benchmark --resume work/benchmark-results/baseline
```

Resume uses saved match settings. Do not supply a new match count or Elo-error target. A completed run returns its saved result. Resuming requires at least one checkpoint; after an abrupt kill, games since the last checkpoint may be replayed.

For comparisons, keep the opening selection, time control, Stockfish settings, and adjudication consistent. Shared TT updates and memory timing can change search results even under a fixed node limit. Record the flashed image identity separately; tournament metadata does not identify it.
