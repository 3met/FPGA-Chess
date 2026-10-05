# DE1-SoC Top Level (`de1_soc`)

The `de1_soc` module is the board-specific top level for the Terasic DE1-SoC. It connects physical clocks, reset controls, UART, SDR SDRAM, and diagnostics to the vendor-neutral engine and portable memory controller.

## External Memory

The DE1 build uses the FPGA-side 64 MiB SDR SDRAM as the primary transposition-table store. The portable controller performs JEDEC initialization, validity initialization, open-row burst access, and refresh before reporting memory ready. The engine remains in reset until the memory path is initialized.

Memory readiness and transactions are described in [tt-memory.md](tt-memory.md) and [sdr-sdram-controller.md](sdr-sdram-controller.md).

## Clocking and Reset

`CLOCK_50` is the board reference clock. The synthesis flow configures independent Intel engine, memory, and communication PLLs and generates matching clock metadata. The cache and search use the engine clock; the memory interface uses the board-configured approximately 133.333333 MHz memory clock (a 7.5 ns period), and UART uses its own 100 MHz communication clock. The memory PLL also supplies a phase-adjusted SDRAM output clock; a dedicated DDR output register forwards its inverted waveform to the chip, and IO input registers capture on the source clock’s rising edge. Sharing that clock source reduces variation between forwarded and capture timing. Frequency, phase, and duty-cycle settings live in the DE1-SoC target's `clock_generator` configuration in the build manifest; the SDRAM wrapper supplies the matching CAS and capture-pipeline settings.

A startup controller holds the design in reset until all PLLs are stable and restarts it if any lock is lost. Each clock domain releases reset locally. UART BREAK resets the engine, memory path, and transmitter so the board can recover without a physical reset; UART framing and overflow errors hold the engine inactive until the next BREAK.

Clock generation and device-specific constraints remain confined to this wrapper. A new board wrapper may use another vendor's PLL/MMCM or a suitable board clock, but it must set `engine.CLOCK_FREQ` to the frequency actually driven on `engine.clk`.

The SDRAM geometry and timing follow the [Intel DE1-SoC SDRAM tutorial](https://ftp.intel.com/Public/Pub/fpgaup/pub/Teaching_Materials/current/Tutorials/VHDL/DE1-SoC/Using_the_SDRAM.pdf) and [ISSI IS42S16320D datasheet](https://www.issi.com/WW/pdf/42-45R-S_86400D-16320D-32160D.pdf).

## Board Interface

| Resource | Role |
| -------- | ---- |
| `CLOCK_50` | Reference for board-specific clock generation. |
| `KEY` | Physical reset and PLL-restart controls. |
| [UART GPIO](../usage/de1-soc-uci.md#hardware-connection) | Host RX/TX connection through `rx_decode` and `tx_encode`. |
| `DRAM_*` | External transposition-table memory interface. |
| LEDs and seven-segment displays | Optional visibility into traffic, readiness, errors, and PLL status. |
| `SW[9]` | Blanks the diagnostic displays. |
