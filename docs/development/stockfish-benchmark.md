# Stockfish Benchmark

Run `python -m tools.stockfish_benchmark` from the repository root to play the FPGA engine against Stockfish with a fixed node budget. Fastchess and Stockfish must be on `PATH`; set `FPGA_CHESS_PORT` or use serial-port autodetection. Use `--help` for match, clock, and Stockfish settings. The `Stockfish-unlimited` label means strength limiting is disabled; the node cap still applies.

The default opening book is `../fastchess/books/UHO_Lichess_4852_v1.epd`. Fastchess shuffles its positions with a fixed seed and plays each selected position with both colors. The same seed keeps opening selection consistent across runs and resumes. If the book is absent, the tool downloads the official Stockfish opening suite into `work/books/`. Pass `--book PATH` to use another local book. Use `--fastchess` and `--stockfish` to select other executables.

Matching openings does not guarantee identical search results: threads share TT publications, and memory timing can change the search tree even with a fixed node limit. Compare matched opening pairs when estimating rating differences, and record the flashed image identity separately because the tournament metadata does not identify it.

```text
python -m tools.stockfish_benchmark
python -m tools.stockfish_benchmark --matches 250
python -m tools.stockfish_benchmark baseline 250 --stockfish-nodes 20000
python -m tools.stockfish_benchmark baseline --elo-error 20
python -m tools.stockfish_benchmark baseline --continue
python -m tools.stockfish_benchmark --resume work/benchmark-results/baseline
```

The optional name defaults to a local timestamp. Results go to `work/benchmark-results/<name>/` unless `--results-root` is set. An existing run name is an error; `--continue` resumes that named run from its saved settings, while `--force` replaces it. A completed run returns its saved result without starting Fastchess. The directory contains the PGN, Fastchess log and autosave, full output, compact summary, and run metadata. Use `--resume RUN_DIR` to resume by directory instead. Optional `--sprt-elo0` and `--sprt-elo1` enable Fastchess's logistic SPRT early stopping.

Ctrl+C asks Fastchess to stop and save its tournament state, then cleans up any remaining engine processes. The command exits with status 130 and prints the resume command when an autosave exists. An abrupt kill resumes from the last saved checkpoint, so games played after that checkpoint may be replayed. A run cannot resume before its first checkpoint exists.

Use `--elo-error ELO` instead of a match count to stop when Fastchess reports a finite Elo confidence half-width of at most `ELO` (the number after `+/-` in its standings). The tool checks after every batch of paired openings and extends the same saved tournament while keeping earlier games. Use `--max-matches` to set a safety cap; reaching the cap without meeting the target is an error. Elo-error stopping cannot be combined with SPRT.
