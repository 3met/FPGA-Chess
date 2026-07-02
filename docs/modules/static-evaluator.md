# Static Evaluator (`static_evaluator`)

Status: partially implemented; this document describes the final target contract.

The static evaluator computes a White-relative score from board-state inputs. Search converts the result to side-to-move point-of-view when consuming it.

## Ports

| Direction | Port Name | Description |
| --------- | --------- | ----------- |
| Input | `clk` | Clock. |
| Input | `board_tiles` | 64 x 4-bit tiles. |
| Output | `static_eval` | White-relative static evaluation score. |

## Pipeline

| Pipeline Stage | Description |
| -------------- | ----------- |
| 0 | Register inputs. |
| 1-6 | Complete propagation and term accumulation. |
| 7 | Set output score. |

## Score Convention

Positive `static_eval` values favor White. Negative values favor Black. The evaluator should not know whose turn it is unless a future evaluation term explicitly depends on side to move.

## Current RTL Notes

The current RTL is incomplete and currently targets White-relative output, which matches the final evaluation convention.
