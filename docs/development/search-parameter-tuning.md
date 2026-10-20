# Search-Parameter Tuning

The search tuner finds search-policy settings by synthesizing each candidate, programming the FPGA, and playing it against Stockfish through the [benchmark runner](stockfish-benchmark.md). It tunes the search policy separately from [evaluation training](evaluation-tuning.md).

## Configure an Experiment

Run commands from the repository root. Prepare the [FPGA host connection](../usage/de1-soc-uci.md), install the vendor build and programming tools, and make Fastchess, Stockfish, and a local EPD opening book available.

Copy [`tools/search_tuning/default_config.json`](../../tools/search_tuning/default_config.json) for your experiment. Relative paths in the configuration resolve from the repository root; `output_root` must remain inside the repository.

| Settings | Purpose |
| -------- | ------- |
| `baseline` | Search-policy JSON used as the starting point and validation reference. |
| `parameters.enabled`, `parameters.overrides` | Parameter paths to tune and optional range or quantization overrides. `["*"]` enables every supported parameter. See [space.py](../../tools/search_tuning/space.py) for supported paths and bounds. |
| `iterations` | Total exploration evaluations, including the baseline. Final validation is additional. |
| `paired_openings`, `opening_start`, `opening_book` | Opening block used by each tournament. Each opening is played with both colors, so a full tournament contains twice `paired_openings` games. |
| `fpga_time_control`, `stockfish_nodes` | FPGA time control and Stockfish per-move node budget. Stockfish strength limiting is disabled. |
| `synthesis_target`, `flash_target`, `synthesis_seeds` | Matching build/programming targets and fitter seeds to try when a build fails. |
| `fastchess_binary`, `stockfish_binary` | Paths to benchmark executables. |
| `output_root`, `benchmark_results_root` | Tuner checkpoints and reports, and separate tournament results. |

Selected parameter ranges must contain the baseline values. Use `optimizer` settings to control candidate selection and `validation` settings to control finalist selection and the number of validation blocks.

### Random Seeds

The seeds serve separate purposes:

- `random_seed` controls parameter proposals.
- `opening_seed` shuffles openings for all exploration tournaments.
- `validation_opening_seed` shuffles openings for final validation. The baseline and all finalists share this seed across validation blocks.
- `synthesis_seeds` controls fitter retries, independently of opening selection.

The two opening seeds must be distinct nonnegative integers. Exploration and validation opening selections may overlap.

## Run and Monitor

Check dependencies and prepare the next candidate before starting hardware work:

```text
python -m tools.search_tuning run --config <config-path> --dry-run
```

A dry run writes checkpoint and candidate files but does not synthesize, program the FPGA, or play games. It still requires the configured build tools, benchmark executables, and opening book.

Start the experiment and inspect progress with:

```text
python -m tools.search_tuning run --config <config-path>
python -m tools.search_tuning status --config <config-path>
```

Omit `--config` to use the checked-in configuration. A run repeatedly reprograms the connected FPGA; programming requires a successful build matching the candidate. The tuner writes generated policies and an engine profile under `output_root`, leaving tracked profiles unchanged.

## Candidate Selection and Validation

The experiment has three stages:

1. **Startup:** measure the baseline, then a challenger sampled across all enabled parameter ranges. Failed builds and runtime-invalid challengers are replaced until a usable challenger result is available.
2. **Guided exploration:** fit a Gaussian process to usable results and select each subsequent candidate by expected improvement. Candidate proposals are local to the model's leading tested policy; a trust-region radius expands or shrinks as results accumulate.
3. **Final validation:** select promising, distinct finalists from model predictions and play additional tournaments for the baseline and finalists using the validation opening seed. Compare each finalist with the baseline on matching opening/color games from validation only.

`optimizer.candidate_pool_size` controls how many proposals are generated for each guided selection. After quantization and removal of duplicate or previously tested policies, every remaining proposal receives a full Gaussian-process prediction of Elo and uncertainty. The candidate with the highest expected improvement is selected for the next tournament.

The finalist with the highest measured validation Elo difference replaces the baseline whenever that difference is positive. Ties retain the baseline. Error margins are reported but do not affect winner selection. `block_stopping_z_score` and `minimum_success_probability` only decide whether further validation blocks are useful, up to `maximum_blocks`. Each scheduled validation tournament runs to its configured length. Setting `maximum_finalists` to zero disables final validation and leaves the baseline as the selected policy.

Configured early stopping can reject inferior exploration candidates before they finish a full tournament. Synthesis failures and tournaments exceeding `runtime_failures.maximum_per_tournament` are excluded from strength estimates. Candidate builds try the configured fitter seeds before rejection; reaching `maximum_synthesis_rejections` stops the run. A baseline build failure or excessive baseline runtime failures stops the experiment.

## Results

Tuner outputs live under `output_root`:

| Path | Contents |
| ---- | -------- |
| `state.json` | Resume checkpoint, experiment identity, trial history, and current phase. |
| `candidate.json` | Policy currently being built or evaluated. |
| `best.json` | Selected policy: the baseline until a finalist wins validation. |
| `provisional.json` | Leading finalist; its presence does not mean it beat the baseline. |
| `trials/` | Saved exploration policies. |
| `logs/` | Synthesis, programming, and tournament logs. |
| `report.json` | Final validation differences and errors, selected trial, model rankings, and rejected trials. |

Tournament PGNs, standings, and Fastchess autosaves live under `benchmark_results_root`. Exploration Elo is measured against Stockfish; the final report's `elo_difference` compares a finalist with the baseline using validation games.

To adopt the selected policy, copy `best.json` to your intended search-profile location, reference it through the engine profile's `search_config`, and [rebuild and program the engine](build-test-synthesis.md). The image left on the FPGA at the end of tuning is the last evaluated policy and may differ from `best.json`.

## Interrupt, Resume, or Restart

Press Ctrl+C to interrupt, then rerun the same `run` command to resume checkpointed builds and tournaments. Iteration count, progress frequency, synthesis jobs, and candidate-pool size may change on resume.

Changes to parameter selection, opening seeds, match conditions, baseline policy, relevant source code, or benchmark assets require a fresh experiment. Incompatible checkpoints are rejected. Archive the tuner output and restart from the configured baseline with:

```text
python -m tools.search_tuning run --config <config-path> --clean
```

The archive is placed beside `output_root` in a directory named `<output-root-name>-archive`. Tournament results remain under `benchmark_results_root`.
