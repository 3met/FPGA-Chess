# Static Evaluator (`static_evaluator`)

Status: implemented V1; this document describes the current RTL contract and planned extension point.

The static evaluator computes a White-relative score from board-state inputs and the current incremental material plus piece-square-table score. Search converts the result to side-to-move point-of-view when consuming it.

## Ports

| Direction | Port Name | Description |
| --------- | --------- | ----------- |
| Input | `clk` | Clock. |
| Input | `board_tiles` | 64 x 4-bit tiles. |
| Input | `base_eval` | Current White-relative material plus piece-square-table score from the board update pipeline. |
| Output | `static_eval` | White-relative static evaluation score. |

## Pipeline

| Pipeline Stage | Description |
| -------------- | ----------- |
| 0 | Register input board tiles and `base_eval`; initialize directional scan state. |
| 1-6 | Propagate nearest-piece and visible-empty-square data one ray distance per stage. |
| 7 | Propagate the final ray distance, add positional terms to delayed `base_eval`, and set output score. |

`STATIC_EVAL_PIPELINE_STAGE_CNT` is 8. The pipeline accepts one request per cycle. Outputs are only meaningful after a request has traversed the fixed latency; there are no valid/ready signals in V1.

## V1 Positional Terms

`static_eval = delayed base_eval + positional_delta`.

| Term | Weight | Description |
| ---- | ------ | ----------- |
| Friendly pawn shield | `+4` for White, `-4` for Black | Each same-color pawn visible within fewer than two empty squares of its king. |
| Trapped bishop | `-4` for White, `+4` for Black | Bishop with no empty square on any diagonal before a blocker or board edge. |
| Rook on fully open file | `+6` for White, `-6` for Black | Rook with no visible piece north or south on its file. |
| Doubled pawn | `-6` for White, `+6` for Black | Pawn with a same-color pawn visible north on its file, matching the initial evaluator heuristic. |
| Slider mobility | `+1` per visible empty square for White, `-1` for Black | Rook and queen cardinal mobility; bishop and queen diagonal mobility. |

## Score Convention

Positive `static_eval` values favor White. Negative values favor Black. The evaluator should not know whose turn it is unless a future evaluation term explicitly depends on side to move.

## Current RTL Notes

The current RTL uses `base_eval` for material and PST and does not access PST ROMs. Simulation assertions catch pawns on the first or eighth rank, adjacent kings, and `SPARE_PIECE` inputs.
