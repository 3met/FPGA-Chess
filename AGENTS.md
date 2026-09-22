# Agent Notes

Relevant docs are under `docs/`. Start with [docs/README.md](docs/README.md), then read the specific architecture or module docs needed for the task as required.

### Development Notes

* All software should be written such that it can be run on both Windows and Linux
* All RTL should be written such that it synthesizes for both Altera and Xilinx
* FPGA setup, startup, and configuration time are irrelevantly small compared to search time, so minimize area here where possible even if it comes at the cost of slower operations
* After changes to primary engine functionality, correct any invalidated or out of date documentation
* This engine only plays standard chess games and does not need to support chess-960 type functionality or any positions that would not be reachable in a standard chess game
* When writing any chess-related RTL, consider if any properties of the game or game rules can be taken advantage of
* Do not ever add legacy support, backwards compatibility, or version numbering unless instructed to
* For simple but slow non-editing tasks like synthesis, running testbenches, running the profiler, parsing massive logs, etc., consider using a subagent equivalent to GPT 6 Luna medium where possible
* When writing tests, avoid asserting a specific configuration value

### Code Style

* All added functions or significant blocks of RTL should have a short explanatory comment
* Paragraphs in Markdown should be written as single lines
* Keep documentation concise without irrelevant details or legacy information
* Avoid writing specific configuration values in the docs unless they are very important
