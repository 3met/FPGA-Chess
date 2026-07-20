# Static Evaluation Design

## Score Convention

Raw static evaluation is White-relative: positive scores favor White and negative scores favor Black. Search converts raw evaluation to side-to-move point-of-view by negating the score when Black is to move.

## Material Valuation

Material values are maintained incrementally. The base material unit is 1/128 pawn, using `PIECE_VALS_128` generated from the canonical evaluation-parameter JSON.

## Piece-Square Tables

Piece-square-table scoring should be White-relative in the final design. White pieces add their table value; Black pieces subtract the mirrored-square table value.

The board update pipeline maintains White-relative incremental material plus piece-square-table state. The static evaluator receives that value as `base_eval` and adds board-derived positional terms.

## Board-State Evaluation

The static evaluator operates from board-state inputs plus `base_eval`. Evaluation terms may be computed with a processing-element-style internal array or other parallel per-square hardware, but the module interface should be a board-state pipeline interface and should not own the canonical board state.

Evaluation is hybrid. Material and PST terms are maintained by board update, while positional terms such as pawn shield, trapped bishops, open rook files, doubled pawns, and slider mobility are computed by static evaluation on dispatch.
