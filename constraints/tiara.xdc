# Tiara design constraints (Alveo U50, xcu50-fsvh2104-2-e).
#
# Out-of-context-style XDC: we constrain only the design's primary
# clock at the target 200 MHz.  When integrated into a full Corundum
# design the master XDC (constraints/alveo-u50-xdc.xdc) sets up the
# physical pins; this file only adds the timing requirements specific
# to the Tiara core.

create_clock -name clk -period 5.000 [get_ports clk]

# Async reset; treat as false-path for setup but synchronize internally.
set_input_delay  -clock clk 0.000 [get_ports rst_n]
set_false_path   -from [get_ports rst_n]

# Inputs are static / set at registration / dispatch time; relax timing
# on them so a small skew doesn't dominate.  Real builds drive these
# from the Corundum DMA pipeline at the same clk domain.
set_input_delay  -clock clk -max 1.000 [get_ports load_en]
set_input_delay  -clock clk -max 1.000 [get_ports {load_addr[*]}]
set_input_delay  -clock clk -max 1.000 [get_ports {load_data[*]}]
set_input_delay  -clock clk -max 1.000 [get_ports inv_valid]
set_input_delay  -clock clk -max 1.000 [get_ports {inv_args[*][*]}]

# Outputs likewise.
set_output_delay -clock clk -max 1.000 [get_ports inv_busy]
set_output_delay -clock clk -max 1.000 [get_ports done]
set_output_delay -clock clk -max 1.000 [get_ports {done_result[*][*]}]
set_output_delay -clock clk -max 1.000 [get_ports done_err]
set_output_delay -clock clk -max 1.000 [get_ports {instr_retired[*]}]
