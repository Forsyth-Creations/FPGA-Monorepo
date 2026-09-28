// Testbench for ws2812_timing.
//
//   cd fpga && yarn simulate ws2812_timing_tb
//   cd fpga && yarn simulate ws2812_timing_tb --gui
//
// Timing parameters are left at their real values -- they are the thing under
// test. A whole run is a few thousand clocks.

`timescale 1 ps / 1 ps
`default_nettype none

module ws2812_timing_tb;

    localparam int CLK_HALF = 4000;   // 8 ns period = 125 MHz
    localparam int T0H_CYC  = 50;
    localparam int T1H_CYC  = 100;
    localparam int BIT_CYC  = 156;

    logic clk       = 1'b0;
    logic rst_n     = 1'b0;
    logic bit_val   = 1'b0;
    logic bit_valid = 1'b0;
    logic bit_ready;
    logic serial;

    int errors = 0;

    always #CLK_HALF clk = ~clk;

    ws2812_timing dut (
        .clk       (clk),
        .rst_n     (rst_n),
        .bit_val   (bit_val),
        .bit_valid (bit_valid),
        .bit_ready (bit_ready),
        .serial    (serial)
    );

    // ---- Measurement -----------------------------------------------------
    // Count clocks, and record every high-pulse width and every
    // rising-edge-to-rising-edge distance (= slot length when back-to-back).
    int cyc       = 0;
    int rise_at   = -1;
    int highs[$];
    int periods[$];
    logic prev    = 1'b0;

    always @(posedge clk) begin
        cyc++;
        if (serial && !prev) begin
            if (rise_at >= 0) periods.push_back(cyc - rise_at);
            rise_at = cyc;
        end
        if (!serial && prev) highs.push_back(cyc - rise_at);
        prev = serial;
    end

    // ---- Stimulus ----------------------------------------------------------
    // Send `n` bits, MSB first, holding bit_valid high the whole time so the
    // PHY is never starved. Inputs change on the falling edge, well away from
    // the rising edge that samples them.
    task automatic send_bits(input logic [31:0] bits, input int n);
        for (int i = n - 1; i >= 0; i--) begin
            @(negedge clk);
            bit_val   = bits[i];
            bit_valid = 1'b1;
            while (!bit_ready) @(negedge clk);
            // bit_ready is high here, so the next rising edge takes the bit.
        end
        @(negedge clk);
        bit_valid = 1'b0;
    endtask

    task automatic idle(input int n);
        repeat (n) @(posedge clk);
    endtask

    task automatic expect_eq(input int got, input int exp, input string what);
        if (got != exp) begin
            $display("FAIL @%0t: %s -- got %0d, expected %0d", $time, what, got, exp);
            errors++;
        end
    endtask

    initial begin
        repeat (4) @(posedge clk);
        @(negedge clk);
        rst_n = 1'b1;

        // A lone 0, then a lone 1, with idle time between.
        send_bits(0, 1);
        idle(2 * BIT_CYC);
        send_bits(1, 1);
        idle(2 * BIT_CYC);

        expect_eq(highs.size(), 2, "pulse count after two single bits");
        expect_eq(highs[0], T0H_CYC, "'0' high time");
        expect_eq(highs[1], T1H_CYC, "'1' high time");

        // Back to back: 1,0,1,1,0. Slots must start exactly BIT_CYC apart.
        highs.delete();
        periods.delete();
        rise_at = -1;
        send_bits(5'b10110, 5);
        idle(2 * BIT_CYC);

        expect_eq(highs.size(), 5, "pulse count for 10110");
        expect_eq(highs[0], T1H_CYC, "bit 0 of 10110");
        expect_eq(highs[1], T0H_CYC, "bit 1 of 10110");
        expect_eq(highs[2], T1H_CYC, "bit 2 of 10110");
        expect_eq(highs[3], T1H_CYC, "bit 3 of 10110");
        expect_eq(highs[4], T0H_CYC, "bit 4 of 10110");
        expect_eq(periods.size(), 4, "slot boundaries for 10110");
        foreach (periods[i]) expect_eq(periods[i], BIT_CYC, "back-to-back slot length");

        if (errors != 0) begin
            $display("ws2812_timing_tb: %0d failure(s)", errors);
            $fatal(1, "ws2812_timing_tb FAILED");
        end
        $display("ws2812_timing_tb: SIM PASS");
        $finish;
    end

    // Watchdog, same pattern as rtl_counter_tb.
    initial begin
        #(CLK_HALF * 2 * 100_000);
        $fatal(1, "ws2812_timing_tb: timeout");
    end

endmodule

`default_nettype wire
