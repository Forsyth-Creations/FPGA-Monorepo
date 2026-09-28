// Pixel store: MAX_LEDS x 24 bits, one word per LED in wire order (GRB).
//
// Port A is read/write (pattern generator in Phase 2, AXI in Phase 3); port B
// is read-only for the frame FSM. Both ports have one cycle of read latency:
// rdata shows mem[addr] the cycle *after* addr is presented.
//
// The array is deliberately never reset. A reset on `mem` would force Vivado
// to build it from flip-flops instead of RAM. Contents after configuration are
// whatever the bitstream initialises them to (zero), which is fine.

`timescale 1 ps / 1 ps
`default_nettype none

module ws2812_framebuffer #(
    parameter int MAX_LEDS = 64
) (
    input  wire  clk,
    // Port A -- AXI (Phase 3) / pattern generator (Phase 2)
    input  wire  [$clog2(MAX_LEDS)-1:0] a_addr,
    input  wire  [23:0]                 a_wdata,
    input  wire                         a_we,
    output logic [23:0]                 a_rdata,
    // Port B -- read-only, frame FSM
    input  wire  [$clog2(MAX_LEDS)-1:0] b_addr,
    output logic [23:0]                 b_rdata
);

    logic [23:0] mem [0:MAX_LEDS-1];

    always_ff @(posedge clk) begin
        if (a_we) mem[a_addr] <= a_wdata;
        a_rdata <= mem[a_addr];
    end

    always_ff @(posedge clk) begin
        b_rdata <= mem[b_addr];
    end

endmodule

`default_nettype wire
