## Zybo Z7-20 pin assignments.
##
## Pin locations and IO standards are from Digilent's Zybo-Z7-Master.xdc
## (github.com/Digilent/digilent-xdc). Only the PL-side pins this design uses
## are listed; the PS DDR and MIO pins are constrained by the processing_system7
## IP itself, not from here.

## Clock signal -- 125 MHz board oscillator on a clock-capable (MRCC) pin.
## This is the PL's clock and the source for the AXI fabric; the PS takes it on
## M_AXI_GP0_ACLK. See the CLOCKING note in rtl/top.v.
set_property -dict { PACKAGE_PIN K17   IOSTANDARD LVCMOS33 } [get_ports { sysclk }]
create_clock -add -name sys_clk_pin -period 8.00 -waveform {0 4} [get_ports { sysclk }]

## LEDs -- driven by AXI GPIO 0 channel 1, so software owns them.
set_property -dict { PACKAGE_PIN M14   IOSTANDARD LVCMOS33 } [get_ports { led[0] }]
set_property -dict { PACKAGE_PIN M15   IOSTANDARD LVCMOS33 } [get_ports { led[1] }]
set_property -dict { PACKAGE_PIN G14   IOSTANDARD LVCMOS33 } [get_ports { led[2] }]
set_property -dict { PACKAGE_PIN D18   IOSTANDARD LVCMOS33 } [get_ports { led[3] }]

## Slide switches -- AXI GPIO 1 channel 1 (inputs).
set_property -dict { PACKAGE_PIN G15   IOSTANDARD LVCMOS33 } [get_ports { sw[0] }]
set_property -dict { PACKAGE_PIN P15   IOSTANDARD LVCMOS33 } [get_ports { sw[1] }]
set_property -dict { PACKAGE_PIN W13   IOSTANDARD LVCMOS33 } [get_ports { sw[2] }]
set_property -dict { PACKAGE_PIN T16   IOSTANDARD LVCMOS33 } [get_ports { sw[3] }]

## Pushbuttons -- AXI GPIO 1 channel 2 (inputs). Active high, and not debounced
## in hardware: a single press can read as several transitions, so software that
## counts edges rather than sampling level needs to debounce.
set_property -dict { PACKAGE_PIN K18   IOSTANDARD LVCMOS33 } [get_ports { btn[0] }]
set_property -dict { PACKAGE_PIN P16   IOSTANDARD LVCMOS33 } [get_ports { btn[1] }]
set_property -dict { PACKAGE_PIN K19   IOSTANDARD LVCMOS33 } [get_ports { btn[2] }]
set_property -dict { PACKAGE_PIN Y16   IOSTANDARD LVCMOS33 } [get_ports { btn[3] }]

## NeoPixel data -- ws2812_ctrl_0 in the block design. Pmod JE pin 1 (je[0] in
## Digilent's master XDC), through a 5 V level shifter to the strip's DIN.
## Deliberately no timing constraint: WS2812B is self-clocked, so the output
## has no clock relationship to check and the unconstrained-output warning is
## expected.
set_property -dict { PACKAGE_PIN V12   IOSTANDARD LVCMOS33 } [get_ports { npx_data }]
