
create_clock -name CLOCK_50 -period 20 [get_ports CLOCK_50]
derive_pll_clocks -create

# UART traffic and TT memory requests cross the engine boundary through
# synchronizers or asynchronous FIFOs. Their source clocks are intentionally
# asynchronous to the configurable engine PLL output; the SDRAM clocks remain
# related to each other so controller and pin timing is still checked.
set engine_clock [get_clocks {*general[0].gpll*PLL_OUTPUT_COUNTER*divclk}]
set memory_clock [get_clocks {*general[1].gpll*PLL_OUTPUT_COUNTER*divclk}]
if {[get_collection_size $engine_clock] > 0} {
    set_clock_groups -asynchronous -group $engine_clock -group [get_clocks CLOCK_50]
    if {[get_collection_size $memory_clock] > 0} {
        set_clock_groups -asynchronous -group $engine_clock -group $memory_clock
    }
}

# The DE1 SDRAM samples commands and write data on the phase-shifted memory
# clock. The pin clock leads the controller by 3 ns, while the read register
# captures 8 ns after the SDRAM edge. These values cover the SDRAM setup/hold
# requirements and retain board-routing margin.
set sdram_clock_source [get_pins {pll_1|pll_ip_inst|altera_pll_i|outclk_wire[2]~CLKENA0|outclk}]
if {[get_collection_size $sdram_clock_source] > 0} {
    create_generated_clock -name SDRAM_PIN_CLK -source $sdram_clock_source -divide_by 1 [get_ports DRAM_CLK]
}
set sdram_clock [get_clocks SDRAM_PIN_CLK]
if {[get_collection_size $sdram_clock] > 0} {
    set sdram_outputs [get_ports {DRAM_ADDR[*] DRAM_BA[*] DRAM_CAS_N DRAM_CKE DRAM_CS_N DRAM_LDQM DRAM_RAS_N DRAM_UDQM DRAM_WE_N}]
    set_output_delay -clock $sdram_clock -max 1.5 $sdram_outputs
    set_output_delay -clock $sdram_clock -min -0.8 $sdram_outputs
    set_output_delay -clock $sdram_clock -max 1.5 [get_ports {DRAM_DQ[*]}]
    set_output_delay -clock $sdram_clock -min -0.8 [get_ports {DRAM_DQ[*]}]
    set_input_delay -clock $sdram_clock -max 6.0 [get_ports {DRAM_DQ[*]}]
    set_input_delay -clock $sdram_clock -min 2.0 [get_ports {DRAM_DQ[*]}]
    set sdram_capture_regs [get_registers {*dq_read_capture*}]
    set_multicycle_path -setup 2 -from [get_ports {DRAM_DQ[*]}] -to $sdram_capture_regs
    set_multicycle_path -hold 1 -from [get_ports {DRAM_DQ[*]}] -to $sdram_capture_regs
}

# These board-facing signals communicate with people or an asynchronous UART,
# not a source-synchronous device. They are either synchronized internally or
# only affect displays, so no external setup/hold relationship exists to time.
set_false_path -from [get_ports {GPIO_0[9] KEY[2] KEY[3] SW[9]}]
set_false_path -to [get_ports {GPIO_0[7] HEX0[*] HEX1[*] HEX2[*] HEX3[*] HEX4[*] HEX5[*] LEDR[*]}]
