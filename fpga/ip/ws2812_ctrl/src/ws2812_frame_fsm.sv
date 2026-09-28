// Frame sequencer: walks the framebuffer, feeds bits to the PHY, then holds
// the line low long enough for the strip to latch.
//
//   IDLE --start--> LOAD --> SHIFT (24 bits x led_count) --> RESET --> IDLE
//
// This module counts bits and pixels, never nanoseconds; the PHY owns timing.
//
// Pixel boundaries cost zero cycles. While pixel n is shifting out, fb_addr
// already points at pixel n+1, and the RAM's output register holds that word
// for the whole 24-bit (3744-clock) window. So when the last bit of pixel n is
// handed over, shreg reloads straight from fb_rdata in the same clock.
//
// The reset gap is counted only while the PHY is ready (idle, or in the last
// clock of its final slot), so the line is guaranteed low for at least
// RESET_CYC clocks after the final bit, however long that slot was.

`timescale 1 ps / 1 ps
`default_nettype none

module ws2812_frame_fsm #(
    parameter int CLK_HZ   = 125_000_000,
    parameter int MAX_LEDS = 64,
    parameter int RESET_NS = 300_000
) (
    input  wire  clk,
    input  wire  rst_n,
    input  wire  start,                              // 1-cycle pulse
    input  wire  [$clog2(MAX_LEDS+1)-1:0] led_count,
    output logic busy,
    output logic frame_done,                         // 1-cycle pulse
    output logic [$clog2(MAX_LEDS+1)-1:0] led_index, // for STATUS
    // framebuffer port B
    output logic [$clog2(MAX_LEDS)-1:0]   fb_addr,
    input  wire  [23:0]                   fb_rdata,
    // PHY handshake
    output logic bit_val,
    output logic bit_valid,
    input  wire  bit_ready
);

    localparam int RESET_CYC = (CLK_HZ / 1_000_000) * RESET_NS / 1000;   // 37500

    typedef enum logic [1:0] { IDLE, LOAD, SHIFT, RESET } state_t;
    state_t state;

    logic [23:0]                       shreg;
    logic [4:0]                        bit_cnt;     // 0..23
    logic [$clog2(MAX_LEDS+1)-1:0]     count_q;     // led_count, latched at start
    logic [$clog2(RESET_CYC+1)-1:0]    reset_cnt;

    assign busy      = (state != IDLE);
    assign bit_val   = shreg[23];
    assign bit_valid = (state == SHIFT);

    logic fire;
    assign fire = bit_valid && bit_ready;

    always_ff @(posedge clk) begin
        frame_done <= 1'b0;

        if (!rst_n) begin
            state     <= IDLE;
            shreg     <= '0;
            bit_cnt   <= '0;
            count_q   <= '0;
            reset_cnt <= '0;
            led_index <= '0;
            fb_addr   <= '0;
        end else begin
            case (state)
                IDLE: begin
                    // fb_addr sits at 0 here, so fb_rdata already holds pixel 0.
                    fb_addr   <= '0;
                    led_index <= '0;
                    if (start && led_count != 0) begin
                        count_q <= (led_count > MAX_LEDS) ? MAX_LEDS : led_count;
                        state   <= LOAD;
                    end
                end

                LOAD: begin
                    shreg   <= fb_rdata;          // pixel 0
                    fb_addr <= 1;                 // prefetch pixel 1
                    bit_cnt <= '0;
                    state   <= SHIFT;
                end

                SHIFT: if (fire) begin
                    if (bit_cnt != 23) begin
                        shreg   <= shreg << 1;
                        bit_cnt <= bit_cnt + 1'b1;
                    end else if (led_index == count_q - 1) begin
                        reset_cnt <= '0;          // that was the last bit of the frame
                        state     <= RESET;
                    end else begin
                        shreg     <= fb_rdata;    // prefetched: zero dead cycles
                        fb_addr   <= fb_addr + 1'b1;
                        led_index <= led_index + 1'b1;
                        bit_cnt   <= '0;
                    end
                end

                RESET: begin
                    if (bit_ready) reset_cnt <= reset_cnt + 1'b1;
                    if (reset_cnt == RESET_CYC - 1) begin
                        frame_done <= 1'b1;
                        state      <= IDLE;
                    end
                end
            endcase
        end
    end

endmodule

`default_nettype wire
