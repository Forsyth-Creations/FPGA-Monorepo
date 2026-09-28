// Top level of the PL design.
//
// This is the real top -- Vivado synthesizes `top`, not a generated wrapper.
// It owns the physical pins and instantiates two things:
//
//   design_1     the block design (fpga/bd/design_1.tcl): PS7, two AXI GPIOs,
//                the ws2812_ctrl NeoPixel IP (fpga/ip/), interconnect and reset. Regenerated at build time, never
//                checked in. Treat it as the chassis.
//   rtl_counter  our logic, in plain Verilog alongside this file. It free-runs
//                off sysclk and is readable from the PS over AXI.
//
// New RTL gets instantiated here and wired to the block design's exposed
// pins. That keeps the block design fixed: adding logic means editing Verilog,
// not mutating a .bd.
//
// CLOCKING. sysclk is the 125 MHz oscillator on the board (pin K17), and it is
// the PL's clock -- an input to the block design, not an output from it. The PS
// takes it for M_AXI_GP0_ACLK and clocks its master port from it. FCLK_CLK0 is
// disabled entirely. The consequence worth knowing: the fabric runs the moment
// the bitstream is configured, with no dependency on the PS having been brought
// up. Under the old FCLK_CLK0 arrangement the PL sat dead until ps7_init ran.
//
// The DDR_0_* and FIXED_IO_0_* ports carry the PS7's external DDR and MIO
// connections straight through to the package pins. They are constrained by
// the processing_system7 IP itself, not by our XDC, which is why they need no
// entries in constraints/Zybo_Z7_io.xdc.

`timescale 1 ps / 1 ps
`default_nettype none

module top (
    input  wire        sysclk,
    inout  wire [14:0] DDR_0_addr,
    inout  wire [ 2:0] DDR_0_ba,
    inout  wire        DDR_0_cas_n,
    inout  wire        DDR_0_ck_n,
    inout  wire        DDR_0_ck_p,
    inout  wire        DDR_0_cke,
    inout  wire        DDR_0_cs_n,
    inout  wire [ 3:0] DDR_0_dm,
    inout  wire [31:0] DDR_0_dq,
    inout  wire [ 3:0] DDR_0_dqs_n,
    inout  wire [ 3:0] DDR_0_dqs_p,
    inout  wire        DDR_0_odt,
    inout  wire        DDR_0_ras_n,
    inout  wire        DDR_0_reset_n,
    inout  wire        DDR_0_we_n,
    inout  wire        FIXED_IO_0_ddr_vrn,
    inout  wire        FIXED_IO_0_ddr_vrp,
    inout  wire [53:0] FIXED_IO_0_mio,
    inout  wire        FIXED_IO_0_ps_clk,
    inout  wire        FIXED_IO_0_ps_porb,
    inout  wire        FIXED_IO_0_ps_srstb,
    output wire [ 3:0] led,
    input  wire [ 3:0] sw,
    input  wire [ 3:0] btn,
    output wire        npx_data   // WS2812B data, Pmod JE pin 1
);

    // Peripheral reset out of the block design: active low, synchronous to
    // sysclk, released once the PS is out of reset. Exposed for RTL that talks
    // to the AXI fabric and therefore has to reset with it. The counter below
    // deliberately does NOT use it -- see there.
    /* verilator lint_off UNUSED */
    wire [0:0] resetn;
    /* verilator lint_on UNUSED */

    // The counter is readable from the PS on AXI GPIO 0 channel 2. It is the
    // liveness indicator for the PL clock: if this value moves, sysclk is
    // running and the fabric is configured.
    wire [3:0] count;

    // AXI GPIO 0 channel 1 drives the LEDs, so software owns them.
    wire [3:0] led_o;

    design_1 design_1_i (
        .DDR_0_addr          (DDR_0_addr),
        .DDR_0_ba            (DDR_0_ba),
        .DDR_0_cas_n         (DDR_0_cas_n),
        .DDR_0_ck_n          (DDR_0_ck_n),
        .DDR_0_ck_p          (DDR_0_ck_p),
        .DDR_0_cke           (DDR_0_cke),
        .DDR_0_cs_n          (DDR_0_cs_n),
        .DDR_0_dm            (DDR_0_dm),
        .DDR_0_dq            (DDR_0_dq),
        .DDR_0_dqs_n         (DDR_0_dqs_n),
        .DDR_0_dqs_p         (DDR_0_dqs_p),
        .DDR_0_odt           (DDR_0_odt),
        .DDR_0_ras_n         (DDR_0_ras_n),
        .DDR_0_reset_n       (DDR_0_reset_n),
        .DDR_0_we_n          (DDR_0_we_n),
        .FIXED_IO_0_ddr_vrn  (FIXED_IO_0_ddr_vrn),
        .FIXED_IO_0_ddr_vrp  (FIXED_IO_0_ddr_vrp),
        .FIXED_IO_0_mio      (FIXED_IO_0_mio),
        .FIXED_IO_0_ps_clk   (FIXED_IO_0_ps_clk),
        .FIXED_IO_0_ps_porb  (FIXED_IO_0_ps_porb),
        .FIXED_IO_0_ps_srstb (FIXED_IO_0_ps_srstb),
        .sysclk              (sysclk),
        .resetn              (resetn),
        .led_o               (led_o),
        .count_i             (count),
        .sw_i                (sw),
        .btn_i               (btn),
        .npx_data            (npx_data)
    );

    // resetn is NOT wired in here on purpose. It is derived from the PS
    // (FCLK_RESET0_N), so a counter held by it would sit at zero until ps7_init
    // had run -- which is exactly the dead-PL failure the sysclk change is
    // meant to rule out. Tied high, the counter free-runs from configuration.
    rtl_counter #(
        .WIDTH    (4),
        .TICK_DIV (24)   // ~7.5 increments/sec on the 125 MHz sysclk
    ) u_counter (
        .clk    (sysclk),
        .resetn (1'b1),
        .count  (count)
    );

    assign led = led_o;

endmodule

`default_nettype wire
