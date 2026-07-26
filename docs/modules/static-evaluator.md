# Static Evaluator (`static_evaluator`)

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
| 0 | Register input board tiles and `base_eval`. Long directional scans inspect their first one to three statically selected ray squares; shorter scans remain constant empty until their geometry-specific start stage. |
| 1-2 | Each active directional scan inspects up to three successive squares from the matching delayed board copy until it finds the nearest piece, then carries that result forward. Starting short edge and diagonal rays late avoids storing their inactive state in early propagation registers. |
| 3 | Add positional terms to delayed `base_eval` with a balanced fixed-width reduction tree and register the output score. |

`STATIC_EVAL_PIPELINE_STAGE_CNT` is 4. The pipeline accepts one request per cycle. Outputs are only meaningful after a request has traversed the fixed latency.

The three directional propagation slots are scheduled independently for each square and direction. A ray uses `ceil(d/3)` slots for maximum distance `d`, with each active slot inspecting the next one to three squares, so every ray completes in slot 2. Slot 0 reads the live input board, while slot `s > 0` reads `board_pipe[s-1]`; the registered result therefore remains aligned with `board_pipe[s]` for the same request.

## Positional Terms

`static_eval = delayed base_eval + positional_delta`.

| Term | Weight | Description |
| ---- | ------ | ----------- |
| Friendly pawn shield | `+4` for White, `-4` for Black | Each same-color pawn visible within fewer than two empty squares of its king. |
| Trapped bishop | `-4` for White, `+4` for Black | Bishop with no empty square on any diagonal before a blocker or board edge. |
| Rook on fully open file | `+6` for White, `-6` for Black | Rook with no visible piece north or south on its file. |
| Doubled pawn | `-6` for White, `+6` for Black | Pawn with a same-color pawn visible north on its file, matching the initial evaluator heuristic. |
| Slider mobility | `+1` per visible empty square for White, `-1` for Black | Rook and queen cardinal mobility; bishop and queen diagonal mobility. |

## Score Convention

Positive `static_eval` values favor White. Negative values favor Black. The evaluator is independent of the side to move.
