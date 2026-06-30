# Laptop-FPGA Communication

---
### Engine Communication Protocol

The engine receives inputs and sends outputs 1 byte at a time.

Input to Engine:
- Every input starts with an op-code for a certain operation
- For every operation, there is a pre-determined number of data bytes to follow
- Input operation or data is only considered valid if `data_in_valid` is asserted
	- If not asserted, after an operation ends, engine goes into an idle state
	- If not asserted mid-operation while engine expects input data, engine is to pause until asserted

Output from Engine:
- Engine output is only considered valid if 
- Every output starts with

---
### UART Communication Protocol

Data is sent from the laptop to the FPGA via UART over USB.

UART Config:
- 8 data bits
- no parity
- 1 stop bit

---
### Communication Scenarios 

**UART input continues despite buffer being full**
- Laptop is responsible for ensuring no commands are sent if FIFO might be full
- If FIFO is full, extra UART input is disregarded
- `kill` and `remote_reset` operations is are exception to this and are always run

**UART output buffer is full, but the engine has more output**
- Output buffer should assert that it is full
- Engine should pause output until `ready_for_result` is asserted again

**Engine is ready for next operation, but next operation's data is only half transmitted**
- The engine will begin processing the next operation and will stall when further data is required


Every data input should output a ready signal
Every data output shout output a data-valid signal

****

| Name       | Size (Bytes) | Description |
| ---------- | ------------ | ----------- |
|            |              |             |
| Request ID |              |             |
| Checksum   |              |             |

---

**Laptop -> Engine**
- See [[Engine FSM]] for list of engine commands
- Ask for status of engine
- Hard reset signal
- Prompt new game (reset board, clear memory and heuristics as needed)
- Set board position from encoding
- Execute list of moves
- Undo last move (?)
- Execute operation (expects a response on completion)
	- `SearchOnClock(clock data)`
	- `SearchDepth(depth=10)`
	- `Perft()`


**Engine -> Laptop**
* Send engine status
* Send best move
* Send board evaluation
* Report error (?)

