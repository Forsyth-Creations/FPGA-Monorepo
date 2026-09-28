// NeoPixel peripheral, Phase 3: the top of the packaged IP
// (forsyth:ip:ws2812_ctrl:1.0). AXI4-Lite in, one serial pin out.
//
// Port names follow the s_axi_* convention exactly so that Vivado's IP
// packager infers the AXI4-Lite interface on its own.
//
// Everything runs on s_axi_aclk (sysclk, 125 MHz). There is one clock domain.

`timescale 1 ps / 1 ps
`default_nettype none

module ws2812_top #(
    parameter int CLK_HZ   = 125_000_000,
    parameter int MAX_LEDS = 64,
    parameter int RESET_NS = 300_000
) (
    input  wire         s_axi_aclk,
    input  wire         s_axi_aresetn,
    input  wire  [11:0] s_axi_awaddr,
    input  wire  [2:0]  s_axi_awprot,
    input  wire         s_axi_awvalid,
    output logic        s_axi_awready,
    input  wire  [31:0] s_axi_wdata,
    input  wire  [3:0]  s_axi_wstrb,
    input  wire         s_axi_wvalid,
    output logic        s_axi_wready,
    output logic [1:0]  s_axi_bresp,
    output logic        s_axi_bvalid,
    input  wire         s_axi_bready,
    input  wire  [11:0] s_axi_araddr,
    input  wire  [2:0]  s_axi_arprot,
    input  wire         s_axi_arvalid,
    output logic        s_axi_arready,
    output logic [31:0] s_axi_rdata,
    output logic [1:0]  s_axi_rresp,
    output logic        s_axi_rvalid,
    input  wire         s_axi_rready,

    output logic        npx_data
);

    localparam int AW = $clog2(MAX_LEDS);
    localparam int CW = $clog2(MAX_LEDS + 1);

    logic [AW-1:0] reg_addr, fsm_addr;
    logic [23:0]   reg_wdata, reg_rdata, fsm_rdata;
    logic          reg_we;
    logic          start, soft_rst, busy, frame_done;
    logic [CW-1:0] led_count, led_index;
    logic          bit_val, bit_valid, bit_ready;

    // SOFT_RST drops the FSM and PHY back to idle; the register block itself
    // is only reset by the bus.
    logic core_rst_n;
    assign core_rst_n = s_axi_aresetn && !soft_rst;

    ws2812_axil_regs #(
        .MAX_LEDS (MAX_LEDS)
    ) u_regs (
        .s_axi_aclk    (s_axi_aclk),
        .s_axi_aresetn (s_axi_aresetn),
        .s_axi_awaddr  (s_axi_awaddr),
        .s_axi_awprot  (s_axi_awprot),
        .s_axi_awvalid (s_axi_awvalid),
        .s_axi_awready (s_axi_awready),
        .s_axi_wdata   (s_axi_wdata),
        .s_axi_wstrb   (s_axi_wstrb),
        .s_axi_wvalid  (s_axi_wvalid),
        .s_axi_wready  (s_axi_wready),
        .s_axi_bresp   (s_axi_bresp),
        .s_axi_bvalid  (s_axi_bvalid),
        .s_axi_bready  (s_axi_bready),
        .s_axi_araddr  (s_axi_araddr),
        .s_axi_arprot  (s_axi_arprot),
        .s_axi_arvalid (s_axi_arvalid),
        .s_axi_arready (s_axi_arready),
        .s_axi_rdata   (s_axi_rdata),
        .s_axi_rresp   (s_axi_rresp),
        .s_axi_rvalid  (s_axi_rvalid),
        .s_axi_rready  (s_axi_rready),
        .start         (start),
        .soft_rst      (soft_rst),
        .led_count     (led_count),
        .busy          (busy),
        .frame_done    (frame_done),
        .led_index     (led_index),
        .fb_addr       (reg_addr),
        .fb_wdata      (reg_wdata),
        .fb_we         (reg_we),
        .fb_rdata      (reg_rdata)
    );

    ws2812_framebuffer #(
        .MAX_LEDS (MAX_LEDS)
    ) u_fb (
        .clk     (s_axi_aclk),
        .a_addr  (reg_addr),
        .a_wdata (reg_wdata),
        .a_we    (reg_we),
        .a_rdata (reg_rdata),
        .b_addr  (fsm_addr),
        .b_rdata (fsm_rdata)
    );

    ws2812_frame_fsm #(
        .CLK_HZ   (CLK_HZ),
        .MAX_LEDS (MAX_LEDS),
        .RESET_NS (RESET_NS)
    ) u_fsm (
        .clk        (s_axi_aclk),
        .rst_n      (core_rst_n),
        .start      (start),
        .led_count  (led_count),
        .busy       (busy),
        .frame_done (frame_done),
        .led_index  (led_index),
        .fb_addr    (fsm_addr),
        .fb_rdata   (fsm_rdata),
        .bit_val    (bit_val),
        .bit_valid  (bit_valid),
        .bit_ready  (bit_ready)
    );

    ws2812_timing #(
        .CLK_HZ (CLK_HZ)
    ) u_phy (
        .clk       (s_axi_aclk),
        .rst_n     (core_rst_n),
        .bit_val   (bit_val),
        .bit_valid (bit_valid),
        .bit_ready (bit_ready),
        .serial    (npx_data)
    );

endmodule

`default_nettype wire
