# DE1-SoC Top Level (`de1_soc`)

The `de1_soc` module is the board-specific top level for the Terasic DE1-SoC. It connects physical clocks, reset controls, UART, SDR SDRAM, and diagnostics to the vendor-neutral engine and portable memory controller.

## External Memory

The DE1 build uses the FPGA-side 64 MiB SDR SDRAM as the primary transposition-table store. The portable controller performs JEDEC initialization, validity initialization, open-row burst access, and refresh before reporting memory ready. The engine remains in reset until the memory path is initialized.

The controller's simulator-only initialization shortcut must not be enabled in hardware builds. Runtime TT behavior and the memory protocol are described in [tt-memory.md](tt-memory.md) and [sdr-sdram-controller.md](sdr-sdram-controller.md).

## Clocking and Reset

`CLOCK_50` is the board reference clock. The synthesis flow configures board-specific Intel PLL IP from the target's engine-clock setting and generates matching `ENGINE_CLOCK_FREQ` and `FPGA_BUILD_ID` constants. The PLL also supplies the SDRAM and UART clock domains and the phase relationships required by SDRAM I/O timing. The 100 MHz SDRAM pin clock leads the controller clock by 2.5 ns, a phase supported by the PLL divider settings used for the 75 MHz engine clock.

A startup controller holds the design in reset until the PLL is stable and retries if lock is lost. It reuses one maximal-length LFSR period for reset hold, lock timeout, and lock verification, trading irrelevant startup latency for a shift/XOR path instead of arithmetic counters. Each clock domain releases reset through a two-flop local synchronizer. UART BREAK holds the engine, memory path, and transmitter in reset until BREAK release so the board can recover remotely without a physical reset. A UART framing error or RX overflow fails closed until the next BREAK.

Clock generation and device-specific constraints remain confined to this wrapper. A new board wrapper may use another vendor's PLL/MMCM or a suitable board clock, but it must set `engine.CLOCK_FREQ` to the frequency actually driven on `engine.clk`.

The SDRAM geometry and timing follow the [Intel DE1-SoC SDRAM tutorial](https://ftp.intel.com/Public/Pub/fpgaup/pub/Teaching_Materials/current/Tutorials/VHDL/DE1-SoC/Using_the_SDRAM.pdf) and [ISSI IS42S16320D datasheet](https://www.issi.com/WW/pdf/42-45R-S_86400D-16320D-32160D.pdf).

## Board Interface

| Resource | Role |
| -------- | ---- |
| `CLOCK_50` | Reference for board-specific clock generation. |
| `KEY` | Physical reset and PLL-restart controls. |
| UART GPIO | Host RX/TX connection through `rx_decode` and `tx_encode`. |
| `DRAM_*` | External transposition-table memory interface. |
| LEDs and seven-segment displays | Optional visibility into traffic, readiness, errors, and PLL status. |
| `SW[9]` | Blanks the diagnostic displays. |
