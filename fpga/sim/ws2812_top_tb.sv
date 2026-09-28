// Phase 2 testbench: the whole no-bus pipeline, pattern generator to pin.
//
//   cd fpga && yarn simulate ws2812_top_tb
//
// sw = 4'b1001 is "red, bright", so every pixel should decode as 0x004000
// (G=00 R=40 B=00) except the moving dot, which is 0xFFFFFF and advances one
// LED per frame. NUM_LEDS and FRAME_DIV are shrunk; the reset gap is real.

`timescale 1 ps / 1 ps
`default_nettype none

module ws2812_top_tb;

    localparam int CLK_HALF = 4000;   // 125 MHz
    localparam int NLEDS    = 4;

    logic clk = 1'b0;
    logic npx;
    logic mon_done;
    int   mon_count;
    int   errors = 0;

    always #CLK_HALF clk = ~clk;

    ws2812_top #(
        .NUM_LEDS  (NLEDS),
        .FRAME_DIV (17)      // a start every 131072 clocks instead of 2 million
    ) dut (
        .clk      (clk),
        .rst_n    (1'b1),    // tied high, exactly as in top.v
        .sw       (4'b1001),
        .npx_data (npx)
    );

    ws2812_monitor u_mon (.clk(clk), .serial(npx), .frame_done(mon_done), .count(mon_count));

    initial begin
        for (int f = 0; f < 2; f++) begin
            @(posedge mon_done);
            #1;
            if (mon_count != NLEDS) begin
                $display("FAIL: frame %0d had %0d pixels, expected %0d", f, mon_count, NLEDS);
                errors++;
            end
            for (int i = 0; i < NLEDS; i++) begin
                automatic logic [23:0] exp = (i == f) ? 24'hFFFFFF : 24'h004000;
                if (u_mon.pixels[i] !== exp) begin
                    $display("FAIL: frame %0d pixel %0d decoded as %06h, expected %06h",
                             f, i, u_mon.pixels[i], exp);
                    errors++;
                end
            end
        end

        if (errors != 0) begin
            $display("ws2812_top_tb: %0d failure(s)", errors);
            $fatal(1, "ws2812_top_tb FAILED");
        end
        $display("ws2812_top_tb: SIM PASS -- 2 frames, dot moved");
        $finish;
    end

    // 64-bit: 8000 ps x 1,000,000 overflows a 32-bit int.
    initial begin
        #(64'd8000 * 1_000_000);
        $fatal(1, "ws2812_top_tb: timeout");
    end

endmodule

`default_nettype wire
