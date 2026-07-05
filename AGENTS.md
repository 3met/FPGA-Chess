# Agent Notes

Relevant docs are under `docs/`. Start with [docs/README.md](docs/README.md), then read the specific architecture or module docs needed for the task.

### Development Notes

* All software should be written such that it can be run on both Windows and Linux
* All RTL should be written such that it synthesizes for both Altera and Xilinx
* FPGA setup, startup, and configuration time is irrelevantly small compared to search time, so minimize area where possible and reasonable here
* After any RTL changes, correct any docs if they are now invalid or out of date
* This engine is only plays standard chess games and does not need to support chess-960 type functionality or any positions that would not be possible in a standard chess game
* When writing any chess-related RTL, consider if any properties of the game or game rules can be taken advantage of

### Code Style

* Paragraphs in Markdown should be written as single lines
