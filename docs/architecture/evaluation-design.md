# Static Evaluation Design

## Score Convention

Incremental material plus PST evaluation is White-relative: positive scores favor White and negative scores favor Black. Search converts it to side-to-move point of view before adding the side-to-move-relative NNUE correction.

## Material Valuation

Material values are maintained incrementally. The base material unit is 1/128 pawn, using `PIECE_VALS_128` generated from the canonical evaluation-parameter JSON.

## Piece-Square Tables

Piece-square-table scoring is White-relative. White pieces add their table value; Black pieces subtract the mirrored-square table value.

The board update pipeline maintains White-relative incremental material plus piece-square-table state. NNUE supplies a separately trained side-to-move-relative correction.

## NNUE Correction

The NNUE uses a direct 2-side by 6-piece by 64-square encoding, for 768 inputs per perspective. Each perspective has its own-piece and opposing-piece categories, with Black squares vertically flipped into its point of view. Each perspective has 128 signed five-bit modular accumulators with signed three-bit bias; the quantization-aware forward pass uses the same modular arithmetic, while add/remove operations remain exact inverses if an extreme wraps. Feature-transformer weights use all four signed two-bit values in 256-bit ROM rows.

The update pipeline applies one physical feature change to all 128 lanes of both perspectives and can accept a new row every cycle. The output applies ReLU clipped at seven to the already biased accumulator state, concatenates the side-to-move perspective before the opposing perspective, and evaluates the 256 activations with 128 shared signed-three-bit MAC lanes over two cycles plus a signed five-bit output bias. The ordered shared head gives the same side-to-move-relative score after a board, color, and turn flip.

Final search evaluation is `side_to_move(material + PST) + NNUE correction`. Material and PST remain independently trainable and continue to be maintained incrementally.
