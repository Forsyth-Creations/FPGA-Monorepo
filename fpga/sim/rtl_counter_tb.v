// Testbench for rtl_counter.
//
//   cd fpga && yarn simulate            # batch, exits non-zero on failure
//   cd fpga && yarn simulate --gui      # same run, waveform viewer
//
// TICK_DIV is deliberately tiny here. The synthesized default of 23 needs
// 2**23 clocks per tick; at 4 the whole check -- two full rollovers of a
// 4-bit count -- costs 512 clocks and runs in well under a second.

`timescale 1 ps / 1 ps
`default_nettype none

module rtl_counter_tb;

    localparam integer WIDTH     = 4;
    localparam integer TICK_DIV  = 4;
    localparam integer TICK_CLKS = 1 << TICK_DIV;   // clocks per tick
    localparam integer ROLL      = 1 << WIDTH;      // count values before wrap
    localparam integer CLK_HALF  = 10000;           // 20 ns period = 50 MHz

    reg              clk    = 1'b0;
    reg              resetn = 1'b0;
    wire [WIDTH-1:0] count;

    integer errors = 0;
    integer t;

    always #CLK_HALF clk = ~clk;

    rtl_counter #(
        .WIDTH    (WIDTH),
        .TICK_DIV (TICK_DIV)
    ) dut (
        .clk    (clk),
        .resetn (resetn),
        .count  (count)
    );

    // Advance n rising edges, then settle past the nonblocking updates so
    // `count` reads as the value the edge just produced.
    task step(input integer n);
        integer k;
        begin
            for (k = 0; k < n; k = k + 1) begin
                @(posedge clk);
            end
            #1;
        end
    endtask

    task check(input [WIDTH-1:0] got, input [WIDTH-1:0] exp, input [64*8-1:0] what);
        begin
            if (got !== exp) begin
                $display("FAIL @%0t: %0s -- got %0d, expected %0d",
                         $time, what, got, exp);
                errors = errors + 1;
            end
        end
    endtask

    initial begin
        // Held in reset.
        resetn = 1'b0;
        step(4);
        check(count, 0, "count held at zero during reset");

        // Release on a falling edge so the first rising edge sees resetn high.
        @(negedge clk);
        resetn = 1'b1;

        // Two full rollovers, checking the count is stable through the
        // prescaler and moves by exactly one on the tick.
        for (t = 1; t <= 2 * ROLL; t = t + 1) begin
            step(TICK_CLKS - 1);
            check(count, (t - 1) % ROLL, "count stable one clock before tick");
            step(1);
            check(count, t % ROLL, "count advanced on tick");
        end

        // Reset is synchronous: it clears the count on the next rising edge.
        @(negedge clk);
        resetn = 1'b0;
        step(1);
        check(count, 0, "count cleared by synchronous reset");

        if (errors != 0) begin
            $display("rtl_counter_tb: %0d failure(s)", errors);
            $fatal(1, "rtl_counter_tb FAILED");
        end

        // "SIM PASS" is the contract scripts/sim.sh checks for; xsim's own
        // exit status is 0 whether or not the testbench called $fatal.
        $display("rtl_counter_tb: SIM PASS -- %0d ticks checked over %0d clocks",
                 2 * ROLL, 2 * ROLL * TICK_CLKS);
        $finish;
    end

    // Watchdog: the run above is bounded, so reaching this means a hang.
    initial begin
        #(CLK_HALF * 2 * 100000);
        $fatal(1, "rtl_counter_tb: timeout");
    end

endmodule

`default_nettype wire
