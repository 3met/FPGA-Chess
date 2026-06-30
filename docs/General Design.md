# General Design Principals

- The board and engine exist as an 8x8 processing element (PE) array
- The engine design attempts to beat classical CPU designs by computing move ordering and evaluation calculations in parallel for each tile. The time saved with this parallel calculation should allow for more complex move ordering and evaluation calculations without slowing down in the engine.
- 
