// AXI4-Lite slave for the NeoPixel peripheral: control registers plus a
// window onto the framebuffer.
//
//   0x000  ID         RO   0x4E454F50 ("NEOP")
//   0x004  CTRL       RW   [0] START (self-clearing)  [1] AUTO  [2] SOFT_RST (self-clearing)
//   0x008  STATUS     RO   [0] BUSY  [1] FRAME_DONE (write 1 to clear)  [15:8] LED index
//   0x00C  LED_COUNT  RW   1..MAX_LEDS
//   0x400+ FB[n]      RW   pixel n at 0x400 + 4n, 0x00GGRRBB
//
// Write channel: AW and W are accepted independently, in either order, into
// holding registers. The write commits once both are held, and BVALID then
// stays up until BREADY. All READY signals come straight from flops, so there
// is no combinational path from any VALID to any READY.
//
// Read channel: every read takes the same two clocks after AR is accepted --
// one to present the address to the framebuffer, one for its read latency --
// and RVALID then stays up until RREADY. Register reads don't need the wait,
// but a fixed latency is simpler than two paths.
//
// Known limitation: WSTRB is ignored, so a byte write becomes a word write.

`timescale 1 ps / 1 ps
`default_nettype none

module ws2812_axil_regs #(
    parameter int MAX_LEDS = 64
) (
    input  wire         s_axi_aclk,
    input  wire         s_axi_aresetn,
    // AW
    input  wire  [11:0] s_axi_awaddr,
    input  wire  [2:0]  s_axi_awprot,
    input  wire         s_axi_awvalid,
    output logic        s_axi_awready,
    // W
    input  wire  [31:0] s_axi_wdata,
    input  wire  [3:0]  s_axi_wstrb,
    input  wire         s_axi_wvalid,
    output logic        s_axi_wready,
    // B
    output logic [1:0]  s_axi_bresp,
    output logic        s_axi_bvalid,
    input  wire         s_axi_bready,
    // AR
    input  wire  [11:0] s_axi_araddr,
    input  wire  [2:0]  s_axi_arprot,
    input  wire         s_axi_arvalid,
    output logic        s_axi_arready,
    // R
    output logic [31:0] s_axi_rdata,
    output logic [1:0]  s_axi_rresp,
    output logic        s_axi_rvalid,
    input  wire         s_axi_rready,

    // To the core
    output logic                          start,       // 1-cycle pulse
    output logic                          soft_rst,    // 1-cycle pulse
    output logic [$clog2(MAX_LEDS+1)-1:0] led_count,
    input  wire                           busy,
    input  wire                           frame_done,  // 1-cycle pulse
    input  wire  [$clog2(MAX_LEDS+1)-1:0] led_index,
    // Framebuffer port A
    output logic [$clog2(MAX_LEDS)-1:0]   fb_addr,
    output logic [23:0]                   fb_wdata,
    output logic                          fb_we,
    input  wire  [23:0]                   fb_rdata
);

    localparam logic [31:0] ID_VALUE = 32'h4E45_4F50;   // "NEOP"
    localparam int          AW       = $clog2(MAX_LEDS);

    // Word addresses (byte address >> 2).
    localparam logic [9:0] A_ID        = 10'h000;
    localparam logic [9:0] A_CTRL      = 10'h001;
    localparam logic [9:0] A_STATUS    = 10'h002;
    localparam logic [9:0] A_LED_COUNT = 10'h003;

    // FB lives at 0x400..0x7FF: byte address bits [11:10] == 2'b01.
    function automatic logic is_fb(input logic [9:0] word);
        return (word[9:8] == 2'b01) && (word[7:0] < MAX_LEDS);
    endfunction

    // ---- Registers -------------------------------------------------------
    logic auto_q;
    logic done_flag;
    logic start_wr;                 // START written this cycle

    // AUTO restarts on frame_done; SOFT_RST suppresses it.
    assign start = start_wr || (auto_q && frame_done && !soft_rst);

    // ---- Write channel ---------------------------------------------------
    logic       aw_held, w_held;
    logic [9:0] aw_word;
    logic [31:0] w_data;
    logic       wr_commit;
    logic [1:0] rd_stage;           // 0 idle, 1 address out, 2 data back

    assign s_axi_awready = !aw_held;
    assign s_axi_wready  = !w_held;
    assign s_axi_bresp   = 2'b00;   // OKAY
    // Hold the write off while a read owns the framebuffer address.
    assign wr_commit     = aw_held && w_held && !s_axi_bvalid && (rd_stage == 0);

    // ---- Read channel ----------------------------------------------------
    logic [9:0] ar_word;

    assign s_axi_arready = (rd_stage == 0) && !s_axi_rvalid;
    assign s_axi_rresp   = 2'b00;

    // ---- Framebuffer port A ---------------------------------------------
    // Reads own the address while in flight; otherwise it follows the write.
    assign fb_addr  = (rd_stage != 0) ? AW'(ar_word[7:0]) : AW'(aw_word[7:0]);
    assign fb_wdata = w_data[23:0];
    assign fb_we    = wr_commit && is_fb(aw_word);

    always_ff @(posedge s_axi_aclk) begin
        start_wr <= 1'b0;
        soft_rst <= 1'b0;

        if (!s_axi_aresetn) begin
            aw_held      <= 1'b0;
            w_held       <= 1'b0;
            aw_word      <= '0;
            w_data       <= '0;
            s_axi_bvalid <= 1'b0;
            ar_word      <= '0;
            rd_stage     <= '0;
            s_axi_rvalid <= 1'b0;
            s_axi_rdata  <= '0;
            auto_q       <= 1'b0;
            done_flag    <= 1'b0;
            led_count    <= MAX_LEDS;
        end else begin
            // -- AW / W: latch each independently
            if (s_axi_awvalid && s_axi_awready) begin
                aw_held <= 1'b1;
                aw_word <= s_axi_awaddr[11:2];
            end
            if (s_axi_wvalid && s_axi_wready) begin
                w_held <= 1'b1;
                w_data <= s_axi_wdata;
            end

            // -- Commit
            if (wr_commit) begin
                aw_held      <= 1'b0;
                w_held       <= 1'b0;
                s_axi_bvalid <= 1'b1;
                case (aw_word)
                    A_CTRL: begin
                        start_wr <= w_data[0];
                        auto_q   <= w_data[1];
                        soft_rst <= w_data[2];
                    end
                    A_LED_COUNT: begin
                        if (w_data == 0)             led_count <= 1;
                        else if (w_data > MAX_LEDS)  led_count <= MAX_LEDS;
                        else                         led_count <= w_data[$bits(led_count)-1:0];
                    end
                    default: ;   // ID, STATUS (below), FB (fb_we), unmapped
                endcase
            end
            if (s_axi_bvalid && s_axi_bready) s_axi_bvalid <= 1'b0;

            // -- FRAME_DONE: set by hardware, cleared by writing 1. Set wins a tie
            //    so an event is never lost.
            if (wr_commit && aw_word == A_STATUS && w_data[1]) done_flag <= 1'b0;
            if (frame_done)                                    done_flag <= 1'b1;

            // -- AR / R
            case (rd_stage)
                2'd0: if (s_axi_arvalid && s_axi_arready) begin
                    ar_word  <= s_axi_araddr[11:2];
                    rd_stage <= 2'd1;
                end
                2'd1: rd_stage <= 2'd2;            // framebuffer samples fb_addr
                2'd2: begin                        // fb_rdata now valid
                    rd_stage     <= 2'd0;
                    s_axi_rvalid <= 1'b1;
                    if (is_fb(ar_word)) s_axi_rdata <= {8'h00, fb_rdata};
                    else case (ar_word)
                        A_ID:        s_axi_rdata <= ID_VALUE;
                        A_CTRL:      s_axi_rdata <= {30'b0, auto_q, 1'b0};
                        A_STATUS:    s_axi_rdata <= {16'b0, 8'(led_index), 6'b0, done_flag, busy};
                        A_LED_COUNT: s_axi_rdata <= 32'(led_count);
                        default:     s_axi_rdata <= 32'h0;
                    endcase
                end
                default: rd_stage <= 2'd0;
            endcase
            if (s_axi_rvalid && s_axi_rready) s_axi_rvalid <= 1'b0;
        end
    end

endmodule

`default_nettype wire
