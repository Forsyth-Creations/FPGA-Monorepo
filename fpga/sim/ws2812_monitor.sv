// Simulation-only WS2812B receiver: does what the first LED in the strip does.
//
// Watches `serial`, measures each high pulse, and calls it a 1 if it is longer
// than THRESH_CYC (halfway between T0H and T1H). Every 24 bits make a pixel.
// A low stretch of LATCH_CYC clocks ends the frame: `count` is updated,
// `frame_done` pulses for one clock, and `pixels[0..count-1]` holds the frame.
//
// It also checks that, inside a frame, every slot starts exactly BIT_CYC
// clocks after the previous one. That is the "gap between bits is
// load-bearing" rule, checked on every bit of every frame.
//
// LATCH_CYC only has to beat the longest low time inside a slot
// (BIT_CYC - T0H_CYC = 106 clocks). Testbenches shrink the FSM's reset gap to
// ~250 clocks, so 200 sits between the two. Not synthesizable; lives in sim/.

`timescale 1 ps / 1 ps
`default_nettype none

module ws2812_monitor #(
    parameter int THRESH_CYC = 75,
    parameter int BIT_CYC    = 156,
    parameter int LATCH_CYC  = 200,
    parameter int MAX_PIX    = 64
) (
    input  wire  clk,
    input  wire  serial,
    output logic frame_done,   // 1-clock pulse at end of frame
    output int   count         // pixels in the last complete frame
);

    logic [23:0] pixels [0:MAX_PIX-1];   // read hierarchically: u_mon.pixels[i]

    int          hi_cnt  = 0;
    int          lo_cnt  = 0;
    int          nbits   = 0;
    int          npix    = 0;
    int          since_rise = -1;        // clocks since last rising edge; -1 = no frame
    logic [23:0] shreg   = '0;
    logic        prev    = 1'b0;

    initial begin
        frame_done = 1'b0;
        count      = 0;
    end

    always @(posedge clk) begin
        frame_done <= 1'b0;
        if (since_rise >= 0) since_rise++;

        if (serial && !prev) begin
            // Rising edge: start of a slot. Check spacing from the last one.
            if (since_rise >= 0 && since_rise != BIT_CYC)
                $error("ws2812_monitor: slot %0d of pixel %0d started %0d clocks after the previous one, expected %0d",
                       nbits, npix, since_rise, BIT_CYC);
            since_rise = 0;
        end

        if (serial) begin
            hi_cnt++;
            lo_cnt = 0;
        end else begin
            if (prev) begin
                // Falling edge: classify the pulse that just ended.
                shreg = {shreg[22:0], (hi_cnt > THRESH_CYC)};
                nbits++;
                if (nbits == 24) begin
                    if (npix < MAX_PIX) pixels[npix] = shreg;
                    npix++;
                    nbits = 0;
                end
            end
            hi_cnt = 0;
            lo_cnt++;

            if (lo_cnt == LATCH_CYC && since_rise >= 0) begin
                if (nbits != 0)
                    $error("ws2812_monitor: frame latched mid-pixel, %0d stray bits", nbits);
                count      <= npix;
                frame_done <= 1'b1;
                npix       = 0;
                nbits      = 0;
                since_rise = -1;
            end
        end
        prev = serial;
    end

endmodule

`default_nettype wire
