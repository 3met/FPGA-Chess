# Agent Notes

Documentation is under `docs/`. Start with [docs/README.md](docs/README.md), then read the specific architecture or module docs needed for the task as required.

### Development Notes

* All software should be written to run on both Windows and Linux
* All RTL should be written to synthesize for both Altera and Xilinx
* FPGA setup, initialization, and configuration times are negligible compared to search time, so prioritize minimal area
* After changes to core engine functionality, update any invalidated or out-of-date documentation
* This engine only plays standard chess games and need not support Chess960 functionality or positions unreachable in a standard chess game
* When writing chess-related RTL, consider whether any properties of the game or game rules can be exploited when assuming only legal and reachable positions
* Never add legacy support, backward compatibility, or version numbering unless instructed to
* For simple but slow non-editing tasks like synthesis, running testbenches, running the profiler, parsing large logs, etc., consider using a subagent equivalent to GPT-6 Luna medium where possible
* Not every feature requires extensive tests, so take the time to consider what tests are effective and worthwhile
* When writing tests, avoid asserting specific configuration values
* Do not create report files unless explicitly requested
* The hardware error-handling philosophy is to assume that everything works as intended and only scoped errors (like OOM) are possible and need only be detected in deployed hardware, not resolved

### Code Style

* All functions and significant RTL blocks should have a short explanatory comment
* Paragraphs in Markdown should be written as single lines
* Keep documentation concise without unnecessary details or legacy information
* Avoid writing specific configuration values in the docs unless they are useful for understanding key design choices
