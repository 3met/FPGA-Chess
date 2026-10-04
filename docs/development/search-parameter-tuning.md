# Search-Parameter Tuning

`python -m tools.search_tuning run` tunes the synthesized search policy against Stockfish. It measures the baseline in `hardware/config/search/default.json`, proposes candidates, synthesizes and programs them, and evaluates them through the shared [Stockfish benchmark](stockfish-benchmark.md).

## Configuration and Commands

Settings live in `tools/search_tuning/default_config.json`. Copy the configuration to customize parameters, ranges, match length, executable paths, synthesis settings, or optimizer effort. Iteration count, progress frequency, synthesis jobs, and acquisition-pool sizes may change on resume. Changes to selected parameters or experiment semantics require a new output directory or `--clean`.

- `python -m tools.search_tuning run --dry-run` validates the setup and creates the first candidate without synthesizing or programming hardware.
- `python -m tools.search_tuning status` reports progress.
- Re-running `python -m tools.search_tuning run` resumes interrupted work.
- After changing RTL or engine behavior, `python -m tools.search_tuning run --clean` archives the existing output and starts from the current baseline.

Build and programming targets, vendor tools, benchmark executables, and the opening book must be available. Programming requires a successful build matching the candidate. Incompatible experiment inputs are rejected on resume.

## Results

Outputs live under `work/search-tuning/`:

| Path | Contents |
| ---- | -------- |
| `candidate.json` | Current trial policy. |
| `best.json` | Strongest policy accepted by validation. |
| `provisional.json` | Most promising validated challenger. |
| `trials/` | Saved trial policies. |
| `logs/` | Synthesis, programming, and tournament output. |
| `report.json` | Rankings, validation results, rejected trials, and parameter consensus. |

The tuner leaves the tracked search and engine profiles unchanged. Interrupted builds and tournaments resume from saved state.

## Evaluation

Candidate selection accounts for noisy Elo estimates. Every tournament uses the same shuffled opening block, and promising candidates are validated against the baseline on those matched openings; `best.json` changes only when the configured promotion criterion is met. Validation games are separate from exploration trials.

The `early_stopping` setting can reject inferior exploration candidates before a full match. Validation matches run to their configured length. Synthesis failures and tournaments exceeding the configured runtime-failure limit are excluded from playing-strength estimates. Repeated synthesis rejection stops the run at the configured limit.
