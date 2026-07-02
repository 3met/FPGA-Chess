# Static Evaluation Design

## Score Convention

Raw static evaluation is White-relative: positive scores favor White and negative scores favor Black. Search converts raw evaluation to side-to-move point-of-view by negating the score when Black is to move.

## Material Valuation

Material values are maintained incrementally. The base material unit is 1/128 pawn, using the values in `PIECE_VALS_128`.

## Piece-Square Tables

Piece-square-table scoring should be White-relative in the final design. White pieces add their table value; Black pieces subtract the mirrored-square table value.

The board update pipeline may maintain a White-relative incremental PST score. The static evaluator may recompute PST terms if that proves smaller or easier to pipeline for a target FPGA.

## Board-State Evaluation

The static evaluator operates from board-state inputs. Evaluation terms may be computed with a processing-element-style internal array or other parallel per-square hardware, but the module interface should be a board-state pipeline interface and should not own the canonical board state.

Evaluation is hybrid. Some terms may be maintained or recomputed alongside board update, while other terms are fully computed by static evaluation on dispatch.
