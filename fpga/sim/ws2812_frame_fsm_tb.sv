// Testbench for ws2812_frame_fsm, with the real framebuffer and PHY behind it
// and ws2812_monitor decoding the line.
//
//   cd fpga && yarn simulate ws2812_frame_fsm_tb
//   cd fpga && yarn simulate ws2812_frame_fsm_tb --gui
//
// Bit timing is real (it's what's under test). The frame is shrunk: 3 LEDs
// and a 2 us reset gap instead of 64 LEDs and 300 us.

`timescale 1 ps / 1 ps
`default_nettype none

module ws2812_frame_fsm_tb;

    localparam int CLK_HALF = 4000;   // 125 MHz
    localparam int MAX_LEDS = 64;
    localparam int NLEDS    = 3;
    localparam int AW       = $clog2(MAX_LEDS);
    localparam int CW       = $clog2(MAX_LEDS + 1);

    logic clk   = 1'b0;
    logic rst_n = 1'b0;
    logic start = 1'b0;

    // Port A, driven by the testbench to preload pixels.
    logic [AW-1:0] a_addr  = '0;
    logic [23:0]   a_wdata = '0;
    logic          a_we    = 1'b0;
    logic [23:0]   a_rdata;

    logic [AW-1:0] fb_addr;
    logic [23:0]   fb_rdata;
    logic          busy, frame_done;
    logic [CW-1:0] led_index;
    logic          bit_val, bit_valid, bit_ready, serial;

    logic          mon_done;
    int            mon_count;

    int errors = 0;

    always #CLK_HALF clk = ~clk;

    ws2812_framebuffer #(.MAX_LEDS(MAX_LEDS)) u_fb (
        .clk(clk),
        .a_addr(a_addr), .a_wdata(a_wdata), .a_we(a_we), .a_rdata(a_rdata),
        .b_addr(fb_addr), .b_rdata(fb_rdata)
    );

    ws2812_frame_fsm #(.MAX_LEDS(MAX_LEDS), .RESET_NS(2000)) u_fsm (
        .clk(clk), .rst_n(rst_n), .start(start), .led_count(CW'(NLEDS)),
        .busy(busy), .frame_done(frame_done), .led_index(led_index),
        .fb_addr(fb_addr), .fb_rdata(fb_rdata),
        .bit_val(bit_val), .bit_valid(bit_valid), .bit_ready(bit_ready)
    );

    ws2812_timing u_phy (
        .clk(clk), .rst_n(rst_n),
        .bit_val(bit_val), .bit_valid(bit_valid), .bit_ready(bit_ready),
        .serial(serial)
    );

    ws2812_monitor u_mon (
        .clk(clk), .serial(serial), .frame_done(mon_done), .count(mon_count)
    );

    task automatic fb_write(input int n, input logic [23:0] v);
        @(negedge clk);
        a_addr  = AW'(n);
        a_wdata = v;
        a_we    = 1'b1;
        @(negedge clk);
        a_we    = 1'b0;
    endtask

    task automatic run_frame();
        @(negedge clk);
        start = 1'b1;
        @(negedge clk);
        start = 1'b0;
        if (!busy) begin
            $display("FAIL: busy did not rise after start");
            errors++;
        end
        @(posedge frame_done);
        // The monitor latches LATCH_CYC clocks into the reset gap, which is
        // before the FSM's own frame_done -- so its result is ready by now.
    endtask

    task automatic expect_frame(input logic [23:0] exp [NLEDS]);
        if (mon_count != NLEDS) begin
            $display("FAIL: monitor saw %0d pixels, expected %0d", mon_count, NLEDS);
            errors++;
        end
        for (int i = 0; i < NLEDS; i++) begin
            if (u_mon.pixels[i] !== exp[i]) begin
                $display("FAIL: pixel %0d decoded as %06h, expected %06h", i, u_mon.pixels[i], exp[i]);
                errors++;
            end
        end
    endtask

    logic [23:0] frame1 [NLEDS] = '{24'hFF0000, 24'h00FF00, 24'h0000FF};
    logic [23:0] frame2 [NLEDS] = '{24'h123456, 24'hA5C381, 24'h800001};

    initial begin
        repeat (4) @(posedge clk);
        @(negedge clk);
        rst_n = 1'b1;

        // Deliberately asymmetric values, so a byte-order or bit-order bug
        // shows up as a mismatch rather than a coincidental pass.
        for (int i = 0; i < NLEDS; i++) fb_write(i, frame1[i]);
        run_frame();
        expect_frame(frame1);

        // A second frame proves the FSM comes back cleanly from RESET.
        for (int i = 0; i < NLEDS; i++) fb_write(i, frame2[i]);
        run_frame();
        expect_frame(frame2);

        if (busy) begin
            $display("FAIL: busy still high after frame_done");
            errors++;
        end

        if (errors != 0) begin
            $display("ws2812_frame_fsm_tb: %0d failure(s)", errors);
            $fatal(1, "ws2812_frame_fsm_tb FAILED");
        end
        $display("ws2812_frame_fsm_tb: SIM PASS -- 2 frames of %0d pixels decoded", NLEDS);
        $finish;
    end

    initial begin
        #(CLK_HALF * 2 * 200_000);
        $fatal(1, "ws2812_frame_fsm_tb: timeout");
    end

endmodule

`default_nettype wire
