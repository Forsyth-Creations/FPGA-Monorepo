# Deploy script: program the Zybo Z7 via JTAG using Vivado Hardware Manager
# Run from the fpga/ directory:
#   vivado -mode batch -source scripts/deploy.tcl

set script_dir [file dirname [file normalize [info script]]]

# Prefer the artifact collected by build_platform; fall back to the raw impl
# run directory so a bitstream built in the Vivado GUI still deploys.
set candidates [list \
    [file normalize "$script_dir/../dist/design_1_wrapper.bit"] \
    [file normalize "$script_dir/../project_1/project_1.runs/impl_1/design_1_wrapper.bit"]]

set bit_file ""
foreach candidate $candidates {
    if {[file exists $candidate]} {
        set bit_file $candidate
        break
    }
}

if {$bit_file eq ""} {
    error "Bitstream not found in any of:\n  [join $candidates "\n  "]\nRun 'yarn build_platform' first."
}

puts "Programming device with: $bit_file"

open_hw_manager
connect_hw_server -allow_non_jtag
open_hw_target

set device [current_hw_device]
set_property PROGRAM.FILE $bit_file $device
program_hw_devices $device
refresh_hw_device $device

close_hw_manager
puts "Deploy complete."
