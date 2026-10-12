# Search-Parameter Tuning

Use `python -m tools.search_tuning run` to tune the synthesized search policy against Stockfish. The tuner benchmarks a baseline, proposes policies, synthesizes and programs each candidate, and evaluates it through the [Stockfish benchmark](stockfish-benchmark.md). It requires a connected FPGA and can reprogram it repeatedly.

## Setup and Run

Run commands from the repository root. Copy [`tools/search_tuning/default_config.json`](../../tools/search_tuning/default_config.json) and set the baseline policy, parameter selection and ranges, output directory, synthesis/programming targets, executable paths, and opening book. Ensure vendor tools, Fastchess, Stockfish, and the [FPGA host connection](../usage/de1-soc-uci.md) are available.

Validate the setup and prepare the next candidate before starting hardware work:

```text
python -m tools.search_tuning run --config <config-path> --dry-run
python -m tools.search_tuning run --config <config-path>
python -m tools.search_tuning status --config <config-path>
```

Omit `--config` to use the checked-in configuration. `--dry-run` creates or inspects a candidate without synthesizing, programming, or playing games. Programming requires a successful build matching that candidate.

## Resume or Restart

Re-run the same `run` command to resume saved work, including interrupted builds and tournaments. Iteration count, progress frequency, synthesis jobs, and acquisition-pool sizes may change on resume. Changes to selected parameters or experiment semantics require a fresh experiment; incompatible inputs are rejected.

After changing RTL or engine behavior, archive the old output and restart from the configured baseline:

```text
python -m tools.search_tuning run --config <config-path> --clean
```

The tuner leaves tracked search and engine profiles unchanged.

## Read the Results

Outputs default to `work/search-tuning/`:

| Path | Contents |
| ---- | -------- |
| `candidate.json` | Current trial policy. |
| `best.json` | Policy accepted by validation. |
| `provisional.json` | Leading challenger pending promotion. |
| `trials/` | Saved trial policies. |
| `logs/` | Synthesis, programming, and tournament output. |
| `report.json` | Rankings, validation results, rejected trials, and parameter consensus. |

Candidates use matched opening blocks. Promising policies receive separate validation games against the baseline; `best.json` changes only when the configured promotion criterion is met. A provisional lead does not establish an improvement.

Configured early stopping can reject inferior exploration candidates; validation matches run to their configured length. Synthesis failures and tournaments exceeding the runtime-failure limit are excluded from strength estimates. Repeated synthesis rejection stops the run at its configured limit.
