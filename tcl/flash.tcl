# Flash the U50 SPI for boot-time loading.
open_hw_manager
connect_hw_server -allow_non_jtag
open_hw_target
set device [lindex [get_hw_devices] 0]
create_hw_cfgmem -hw_device $device -mem_dev mt25qu01g-spi-x1_x2_x4
set cfgmem [get_property PROGRAM.HW_CFGMEM $device]
set_property PROGRAM.FILES         [list "hw/build/fpga.mcs"] $cfgmem
set_property PROGRAM.PRM_FILES     [list "hw/build/fpga.prm"] $cfgmem
set_property PROGRAM.ERASE         1 $cfgmem
set_property PROGRAM.CFG_PROGRAM   1 $cfgmem
set_property PROGRAM.VERIFY        1 $cfgmem
program_hw_cfgmem -hw_cfgmem $cfgmem
close_hw_target
disconnect_hw_server
