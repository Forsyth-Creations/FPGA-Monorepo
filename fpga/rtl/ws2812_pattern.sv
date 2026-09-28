// Phase 2 test source: fills the framebuffer from the slide switches and kicks
// a frame every 2**FRAME_DIV clocks. No bus, no software.
//
//   sw[0] red   sw[1] green   sw[2] blue   sw[3] bright
//
// The framebuffer is rewritten continuously, one pixel per clock, so there is
// no "write then start" ordering to get right. One pixel -- `dot` -- is drawn
// at full brightness and moves one LED per frame, which proves the pixels
// arrive in order rather than just "some light came on".
//
// FRAME_DIV = 21 at 125 MHz is a start every 16.8 ms (~60 fps). A 64-LED frame
// takes 2.2 ms, so the FSM is always idle by the next start.

`timescale 1 ps / 1 ps
`default_nettype none

module ws2812_pattern #(
    parameter int MAX_LEDS  = 64,
    parameter int NUM_LEDS  = 64,
    parameter int FRAME_DIV = 21
) (
    input  wire  clk,
    input  wire  [3:0] sw,
    input  wire        frame_done,
    output logic [$clog2(MAX_LEDS)-1:0] fb_addr,
    output logic [23:0]                 fb_wdata,
    output logic                        fb_we,
    output logic                        start
);

    logic [FRAME_DIV-1:0]          div  = '0;
    logic [$clog2(MAX_LEDS)-1:0]   addr = '0;
    logic [$clog2(MAX_LEDS)-1:0]   dot  = '0;

    // Dim level for the background, full level for the moving dot.
    logic [7:0] lvl;
    assign lvl = sw[3] ? 8'h40 : 8'h08;

    logic [7:0] r, g, b;
    always_comb begin
        if (addr == dot) begin
            r = 8'hFF; g = 8'hFF; b = 8'hFF;
        end else begin
            r = sw[0] ? lvl : 8'h00;
            g = sw[1] ? lvl : 8'h00;
            b = sw[2] ? lvl : 8'h00;
        end
    end

    assign fb_addr  = addr;
    assign fb_wdata = {g, r, b};        // wire order is G, R, B
    assign fb_we    = 1'b1;
    assign start    = (div == '1);

    always_ff @(posedge clk) begin
        div  <= div + 1'b1;
        addr <= (addr == NUM_LEDS - 1) ? '0 : addr + 1'b1;
        if (frame_done) dot <= (dot == NUM_LEDS - 1) ? '0 : dot + 1'b1;
    end

endmodule

`default_nettype wire
