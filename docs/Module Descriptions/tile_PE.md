### Tile Module Ports

List of ports for each tile module.

- Inputs with value shared by all tiles
	- clock
	- active-low reset
	- current search depth
	- tile write data
	- tile instruction
		- idle
		- disable attacker (should be tile level instruction to deal with special cases)
		- reset current attacker mask
- Inputs with value unique to tile
	- tile select 1
	- tile select 2
- Outputs to parent board
	- tile occupant
	- is illegal king attack
	- move priority
	- move direction
	- move distance (distance=0 for knights, distance>=1 for adjacent pieces)
- Inter-tile Connections
	- adjacent connections (to propagate data)
		- piece type + color data
		- distance
		- piece behind (add later on)

	- knight connections
		- piece color
		- has knight
		- has king or major

### Tile-Level Operations

List of operations on the individual tile level.

| Operation                           | Usage                                                                    | SEL_1            | SEL_2 |
| ----------------------------------- | ------------------------------------------------------------------------ | ---------------- | ----- |
| Idle                                | Tile should do nothing                                                   |                  |       |
| Place                               | Simply places a piece<br><br>Can replace captured piece on move reversal | Place            |       |
| Place + add mask and Clear          | Used for making a normal move                                            | Place + add mask | Clear |
| Place and Clear                     | Places a piece on one tile and clears another                            | Place            | Clear |
| Place + global reset mask and Clear | Used to undo non-capture moves                                           | Place            | Clear |
| Output Score                        | Outputs score to mixed arbiter/adder                                     |                  |       |
| Output Best Move                    | Outputs score to mixed arbiter/adder                                     |                  |       |
