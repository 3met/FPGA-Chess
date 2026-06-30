
Issue: lack of hash-table has a large effect
Issue: how to deal with generated illegal moves

A pipelined systolic-array type computation. A basic design would have:
- A stack of 7 layers each with an 8x8 grid of PEs
- Would allow up to 7 evaluations in-flight at a time
- Each tile layer of processing elements would pass information directly to the 

In the systolic evaluator, do we really need to track exact distance? Or is it sufficient to know that the distant is at least 2?

Idea: Add a quick way to check if a PV/Hash/Killer/etc move is valid rather than going through the move generator

Big Idea: worry less about primary thread performance and focus on maximizing pipeline parallelism with a Lazy SMP management of parallel evaluations.

Idea: For Zobrist hashing, instead of storing full hash, store

Idea: Store previously searched moves in a layered format with the first cycle in the pipeline reading which chunks have have non-uniform masks 


```
global nodeCount ← 0
global TT ← empty transposition table

function ITERATIVE_DEEPENING(rootPos, MaxDepth):
    bestMove ← null
    for depth from 1 to MaxDepth:
        α ← –∞
        β ← +∞
        (score, pv) ← ALPHA_BETA(rootPos, depth, α, β)
        bestMove ← pv[0]         // first move of the returned PV
    return bestMove


function ALPHA_BETA(pos, depth, α, β):
    nodeCount ← nodeCount + 1

    // 1) TT lookup
    entry ← TT_LOOKUP(pos.hash, depth, α, β)
    if entry.hit:
        return (entry.score, entry.bestMove, entry.pv)

    if depth == 0:
        return QSEARCH(pos, α, β)

    bestMove ← null
    bestPV   ← []
    moves ← pos.generateLegalMoves()
    ORDER_MOVES(moves)

    for move in moves:
        pos.makeMove(move)
        (score, subPV) ← ALPHA_BETA(pos, depth–1, –β, –α)
        pos.unmakeMove(move)

        score ← –score
        if score ≥ β:
            // β-cutoff: store lower bound
            TT_STORE(pos.hash, depth, LOWERBOUND, β, move, [move] + subPV)
            return (β, [move]) 
        if score > α:
            α ← score
            bestMove ← move
            bestPV   ← [move] + subPV

    // store exact score
    TT_STORE(pos.hash, depth, EXACT, α, bestMove, bestPV)
    return (α, bestPV)


function QSEARCH(pos, α, β):
    nodeCount ← nodeCount + 1
    standPat ← EVALUATE(pos)
    if standPat ≥ β:
        return (β, [])       // cutoff on stand-pat
    if α < standPat:
        α ← standPat

    captures ← pos.generateCaptures()
    ORDER_CAPTURES(captures)

    for move in captures:
        pos.makeMove(move)
        score ← –QSEARCH(pos, –β, –α).score
        pos.unmakeMove(move)

        if score ≥ β:
            return (β, [])   // no need to store captures in PV here
        if score > α:
            α ← score

    return (α, [])

```

**Pipelines**
- Evaluate
	- Input board position, piece-square eval
	- Output: evaluation
- Move Generation
	- Input: board position, target move
	- Output: move
- Make/Reverse Move
	- Input: board position, target move
	- Output: board
- Load TT
	- Input: board hash
	- Output: board hash, evaluation
- Store TT
	- Input: board hash, evaluation
	- Output: N/A


