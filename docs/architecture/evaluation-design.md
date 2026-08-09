# Static Evaluation Design

## Score Convention

Raw evaluation is White-relative: positive scores favor White and negative scores favor Black. Search converts it to side-to-move point-of-view by negating the score when Black is to move.

## Material Valuation

Material values are maintained incrementally. The base material unit is 1/128 pawn, using `PIECE_VALS_128` generated from the canonical evaluation-parameter JSON.

## Piece-Square Tables

Piece-square-table scoring is White-relative. White pieces add their table value; Black pieces subtract the mirrored-square table value.

The board update pipeline maintains White-relative incremental material plus piece-square-table state. NNUE supplies a separately trained White-relative correction.

## NNUE Correction

The NNUE uses a direct 2-side by 6-piece by 64-square encoding, for 768 inputs per perspective. Each perspective has its own-piece and opposing-piece categories, with Black squares vertically flipped into its point of view. Each perspective has 256 signed six-bit modular accumulators with signed three-bit bias; the trained distribution remains inside the represented range, while modular add/remove operations remain exact inverses if a rare extreme wraps. Feature-transformer weights use direct signed two-bit ternary encoding in 512-bit ROM rows.

The update pipeline applies one physical feature change to all 256 lanes of both perspectives and can accept a new row every cycle. The output applies ReLU clipped at 31 to the already biased accumulator state, subtracts Black-perspective activations from White-perspective activations, and evaluates the 256 differences with 128 shared int4 MAC lanes over two cycles. The bias-free difference head makes the correction exactly color-antisymmetric.

Final evaluation is `material + PST + NNUE correction`. Material and PST remain independently trainable and continue to be maintained incrementally.
