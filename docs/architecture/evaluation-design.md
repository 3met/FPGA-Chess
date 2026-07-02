# Static Evaluation Design

## Score Convention

Raw static evaluation is White-relative: positive scores favor White and negative scores favor Black. Search converts raw evaluation to side-to-move point-of-view by negating the score when Black is to move.

`EvalScore` is signed 16-bit. Evaluation logic should saturate or clamp before overflow if future terms can exceed the finite score range.

## Material Valuation

Material may be recomputed instead of maintained incrementally if recomputation uses less area than update logic. The base material unit is 1/128 pawn, using the values in `PIECE_VALS_128`.

## Piece-Square Tables

Piece-square-table scoring should be White-relative in the final design. White pieces add their table value; Black pieces subtract the mirrored-square table value.

The board controller may maintain a White-relative incremental PST score. The static evaluator may recompute PST terms if that proves smaller or easier to pipeline for a target FPGA.

## Board-State Evaluation

The static evaluator operates from board-state inputs. Evaluation terms may be computed with a PE-style internal array or other parallel per-square hardware, but the module interface should be a board-state pipeline interface and should not own the canonical board state.

Evaluation is hybrid. Some terms may be maintained or recomputed alongside board update, while other terms are fully computed by static evaluation on dispatch.

## Required Base Terms

| Term | Required Behavior |
| ---- | ----------------- |
| Material | White-relative material balance in 1/128 pawn units. |
| Piece-square tables | White-relative PST score using mirrored square indices for Black pieces. |
| Basic mobility | Optional for first integration, but if present must be White-relative. |
| Basic king safety | Optional for first integration, but if present must be White-relative. |

## Current RTL Notes

The current `static_evaluator` RTL is incomplete and outputs a White-relative score. The current `board_controller` maintains `pst_eval` from the active-color perspective; final integration should normalize this to White-relative PST state or explicitly convert at the boundary.
