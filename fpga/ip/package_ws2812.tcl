# Package fpga/ip/ws2812_ctrl/src/*.sv as forsyth:ip:ws2812_ctrl:1.0.
#
#   cd fpga && vivado -mode batch -nojournal -nolog -source ip/package_ws2812.tcl
#
# Writes component.xml (and xgui/) into ip/ws2812_ctrl/. The sources are
# referenced in place, not copied, so editing src/ and re-running this is the
# whole update loop. Run it again whenever a port or parameter changes.

set ip_dir  [file normalize [file join [file dirname [info script]] ws2812_ctrl]]
set src_dir [file join $ip_dir src]
set tmp_dir [file join $ip_dir .pkg_tmp]

# ipx::package_project packages a *project*, so make a throwaway one.
file delete -force $tmp_dir
create_project -force pkg_tmp $tmp_dir -part xc7z020clg400-1
add_files -norecurse [lsort [glob $src_dir/*.sv]]
set_property top ws2812_top [current_fileset]
update_compile_order -fileset sources_1

ipx::package_project -root_dir $ip_dir -vendor forsyth -library ip \
    -taxonomy /UserIP -import_files false -set_current true
set core [ipx::current_core]

set_property name         ws2812_ctrl                       $core
set_property version      1.0                               $core
set_property display_name {WS2812 NeoPixel controller}      $core
set_property description  {AXI4-Lite WS2812B LED strip driver} $core
set_property core_revision 1                                $core

# The s_axi_* names let Vivado infer the AXI4-Lite interface ("s_axi") and its
# clock/reset. Make the clock association explicit anyway: without it a BD can
# drop the IP in with no clock inference.
ipx::associate_bus_interfaces -busif s_axi -clock s_axi_aclk $core
set clk_if [ipx::get_bus_interfaces s_axi_aclk -of_objects $core]
set freq   [ipx::get_bus_parameters FREQ_HZ -of_objects $clk_if]
if {$freq eq ""} { set freq [ipx::add_bus_parameter FREQ_HZ $clk_if] }
set_property value 125000000 $freq

ipx::create_xgui_files $core
ipx::update_checksums  $core
ipx::check_integrity   $core
ipx::save_core         $core

close_project -delete
file delete -force $tmp_dir
puts "Packaged [get_property vlnv $core] into $ip_dir"
