// NeoPixel peripheral, Phase 2 wiring: pattern generator -> framebuffer ->
// frame FSM -> PHY -> pin. Phase 3 replaces the pattern generator with the
// AXI4-Lite register block and this file with the packaged-IP version.
//
// top.v ties rst_n high (see the note there about the PS-derived reset), so
// nothing would ever reset the FSM and PHY. A 4-bit shift register with an
// initial value gives them a clean power-on reset instead: Xilinx FPGAs load
// every flop's initial value at configuration, so `por` starts at 0 and fills
// with 1s over the first four clocks.

`timescale 1 ps / 1 ps
`default_nettype none

module ws2812_top #(
    parameter int CLK_HZ   = 125_000_000,
    parameter int MAX_LEDS = 64,
    parameter int NUM_LEDS  = 64,
    parameter int FRAME_DIV = 21     // start a frame every 2**FRAME_DIV clocks
) (
    input  wire        clk,
    input  wire        rst_n,
    input  wire  [3:0] sw,
    output logic       npx_data
);

    localparam int AW = $clog2(MAX_LEDS);
    localparam int CW = $clog2(MAX_LEDS + 1);

    logic [3:0] por = '0;
    logic       rst_q_n;
    always_ff @(posedge clk) por <= {por[2:0], 1'b1};
    assign rst_q_n = rst_n && por[3];

    logic [AW-1:0] pat_addr, fsm_addr;
    logic [23:0]   pat_wdata, fsm_rdata;
    logic          pat_we, start, frame_done, busy;
    logic [CW-1:0] led_index;
    logic          bit_val, bit_valid, bit_ready;

    ws2812_pattern #(
        .MAX_LEDS  (MAX_LEDS),
        .NUM_LEDS  (NUM_LEDS),
        .FRAME_DIV (FRAME_DIV)
    ) u_pattern (
        .clk        (clk),
        .sw         (sw),
        .frame_done (frame_done),
        .fb_addr    (pat_addr),
        .fb_wdata   (pat_wdata),
        .fb_we      (pat_we),
        .start      (start)
    );

    ws2812_framebuffer #(
        .MAX_LEDS (MAX_LEDS)
    ) u_fb (
        .clk     (clk),
        .a_addr  (pat_addr),
        .a_wdata (pat_wdata),
        .a_we    (pat_we),
        .a_rdata (),
        .b_addr  (fsm_addr),
        .b_rdata (fsm_rdata)
    );

    ws2812_frame_fsm #(
        .CLK_HZ   (CLK_HZ),
        .MAX_LEDS (MAX_LEDS)
    ) u_fsm (
        .clk        (clk),
        .rst_n      (rst_q_n),
        .start      (start),
        .led_count  (CW'(NUM_LEDS)),
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
        .clk       (clk),
        .rst_n     (rst_q_n),
        .bit_val   (bit_val),
        .bit_valid (bit_valid),
        .bit_ready (bit_ready),
        .serial    (npx_data)
    );

endmodule

`default_nettype wire
