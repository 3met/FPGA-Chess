# SDR SDRAM Controller (`sdr_sdram_controller`)

The SDR SDRAM controller adapts the vendor-neutral 16-bit burst protocol in [tt-memory.md](tt-memory.md) to a JEDEC single-data-rate SDRAM device. It contains no chess or transposition-table policy; entry layout and table indexing belong to the TT frontend.

## Configuration

The controller is parameterized by clock frequency, accessible entry count, maximum burst words per three-way entry, validity-sweep stride/offset, CAS latency of two or three cycles, capture edge, and read-pipeline latency appropriate to the board clock routing. The mode register and read timing use the same CAS setting. JEDEC timing intervals are converted to conservative integer clock counts from the configured frequency.

The physical interface uses a 16-bit data bus, four banks, 13 row-address bits, and the standard SDR SDRAM command and byte-mask signals. A board wrapper supplies the memory clocking and pin assignments.

## Initialization and Refresh

After reset, the controller observes the power-up delay, precharges all banks, performs the required refresh commands, programs sequential full-page burst mode and the configured CAS latency, and initializes TT validity storage before asserting `ready`. The board supplies one-way sweep spacing and the validity-word offset so all three ways are invalidated without clearing their payloads.

Refresh is scheduled early enough to allow precharge and command latency without exceeding the device refresh interval. New requests are held off when refresh is due; a stalled write collection, read response, or completion also yields the command bus to refresh. Read and completion responses remain valid while refresh runs. Refresh closes all tracked open rows.

Initialization and refresh timing are properties of the memory device and controller clock, not of a particular FPGA vendor.

## Transactions

The controller accepts one transaction at a time. Addresses and lengths are expressed in 16-bit words, and a transaction contains between one word and one physical TT entry.

For writes, the controller buffers the complete transaction before issuing the SDRAM WRITE command because the physical burst cannot be stalled. For reads, captured words become available while the physical burst continues. The buffer can hold the complete transaction if the receiver stalls, and completion follows burst termination and delivery of every word.

Transactions crossing a row boundary are divided into legal physical segments while remaining one logical request. Per-bank minimum-active-time and write-recovery counters prevent short segments from precharging too early at faster clocks.

Runtime accesses use a closed-row policy: each physical read or write segment ends with burst termination and explicit bank precharge as soon as minimum active time and write recovery permit. Queued requests do not suppress closing, and there is no post-write grace period. Captured read words continue draining during precharge; terminal completion may release the scheduler to deliver buffered responses before precharge recovery finishes, but the controller accepts the next transaction only after the bank has closed. Initialization reuses rows during its serial validity sweep, then closes all banks before runtime requests begin.

Every accepted request terminates with one completion. Invalid lengths, malformed write termination, set the persistent error output and mark the completion as failed.

## Clocking Boundary

Command and write outputs are registered in the controller clock domain. Read data may be sampled with a phase-adjusted capture clock supplied by the board wrapper, then transferred through a controller-clock register before entering the burst buffer. The read timer accounts for this pipeline and the device starting to drive data after the READ command edge plus CAS latency minus one; all protocol-visible state remains synchronous to the controller clock.

Clock generation is outside this module. Intel PLLs, Xilinx MMCMs, and board-specific phase constraints must remain isolated in platform wrappers.
