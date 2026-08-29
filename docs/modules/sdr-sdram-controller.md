# SDR SDRAM Controller (`sdr_sdram_controller`)

The SDR SDRAM controller adapts the vendor-neutral 16-bit burst protocol in [tt-memory.md](tt-memory.md) to a JEDEC single-data-rate SDRAM device. It contains no chess or transposition-table policy; entry layout and table indexing belong to the TT frontend.

## Configuration

The controller is parameterized by clock frequency, accessible entry count, TT words per entry, and CAS latency. JEDEC timing intervals are converted to conservative integer clock counts from the configured frequency.

The physical interface uses a 16-bit data bus, four banks, 13 row-address bits, and the standard SDR SDRAM command and byte-mask signals. A board wrapper supplies the memory clocking and pin assignments.

## Initialization and Refresh

After reset, the controller observes the power-up delay, precharges all banks, performs the required refresh commands, programs sequential full-page burst mode and the configured CAS latency, and initializes TT validity storage before asserting `ready`.

Refresh is scheduled early enough to allow precharge and command latency without exceeding the device refresh interval. New requests are held off when refresh is due. Refresh closes all tracked open rows.

Initialization and refresh timing are properties of the memory device and controller clock, not of a particular FPGA vendor.

## Transactions

The controller accepts one transaction at a time. Addresses and lengths are expressed in 16-bit words, and a transaction contains between one word and one physical TT entry.

For writes, the controller buffers the complete transaction before issuing the SDRAM WRITE command because the physical burst cannot be stalled. For reads, it captures the complete physical burst before exposing words on the backpressured read-data channel.

Transactions crossing a row boundary are divided into legal physical segments while remaining one logical request. The controller tracks and reuses open rows, precharging and activating banks as required. Reads may retain their row for a conditional TT replacement, while idle banks may be closed between requests.

Every accepted request terminates with one completion. Invalid lengths, malformed write termination, or memory-controller faults set the persistent error output and mark the completion as failed.

## Clocking Boundary

Command and write outputs are registered in the controller clock domain. Read data may be sampled with a phase-adjusted capture clock supplied by the board wrapper, but all protocol-visible state remains synchronous to the controller clock.

Clock generation is outside this module. Intel PLLs, Xilinx MMCMs, and board-specific phase constraints must remain isolated in platform wrappers.
