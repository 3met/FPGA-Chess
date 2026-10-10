
# Reference clock is generated from the board target before this file is read.
derive_pll_clocks -create

# UART traffic and TT memory requests cross the engine boundary through
# synchronizers or asynchronous FIFOs. Their source clocks are intentionally
# asynchronous to the configurable engine PLL output; the SDRAM clocks remain
# related to each other so controller and pin timing is still checked.
set engine_clock [get_clocks {*altera_pll_i*general[0].gpll*PLL_OUTPUT_COUNTER*divclk}]
set communication_clock [get_clocks {*communication_pll_i*general[0].gpll*PLL_OUTPUT_COUNTER*divclk}]
set memory_clock [get_clocks {*memory_pll_i*general[0].gpll*PLL_OUTPUT_COUNTER*divclk}]
# Startup logic asserts resets asynchronously; reset_release synchronizes their
# deassertion in the destination domain.
if {[get_collection_size $memory_clock] > 0} {
    set_clock_groups -asynchronous -group [get_clocks CLOCK_50] -group $memory_clock
}
if {[get_collection_size $engine_clock] > 0} {
    set_clock_groups -asynchronous -group $engine_clock -group [get_clocks CLOCK_50]
    if {[get_collection_size $memory_clock] > 0} {
        set_clock_groups -asynchronous -group $engine_clock -group $memory_clock
    }
}

if {[get_collection_size $communication_clock] > 0} {
    set_clock_groups -asynchronous -group $communication_clock -group [get_clocks CLOCK_50] -group $engine_clock -group $memory_clock
}

# Bound each Gray bus separately, including paths cut by asynchronous clock
# groups. Bounding every bit below a source period also bounds bus skew.
set fifo_prefixes {}
foreach_in_collection fifo_reg [get_registers -no_duplicates {*|wr_gray[*]}] {
    set fifo_name [get_object_info -name $fifo_reg]
    if {[regexp {^(.*)\|wr_gray\[[0-9]+\]$} $fifo_name unused fifo_prefix]} {
        lappend fifo_prefixes $fifo_prefix
    }
}
set fifo_prefixes [lsort -unique $fifo_prefixes]
if {[llength $fifo_prefixes] == 0} {
    error "No async_fifo Gray-pointer registers found for CDC constraints"
}
foreach fifo_prefix $fifo_prefixes {
    foreach {source_name destination_name} {
        wr_gray wr_gray_rdclk_meta
        rd_gray rd_gray_wrclk_meta
    } {
        set fifo_source [get_registers -nowarn [format {%s|%s[*]} $fifo_prefix $source_name]]
        set fifo_destination [get_registers -nowarn [format {%s|%s[*]} $fifo_prefix $destination_name]]
        if {[get_collection_size $fifo_source] == 0 || [get_collection_size $fifo_destination] == 0} {
            error "Missing Gray-pointer CDC registers in $fifo_prefix"
        }
        set_net_delay -from $fifo_source -to $fifo_destination -max -get_value_from_clock_period src_clock_period -value_multiplier 0.8
    }
}

# The DE1 SDRAM samples commands and write data on the phase-shifted memory
# clock. Engine-profile PLL phases place the read sample inside the SDRAM
# data-valid window. These values cover the SDRAM setup/hold
# requirements and retain board-routing margin.
set sdram_clock_source [get_pins {pll_1|pll_ip_inst|memory_pll_i|general[1].gpll~PLL_OUTPUT_COUNTER|divclk}]
if {[get_collection_size $sdram_clock_source] != 1} {
    error "Missing SDRAM forwarded-clock PLL counter"
}
create_generated_clock -name SDRAM_PIN_CLK -source $sdram_clock_source -divide_by 1 -invert [get_ports DRAM_CLK]
set sdram_clock [get_clocks SDRAM_PIN_CLK]
if {[get_collection_size $sdram_clock] > 0} {
    set sdram_outputs [get_ports {DRAM_ADDR[*] DRAM_BA[*] DRAM_CAS_N DRAM_CKE DRAM_CS_N DRAM_LDQM DRAM_RAS_N DRAM_UDQM DRAM_WE_N}]
    set_output_delay -clock $sdram_clock -max 1.5 $sdram_outputs
    set_output_delay -clock $sdram_clock -min -0.8 $sdram_outputs
    set_output_delay -clock $sdram_clock -max 1.5 [get_ports {DRAM_DQ[*]}]
    set_output_delay -clock $sdram_clock -min -0.8 [get_ports {DRAM_DQ[*]}]
    # CAS-3 tAC=5.4 ns and tOH=2.7 ns. Clock flight to the chip plus
    # returning data flight adds 0..0.3 ns relative to the FPGA clock pin.
    set_input_delay -clock $sdram_clock -max 5.7 [get_ports {DRAM_DQ[*]}]
    set_input_delay -clock $sdram_clock -min 2.7 [get_ports {DRAM_DQ[*]}]
    # Capture occurs inside the preceding word's guaranteed output-hold
    # interval. The forwarded pin clock and capture phase pair the previous launch
    # with the next capture edge.
    set sdram_capture_regs [get_registers {*dq_read_capture*}]
    set_multicycle_path -setup 2 -from [get_ports {DRAM_DQ[*]}] -to $sdram_capture_regs
}

# These board-facing signals communicate with people or an asynchronous UART,
# not a source-synchronous device. They are either synchronized internally or
# only affect displays, so no external setup/hold relationship exists to time.
set_false_path -from [get_ports {GPIO_0[9] KEY[2] KEY[3] SW[9]}]
set_false_path -to [get_ports {GPIO_0[7] HEX0[*] HEX1[*] HEX2[*] HEX3[*] HEX4[*] HEX5[*] LEDR[*]}]
