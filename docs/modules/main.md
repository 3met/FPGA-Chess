# Main (`main`)

Status: board-wrapper final RTL spec.

The `main` module maps board-level FPGA pins to the vendor-neutral engine design and board-specific wrappers.

## On-Board Interface

| Resource | Required Behavior |
| -------- | ----------------- |
| Clock | Accept board reference clock and generate the engine clock through a vendor-specific PLL wrapper. |
| Reset button | `KEY[3]` controls engine reset. |
| PLL reset button | `KEY[2]` controls PLL reset. |
| UART GPIO | Route host RX/TX pins to `rx_decode` and `tx_encode`. |
| LEDs | Expose basic status such as PLL lock, reset, RX/TX activity, search active, and error state. |
| 7-segment displays | Optional debug display for board state, status, or recent UART data. |
| Switches | Optional debug controls, such as enabling status LEDs or selecting display mode. |

## Current RTL Notes

The current RTL maps PLL lock and recent RX byte status to LEDs and loops received UART bytes into the UART transmitter. The final design should instantiate the engine command layer between RX and TX.
