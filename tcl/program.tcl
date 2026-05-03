# Program the U50 over JTAG with a built bitstream.
# Expects hw/build/fpga.bit to exist.
open_hw_manager
connect_hw_server -allow_non_jtag
open_hw_target
set device [lindex [get_hw_devices] 0]
set_property PROGRAM.FILE [file normalize hw/build/fpga.bit] $device
program_hw_devices $device
refresh_hw_device $device
close_hw_target
disconnect_hw_server
