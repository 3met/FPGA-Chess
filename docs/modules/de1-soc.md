# DE1-SoC Top Level (`de1_soc`)

The `de1_soc` module is the board-specific top level for the Terasic DE1-SoC. It maps physical pins and board-specific clocking to the vendor-neutral `engine`.

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
