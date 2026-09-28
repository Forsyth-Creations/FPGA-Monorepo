// Full-system testbench for the Phase 3 peripheral: drives ws2812_top over
// AXI4-Lite exactly as the PS would, and decodes its output pin with
// ws2812_monitor.
//
//   cd fpga && yarn simulate ws2812_axil_regs_tb
//
// The AXI tasks below are the whole bus protocol, written out by hand.

`timescale 1 ps / 1 ps
`default_nettype none

module ws2812_axil_regs_tb;

    localparam int CLK_HALF = 4000;   // 125 MHz
    localparam int NLEDS    = 3;

    localparam logic [11:0] ID        = 12'h000;
    localparam logic [11:0] CTRL      = 12'h004;
    localparam logic [11:0] STATUS    = 12'h008;
    localparam logic [11:0] LED_COUNT = 12'h00C;
    localparam logic [11:0] FB        = 12'h400;

    logic        clk    = 1'b0;
    logic        resetn = 1'b0;

    logic [11:0] awaddr  = '0;  logic awvalid = 1'b0;  logic awready;
    logic [31:0] wdata   = '0;  logic wvalid  = 1'b0;  logic wready;
    logic [1:0]  bresp;         logic bvalid;          logic bready = 1'b0;
    logic [11:0] araddr  = '0;  logic arvalid = 1'b0;  logic arready;
    logic [31:0] rdata;         logic [1:0] rresp;
    logic        rvalid;        logic rready  = 1'b0;
    logic        npx;

    logic        mon_done;
    int          mon_count;
    int          errors = 0;

    always #CLK_HALF clk = ~clk;

    ws2812_top #(.RESET_NS(2000)) dut (
        .s_axi_aclk(clk), .s_axi_aresetn(resetn),
        .s_axi_awaddr(awaddr), .s_axi_awprot(3'b000), .s_axi_awvalid(awvalid), .s_axi_awready(awready),
        .s_axi_wdata(wdata), .s_axi_wstrb(4'hF), .s_axi_wvalid(wvalid), .s_axi_wready(wready),
        .s_axi_bresp(bresp), .s_axi_bvalid(bvalid), .s_axi_bready(bready),
        .s_axi_araddr(araddr), .s_axi_arprot(3'b000), .s_axi_arvalid(arvalid), .s_axi_arready(arready),
        .s_axi_rdata(rdata), .s_axi_rresp(rresp), .s_axi_rvalid(rvalid), .s_axi_rready(rready),
        .npx_data(npx)
    );

    ws2812_monitor u_mon (.clk(clk), .serial(npx), .frame_done(mon_done), .count(mon_count));

    // ---- AXI4-Lite master tasks -----------------------------------------
    // Inputs change on the falling edge, and READY/VALID are checked there
    // too: a signal seen high at a falling edge means the handshake completes
    // on the rising edge that follows.
    //
    // Each channel is its own little process. aw_delay / w_delay hold one
    // channel back by some clocks, which is how the test sends W before AW.
    task automatic axil_write(input logic [11:0] addr, input logic [31:0] data,
                              input int aw_delay = 0, input int w_delay = 0);
        fork
            begin : aw_channel
                repeat (aw_delay) @(negedge clk);
                @(negedge clk);
                awaddr  = addr;
                awvalid = 1'b1;
                while (!awready) @(negedge clk);
                @(negedge clk);
                awvalid = 1'b0;
            end
            begin : w_channel
                repeat (w_delay) @(negedge clk);
                @(negedge clk);
                wdata  = data;
                wvalid = 1'b1;
                while (!wready) @(negedge clk);
                @(negedge clk);
                wvalid = 1'b0;
            end
            begin : b_channel
                @(negedge clk);
                bready = 1'b1;
                while (!bvalid) @(negedge clk);
                if (bresp != 2'b00) begin
                    $display("FAIL: BRESP %0b writing %03h", bresp, addr);
                    errors++;
                end
                @(negedge clk);
                bready = 1'b0;
            end
        join
    endtask

    task automatic axil_read(input logic [11:0] addr, output logic [31:0] data);
        @(negedge clk);
        araddr  = addr;
        arvalid = 1'b1;
        while (!arready) @(negedge clk);
        @(negedge clk);
        arvalid = 1'b0;
        rready  = 1'b1;
        while (!rvalid) @(negedge clk);
        data = rdata;
        @(negedge clk);
        rready = 1'b0;
    endtask

    task automatic expect_read(input logic [11:0] addr, input logic [31:0] mask,
                               input logic [31:0] exp, input string what);
        logic [31:0] got;
        axil_read(addr, got);
        if ((got & mask) !== exp) begin
            $display("FAIL: %s -- read %08h from %03h, expected %08h (mask %08h)", what, got, addr, exp, mask);
            errors++;
        end
    endtask

    // ---- Test ------------------------------------------------------------
    logic [23:0] px [NLEDS] = '{24'hFF0000, 24'h00FF00, 24'h0000FF};

    initial begin
        repeat (4) @(posedge clk);
        @(negedge clk);
        resetn = 1'b1;

        expect_read(ID, 32'hFFFF_FFFF, 32'h4E45_4F50, "ID");

        axil_write(LED_COUNT, NLEDS);
        expect_read(LED_COUNT, 32'hFFFF_FFFF, NLEDS, "LED_COUNT round-trip");

        // One pixel written in each channel ordering.
        axil_write(FB + 0, {8'h00, px[0]});         // AW and W together
        axil_write(FB + 4, {8'h00, px[1]}, 0, 5);   // AW first, W 5 clocks later
        axil_write(FB + 8, {8'h00, px[2]}, 5, 0);   // W first, AW 5 clocks later
        for (int i = 0; i < NLEDS; i++)
            expect_read(FB + 4 * i, 32'hFFFF_FFFF, {8'h00, px[i]}, "FB round-trip");

        // START: self-clears, BUSY rises then falls, FRAME_DONE latches.
        axil_write(CTRL, 32'h1);
        expect_read(CTRL,   32'h1, 32'h0, "START self-clears");
        expect_read(STATUS, 32'h1, 32'h1, "BUSY during frame");
        wait (mon_done);
        wait (!dut.busy);
        expect_read(STATUS, 32'h3, 32'h2, "idle with FRAME_DONE set");

        // W1C: writing 0 must not clear it, writing 1 must.
        axil_write(STATUS, 32'h0);
        expect_read(STATUS, 32'h2, 32'h2, "FRAME_DONE survives write of 0");
        axil_write(STATUS, 32'h2);
        expect_read(STATUS, 32'h2, 32'h0, "FRAME_DONE cleared by W1C");

        // The pixels on the wire are what software wrote.
        if (mon_count != NLEDS) begin $display("FAIL: monitor saw %0d pixels", mon_count); errors++; end
        for (int i = 0; i < NLEDS; i++)
            if (u_mon.pixels[i] !== px[i]) begin
                $display("FAIL: pixel %0d on wire %06h, expected %06h", i, u_mon.pixels[i], px[i]);
                errors++;
            end

        if (errors != 0) begin
            $display("ws2812_axil_regs_tb: %0d failure(s)", errors);
            $fatal(1, "ws2812_axil_regs_tb FAILED");
        end
        $display("ws2812_axil_regs_tb: SIM PASS");
        $finish;
    end

    initial begin
        #(CLK_HALF * 2 * 200_000);
        $fatal(1, "ws2812_axil_regs_tb: timeout -- an AXI handshake probably hung");
    end

endmodule

`default_nettype wire
