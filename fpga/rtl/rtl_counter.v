// Free-running counter for the LEDs.
//
// A 4-bit counter clocked directly off FCLK_CLK0 would roll over at about
// 3 MHz, which reads as four LEDs at steady half brightness. So the count is
// gated by a prescaler: `div` free-runs and every time it wraps it emits a
// one-cycle tick that advances the visible count.
//
// TICK_DIV is the prescaler width, so the divider is 2**TICK_DIV. With the
// defaults on the 50 MHz FCLK_CLK0:
//
//   tick rate   = 50e6 / 2**23 = 5.96 Hz     (count increments ~6x/second)
//   full cycle  = 16 / 5.96    = 2.68 s      (0 -> 15 and back to 0)
//
// Drop TICK_DIV to speed it up, raise it to slow it down; each step is a
// factor of two. sim/rtl_counter_tb.v drives it with TICK_DIV = 4 so the
// testbench sees the count move in hundreds of cycles rather than millions.
//
// TICK_DIV must be at least 1 -- it is the width of a register.

`timescale 1 ps / 1 ps
`default_nettype none

module rtl_counter #(
    parameter integer WIDTH    = 4,
    parameter integer TICK_DIV = 23
) (
    input  wire             clk,
    input  wire             resetn,
    output reg  [WIDTH-1:0] count
);

    reg [TICK_DIV-1:0] div;

    // `div` wraps on its own, so the tick is just its terminal count.
    wire tick = (div == {TICK_DIV{1'b1}});

    always @(posedge clk) begin
        if (!resetn) begin
            div   <= {TICK_DIV{1'b0}};
            count <= {WIDTH{1'b0}};
        end else begin
            div <= div + 1'b1;

            if (tick) begin
                count <= count + 1'b1;
            end
        end
    end

endmodule

`default_nettype wire
