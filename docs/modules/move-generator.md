# Move Generator (`move_generator`)

Status: partially implemented; this document describes the final target contract.

The move generator accepts a legal input position and emits one ordered candidate move per dispatch. It also reports whether the candidate is strictly legal. A candidate is consumed for the current node whether or not it is legal.

## Ports

| Direction | Port Name | Description |
| --------- | --------- | ----------- |
| Input | `clk` | Clock. |
| Input | `rst_n` | Synchronous active-low reset. |
| Input | `move_gen_op` | Move-generation operation. |
| Input | `thread_id` | Thread whose per-node searched-move mask should be read or written. |
| Input | `ply` | Current search ply. |
| Input | `board_tiles` | 64 x 4-bit tiles. |
| Input | `turn` | Side to move. |
| Input | `castle_perms` | Castling permissions. |
| Input | `has_ep` | Whether the position has an en passant target. |
| Input | `ep_file` | En passant file if `has_ep` is asserted. |
| Input | `target_move` | Move that should receive highest priority if legal and unsearched. |
| Output | `candidate_move` | Next ordered candidate move, or `NULL_MOVE` if no remaining candidate exists. |
| Output | `move_is_legal` | Asserted when `candidate_move` is strictly legal. If deasserted, the candidate is still consumed. |

## Operations

| Operation | Inputs Required | Description |
| --------- | --------------- | ----------- |
| Idle | None | Does not update internal move masks. |
| Normal Generation | None | Generates the next ordered candidate move. |
| Targeted Generation | `target_move` | Returns `target_move` if legal and unsearched; otherwise returns the next ordered candidate. |
| QSearch Generation | None | Generates the next quiescence-search candidate, limited to captures and promotions. Checking non-captures are not generated for qsearch. |

## Pipeline

| Pipeline Stage | Description |
| -------------- | ----------- |
| 0 | Register inputs and begin loading searched-move mask data. |
| 1 | Propagate state and update previous-ply tracking. |
| 2 | Propagate state. |
| 3 | Propagate pieces and begin valid-move chunk loading. |
| 4-5 | Propagate state. |
| 6 | Finish propagation, register valid move mask, and compute target-move direction/distance. |
| 7 | Compute the best candidate on a per-tile basis and identify pinned-piece axes. |
| 8 | Promote target-move score to maximum if legal and unsearched. |
| 9 | Compute the best candidate across the board. |
| 10 | Check strict legality, output the candidate move, and update/save searched-move mask. |

## Ordered Move Generation

The intended ordering architecture scores candidate destination tiles, then selects the best board-wide candidate. Each tile has information about the closest piece in each cardinal, diagonal, and knight direction. Candidate scores may use material trades, attacker/defender counts, target-piece value, target-square flags, and TT/root move hints.

Targeted Generation supports TT move ordering and root move forcing. If the target move is legal and unsearched, it must outrank all other candidates for that dispatch.

Promotion ordering should prioritize queen promotions first. Underpromotion policy is part of the qsearch/search design and should be explicit before integration.

## Move Mask Memory

Each generated candidate must be marked as searched for the current `thread_id` and `ply`, even when `move_is_legal` is false. This prevents repeated emission of the same illegal pseudo-move.

The searched-move mask may be stored as compressed direction/category chunks. The logical behavior is a per-node set of consumed candidate moves; the physical mask-memory layout can be optimized for BRAM shape as long as it preserves that behavior.

If `ply` moves backward or remains the same, stale deeper-ply masks must not affect the current node. If `ply` advances by one, the new ply starts with a fresh searched-move mask.

## Legality Filtering

The input position is assumed legal. The move generator is responsible for rejecting generated candidates that would leave the side to move in check.

Legality filtering must cover:

| Case | Required Behavior |
| ---- | ----------------- |
| Pinned piece | A pinned piece may move only along the pin line when that preserves king safety. |
| King move | A king may not move to an attacked square. |
| Check | If in check, non-king moves must capture the checker, block the checking line, or otherwise remove the check. |
| Double check | Only king moves can be legal. |
| En passant | En passant must reject discovered checks created by removing the captured pawn. |
| Castling | Castling requires clear path squares, castling permission, king not currently in check, and king transit/destination squares not attacked. |

The board update pipeline should not select replacement moves after an illegal candidate is rejected; the search controller should dispatch move generation again.

## Current RTL Notes

The current RTL contains the beginning of the propagation pipeline and mask-memory structure, but output selection and strict legality are incomplete.
