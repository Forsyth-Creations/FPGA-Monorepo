// WS2812B bit-slot PHY: turns one bit into one 1.25 us pulse-width-encoded slot.
//
// This is the only module in the design that knows about nanoseconds. It has
// no state machine: a single counter, `cnt`, runs 0..BIT_CYC-1 once per bit,
// and the line is high while `cnt` is below the high-time for that bit. The
// counter *is* the state.
//
// bit_ready is high on the final cycle of a slot as well as when idle, so an
// upstream that is already holding bit_valid gets its next bit started on the
// very next cycle -- no dead cycles between slots.
//
// `serial` is registered rather than driven straight off the comparator. A
// comparator output can glitch for a fraction of a cycle while `cnt` changes,
// and this signal leaves the chip. The flop delays every edge by exactly one
// cycle, so pulse widths are unchanged.

`timescale 1 ps / 1 ps
`default_nettype none

module ws2812_timing #(
    parameter int CLK_HZ = 125_000_000,
    parameter int T0H_NS = 400,
    parameter int T1H_NS = 800,
    parameter int BIT_NS = 1250
) (
    input  wire  clk,
    input  wire  rst_n,        // active low, synchronous
    input  wire  bit_val,      // bit to send; sampled when the handshake fires
    input  wire  bit_valid,    // upstream has a bit ready
    output logic bit_ready,    // high when able to accept a bit
    output logic serial        // the encoded line
);

    // Elaboration-time integer math: 125 cycles/us -> 50, 100, 156.
    localparam int CYC_PER_US = CLK_HZ / 1_000_000;
    localparam int T0H_CYC    = CYC_PER_US * T0H_NS / 1000;
    localparam int T1H_CYC    = CYC_PER_US * T1H_NS / 1000;
    localparam int BIT_CYC    = CYC_PER_US * BIT_NS / 1000;

    logic [$clog2(BIT_CYC)-1:0] cnt;
    logic                       busy;      // a slot is in progress
    logic                       cur_bit;   // the bit being sent

    logic last;
    logic fire;
    assign last      = busy && (cnt == BIT_CYC - 1);
    assign bit_ready = !busy || last;
    assign fire      = bit_valid && bit_ready;

    always_ff @(posedge clk) begin
        if (!rst_n) begin
            busy    <= 1'b0;
            cnt     <= '0;
            cur_bit <= 1'b0;
        end else if (fire) begin
            busy    <= 1'b1;
            cnt     <= '0;
            cur_bit <= bit_val;
        end else if (last) begin
            busy    <= 1'b0;
        end else if (busy) begin
            cnt     <= cnt + 1'b1;
        end
    end

    // The encoder, in one line.
    always_ff @(posedge clk) begin
        if (!rst_n) serial <= 1'b0;
        else        serial <= busy && (cnt < (cur_bit ? T1H_CYC : T0H_CYC));
    end

endmodule

`default_nettype wire
