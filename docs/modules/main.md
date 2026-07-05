# Main (`main`)

Status: board-wrapper final RTL spec.

The `main` module maps board-level FPGA pins to the vendor-neutral engine design and board-specific wrappers.

## On-Board Interface

| Resource | Required Behavior |
| -------- | ----------------- |
| Clock | Accept board reference clock and generate the engine clock through a vendor-specific PLL wrapper. |
| Reset button | `KEY[3]` controls board logic reset; UART BREAK also resets the engine-side command/output path. |
| PLL reset button | `KEY[2]` controls PLL reset. |
| UART GPIO | Route host RX/TX pins to `rx_decode` and `tx_encode`. |
| LEDs | Expose basic status such as PLL lock, reset, RX/TX activity, search active, and error state. |
| 7-segment displays | Optional debug display for board state, status, or recent UART data. |
| Switches | Optional debug controls, such as enabling status LEDs or selecting display mode. |

## Current RTL Notes

The current RTL maps PLL lock, recent RX byte status, and RX/TX/engine error status to LEDs. UART bytes flow through `rx_decode`, the V1 `engine` command layer, and `tx_encode` using a 50 MHz UART clock and PLL-derived engine clock.

`rx_decode` receives the raw button reset so it can detect UART BREAK and emit `remote_reset`. The engine, real search controller, and TX path use `KEY[3]` combined with `remote_reset`, so BREAK clears latched engine/output/search state as an out-of-band reset.

The board wrapper instantiates the real `search_controller` behind the engine's typed controller boundary. The older `search_controller_stub` remains as a lightweight protocol mock for focused tests or temporary experiments only.
