# Stockfish Benchmark

Run `python -m tools.stockfish_benchmark` from the repository root to play the FPGA engine against full-strength Stockfish. By default, it uses 500 paired openings (1,000 games), a `2+0.02` FPGA clock, one Stockfish thread, and 32 MB of hash. Fastchess and Stockfish must be available on `PATH`; the FPGA UCI host uses the current Python interpreter. Set `FPGA_CHESS_PORT` or use the host's serial-port autodetection.

The default opening book is `../fastchess/books/UHO_Lichess_4852_v1.epd`, matching the earlier benchmark. If it is absent, the tool downloads the official Stockfish opening suite into `work/books/`. Pass `--book PATH` to use another local book. Use `--fastchess` and `--stockfish` to select other executables.

```text
python -m tools.stockfish_benchmark
python -m tools.stockfish_benchmark --matches 250
python -m tools.stockfish_benchmark baseline 250 --stockfish-nodes 20000
python -m tools.stockfish_benchmark baseline --elo-error 20
python -m tools.stockfish_benchmark baseline --continue
python -m tools.stockfish_benchmark --resume work/benchmark-results/baseline
```

The optional name defaults to a local timestamp. Results go to `work/benchmark-results/<name>/` unless `--results-root` is set. An existing run name is an error; `--continue` resumes that named run from its saved settings, while `--force` replaces it. A completed run returns its saved result without starting Fastchess. The directory contains the PGN, Fastchess log and autosave, full output, compact summary, and run metadata. Use `--resume RUN_DIR` to resume by directory instead. Optional `--sprt-elo0` and `--sprt-elo1` enable Fastchess's logistic SPRT early stopping.

Ctrl+C asks Fastchess to stop and save its tournament state, then cleans up any remaining engine processes. The command exits with status 130 and prints the resume command when an autosave exists.

Use `--elo-error ELO` instead of a match count to stop when Fastchess reports a finite Elo confidence half-width of at most `ELO` (the number after `+/-` in its standings). The tool checks after every batch of paired openings and extends the same saved tournament while keeping earlier games. Use `--max-matches` to set a safety cap; reaching the cap without meeting the target is an error. Elo-error stopping cannot be combined with SPRT.

Other Python tools can import `BenchmarkConfig`, `run_tournament`, `continue_tournament`, `resume_tournament`, and `read_result` from `tools.stockfish_benchmark`. Successful runs return a `TournamentResult` containing FPGA wins, losses, draws, points, Elo, confidence interval, pentanomial counts, and any SPRT decision. An incomplete or failed tournament raises `BenchmarkError`.
