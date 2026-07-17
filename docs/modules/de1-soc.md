# DE1-SoC Top Level (`de1_soc`)

The `de1_soc` module is the board-specific top level for the Terasic DE1-SoC. It maps physical pins and board-specific clocking to the vendor-neutral `engine`.

The DE1 build uses the FPGA-side 64 MiB, 32M-by-16 SDR SDRAM as the backing store for the transposition table. A portable controller performs JEDEC initialization, a serial validity-word sweep, open-row burst accesses, and distributed refresh. Runtime writes are fully staged before the physical WRITE command so upstream ready/valid gaps cannot interrupt the SDRAM's mandatory consecutive data beats. The engine remains in reset until memory initialization completes.

The DE1 wrapper enables search statistics by default through `ENABLE_SEARCH_STATS = 1`; override the wrapper parameter with zero to synthesize them out. The generic engine and search-controller modules remain default-off.

## Clocking

`CLOCK_50` is the DE1-SoC's 50 MHz reference clock. The build copies the target-specific Intel PLL template at `hardware/ip/pll/`, configures its output from `synthesis_targets.quartus-de1-soc.engine_clock_mhz`, and generates the matching `ENGINE_CLOCK_FREQ` parameter for `engine`. The DE1 target uses a 25 MHz engine clock. The UART continues to use the undivided 50 MHz reference clock.

The same PLL produces a 100 MHz SDRAM-controller clock and a phase-adjusted 100 MHz `DRAM_CLK`. The TT path crosses between the engine and memory domains through shallow asynchronous FIFOs sized for their traffic: four commands, four write words, eight read words, and two completions. The read FIFO can hold a complete six-word burst because physical SDR SDRAM bursts cannot be paused. The board SDC declares the engine-to-memory and engine-to-UART synchronizer boundaries asynchronous while retaining timing between the related SDRAM clocks. These clocks are confined to the DE1 wrapper so another FPGA family can provide equivalents with its PLL or MMCM.

To select another legal PLL rate, change `hardware/build/manifest.json`'s `quartus-de1-soc.engine_clock_mhz` and rerun synthesis. The integer-N PLL accepts only rates its VCO and output counters can realize; Quartus rejects unsupported values. The source PLL template remains unchanged; the configured vendor IP and engine timing include are generated under `work/build/quartus-de1-soc/` for that build.

The core does not depend on the Intel PLL: a new board wrapper should generate its intended engine clock with its vendor's PLL/MMCM (or use a suitable board clock), connect it to `engine.clk`, and set `engine.CLOCK_FREQ` to the exact resulting frequency. Do not override the DE1-SoC clock-rate constant independently of its PLL output.

## On-Board Interface

| Resource | Required Behavior |
| -------- | ----------------- |
| Clock | Accept board reference clock and generate the engine clock through a vendor-specific PLL wrapper. |
| Reset button | `KEY[3]` controls board logic reset; UART BREAK also resets the engine and TX path. |
| PLL reset button | `KEY[2]` controls PLL reset. |
| UART GPIO | Route host RX/TX pins to `rx_decode` and `tx_encode`. |
| FPGA SDRAM | Route `DRAM_*` to the portable SDR SDRAM controller for the off-chip TT. |
| LEDs | `LEDR[7:0]` show the most recently received byte, `LEDR[8]` indicates any RX, remote-reset, TX-full, or engine error, and `LEDR[9]` indicates PLL unlock. |
| 7-segment displays | `HEX1:HEX0` show the most recently received byte in hexadecimal. `HEX2` shows `{engine_error, tx_full, rx_error}` and `HEX3` shows `{remote_reset, engine_ready, pll_locked}` in hexadecimal. `HEX5:HEX4` show a wrapping count of engine response bytes accepted by the UART TX path. |
| Display blanking | `SW[9]` turns off all LEDs and seven-segment displays when high. |
