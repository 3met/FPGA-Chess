# Static Evaluation Design

## Score Convention

Incremental material plus PST evaluation is White-relative: positive scores favor White and negative scores favor Black. Search converts it to side-to-move point of view before adding the side-to-move-relative NNUE correction.

## Material Valuation

Material values are maintained incrementally in units of 1/128 pawn. The canonical material and piece-square parameters are generated from the evaluation-parameter JSON.

## Piece-Square Tables

Piece-square-table scoring is White-relative. White pieces add their table value; Black pieces subtract the mirrored-square table value.

The board update pipeline updates material, PST state, and total occupied-piece count together with every board operation.

## NNUE Correction

The NNUE uses direct piece-square features for White and Black perspectives. Black squares are vertically flipped into its point of view, and each perspective distinguishes friendly from opposing pieces. Incremental add/remove updates preserve one accumulator per search thread.

The output orders the side-to-move perspective before the opposing perspective and produces a side-to-move-relative correction. The incrementally tracked piece count selects one of sixteen two-piece phase buckets without scanning the board. Model widths, packing, update behavior, and generated files are defined in [nnue-evaluator.md](../modules/nnue-evaluator.md).

Final search evaluation is `side_to_move(material + PST) + NNUE correction`. Material and PST remain independently trainable and continue to be maintained incrementally.
