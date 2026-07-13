# DE1-SoC Top Level (`de1_soc`)

The `de1_soc` module is the board-specific top level for the Terasic DE1-SoC. It maps physical pins and board-specific clocking to the vendor-neutral `engine`.

## Clocking

`CLOCK_50` is the DE1-SoC's 50 MHz reference clock. The build copies the target-specific Intel PLL template at `hardware/ip/pll/`, configures its output from `synthesis_targets.quartus-de1-soc.engine_clock_mhz`, and generates the matching `ENGINE_CLOCK_FREQ` parameter for `engine`. The UART continues to use the undivided 50 MHz reference clock.

To select 20 MHz, change `hardware/build/manifest.json`'s `quartus-de1-soc.engine_clock_mhz` to `20.0` and rerun synthesis. Fractional-MHz rates such as `12.5` are supported. The source PLL template remains unchanged; the configured vendor IP and engine timing include are generated under `work/build/quartus-de1-soc/` for that build.

The core does not depend on the Intel PLL: a new board wrapper should generate its intended engine clock with its vendor's PLL/MMCM (or use a suitable board clock), connect it to `engine.clk`, and set `engine.CLOCK_FREQ` to the exact resulting frequency. Do not override the DE1-SoC clock-rate constant independently of its PLL output.

## On-Board Interface

| Resource | Required Behavior |
| -------- | ----------------- |
| Clock | Accept board reference clock and generate the engine clock through a vendor-specific PLL wrapper. |
| Reset button | `KEY[3]` controls board logic reset; UART BREAK also resets the engine and TX path. |
| PLL reset button | `KEY[2]` controls PLL reset. |
| UART GPIO | Route host RX/TX pins to `rx_decode` and `tx_encode`. |
| LEDs | `LEDR[7:0]` show the most recently received byte, `LEDR[8]` indicates any RX, remote-reset, TX-full, or engine error, and `LEDR[9]` indicates PLL unlock. |
| 7-segment displays | `HEX1:HEX0` show the most recently received byte in hexadecimal. `HEX2` shows `{engine_error, tx_full, rx_error}` and `HEX3` shows `{remote_reset, engine_ready, pll_locked}` in hexadecimal. `HEX5:HEX4` are unused. |
| Display blanking | `SW[9]` turns off all LEDs and seven-segment displays when high. |
