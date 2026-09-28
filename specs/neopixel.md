# WS2812B NeoPixel driver — implementation spec

Status: **reference implementation on branch `neopixel-reference`.** Every code
sample below is taken from a file on that branch that has been simulated,
synthesized, and (Phase 3–4) built and deployed. Where the original plan turned
out to be wrong, the correction is marked **⚠️ Learned the hard way**.

Target: one WS2812B strip, up to 64 LEDs, driven from the PL on a Zybo Z7-20,
controlled from `no_std` Rust on the PS over AXI4-Lite.

### Using the reference branch

The branch has one commit per phase, so you can see each phase on its own:

```
git log --oneline master..neopixel-reference
git show <commit> --stat          # which files a phase touched
git diff master neopixel-reference -- fpga/scripts/sim.sh
```

| Commit (oldest first) | What it adds |
|---|---|
| `sim.sh: compile .sv files as SystemVerilog` | prerequisite fix, see [Phase 1](#phase-1--rtl-and-simulation-only) |
| `ws2812: Phase 1 -- ...` | PHY, framebuffer, frame FSM, monitor, two testbenches |
| `ws2812: Phase 2 -- ...` | pattern generator, no-bus `ws2812_top`, its testbench |
| `ws2812: Phase 3 -- ...` | AXI4-Lite register block, bus-facing `ws2812_top`, system testbench |
| `xil_bindings: ws2812 driver` | the Rust driver |
| `ws2812: package as IP, add to block design, drive from firmware` | packaging, BD, `top.v`, XDC, `main.rs` |

If you want to write it yourself and use the branch only to check your work,
read the prose, try each file yourself, and only then open the sample. The
samples are one correct answer, not the only one.

### How to read SystemVerilog if you are new to it

Four constructs cover almost everything below:

```systemverilog
logic [7:0] x;                 // an 8-bit signal. "logic" = can be 0, 1, X, Z.

assign y = a && b;             // combinational: y is *always* a && b, like a wire.

always_ff @(posedge clk) begin // sequential: on every rising clock edge...
    q <= d;                    // ...q takes the value d had just before the edge.
end                            // "<=" means all updates in the block happen together.

always_comb begin              // combinational logic written like code;
    if (s) y = a; else y = b;  // "=" here, and every path must assign y.
end
```

The mental model that matters: **everything runs in parallel, all the time.**
An `always_ff` block is not a function that gets called — it is a bank of
flip-flops that all update at once on each clock edge. A module is a circuit,
not a program.

---

## 0. The protocol, and why there is no clock

WS2812B is **single-wire and self-clocked**. One pin carries clock and data
together, encoded as *pulse width*. Each bit occupies a fixed 1.25 µs slot; the
line rises at the start of the slot, and how long it stays high is the bit.

```
  '0':  ┌────┐                      '1':  ┌─────────┐
        │0.4 │      0.85 µs               │  0.8 µs │   0.45 µs
      ──┘    └───────────────────        ──┘         └───────────
        |<------ 1.25 µs ----->|            |<---- 1.25 µs ---->|

  RESET / latch:  line held LOW for >280 µs
  Wire format:    24 bits per LED, G7..G0 R7..R0 B7..B0, MSB first
  Topology:       daisy chain — LED 0 consumes the first 24 bits and
                  forwards everything after them down the strip
```

Two consequences that shape the whole design:

- **There is no clock divider anywhere.** The core primitive is a *bit-slot
  sequencer*: a counter that runs once per bit, plus two comparators deciding
  when the line falls.
- **The gap between bits is load-bearing.** Leave the line low for >50 µs
  mid-frame and the strip latches early, showing a half-updated frame. Bits must
  go out back-to-back with zero idle cycles between slots. This is the bug that
  is invisible in a strip of lights and obvious in a waveform.

### Cycle counts at 125 MHz (8.000 ns/cycle)

| Interval | Target | Cycles | Actual | Margin |
|---|---|---|---|---|
| Bit slot (`BIT_CYC`) | 1.250 µs | **156** | 1.248 µs | ±600 ns allowed |
| `'0'` high (`T0H_CYC`) | 0.40 µs | **50** | 0.400 µs | ±150 ns allowed |
| `'1'` high (`T1H_CYC`) | 0.80 µs | **100** | 0.800 µs | ±150 ns allowed |
| Reset gap (`RESET_CYC`) | ≥280 µs | **37500** | 300 µs | covers WS2812B-V5 |

Use 0.4 / 0.8 µs rather than the datasheet's nominal 0.35 / 0.70. Those sit in
the middle of the valid window for every WS2812B revision, so one build works on
whatever strip actually turned up in the envelope.

Derive them in RTL from a `CLK_HZ` parameter rather than hardcoding 50 and 100:

```systemverilog
localparam int CYC_PER_US = CLK_HZ / 1_000_000;          // 125
localparam int T0H_CYC    = CYC_PER_US * T0H_NS / 1000;  // 125 * 400  / 1000 = 50
localparam int T1H_CYC    = CYC_PER_US * T1H_NS / 1000;  // 125 * 800  / 1000 = 100
localparam int BIT_CYC    = CYC_PER_US * BIT_NS / 1000;  // 125 * 1250 / 1000 = 156
```

Integer math at elaboration time, so it costs nothing in hardware. The numbers
stay correct if the clock ever changes, and a reader can see where they came
from. Divide by 1 000 000 *first*: `125_000_000 * 1250` would overflow a 32-bit
`int`.

Frame time for 64 LEDs: 64 × 24 × 1.248 µs + 300 µs ≈ **2.2 ms** → ~450 fps
ceiling. Never the bottleneck.

---

## Module hierarchy

```
top.v                                        (existing — edited in the last commit)
 └─ design_1_i   block design
     └─ ws2812_ctrl_0   ws2812_top.sv        packaged IP: forsyth:ip:ws2812_ctrl:1.0
         ├─ u_regs   ws2812_axil_regs.sv     AXI4-Lite slave: ID/CTRL/STATUS/LED_COUNT
         ├─ u_fb     ws2812_framebuffer.sv   true dual-port RAM, MAX_LEDS × 24b
         ├─ u_fsm    ws2812_frame_fsm.sv     walks pixels, serializes, times reset gap
         └─ u_phy    ws2812_timing.sv        bit-slot counter + pulse-width encoder
```

In Phases 1–2 the files live in `fpga/rtl/`. Phase 3c moves them to
`fpga/ip/ws2812_ctrl/src/`, which is where they are at the tip of the branch.

Two structural rules worth carrying into future peripherals:

1. **The timing-critical part is the smallest module.** `ws2812_timing` is the
   only thing in the design that knows about nanoseconds. Everything above it
   counts *bits*.
2. **Layers meet at ready/valid handshakes**, never at shared counters. That is
   what lets you testbench the PHY standing completely alone, and what would let
   you drop in an APA102 PHY later without touching the FSM.

### The ready/valid handshake, since everything uses it

```
            ┌───┐   ┌───┐   ┌───┐   ┌───┐   ┌───┐
  clk     ──┘   └───┘   └───┘   └───┘   └───┘   └──
  valid   ______/‾‾‾‾‾‾‾‾‾‾‾‾‾‾‾‾‾‾‾‾‾‾‾‾\__________   sender: "I have data"
  ready   ‾‾‾‾‾‾‾‾‾‾‾‾\_______________/‾‾‾‾‾‾‾‾‾‾‾‾   receiver: "I can take it"
  data    ======<  A  ====================>=========
                                        ^
                  transfer happens on the rising edge where BOTH are high
```

Rules: the sender holds `valid` and `data` steady until the transfer happens;
the receiver may raise or drop `ready` whenever it likes. AXI uses exactly this
on each of its five channels.

### House conventions (from the existing RTL)

- `` `timescale 1 ps / 1 ps `` and `` `default_nettype none `` at the top of every
  file, `` `default_nettype wire `` at the bottom.
- File name == module name, lowercase snake_case.
- Instances named `u_<module>`.
- A comment block at the top of each file explaining the *why*, not the what.
  `fpga/rtl/rtl_counter.v` is the reference for tone and depth.
- Anything a testbench might want to shrink is a real `parameter`.
- **Inputs are declared `input wire`, outputs `output logic`.** See the next box.

> ⚠️ **Learned the hard way — `input logic` + `` `default_nettype none `` fails
> synthesis.** The original port lists in this spec used `input logic`. xsim
> only *warns* about it (`VRFC 10-1103`), so every testbench passed — then
> Vivado synthesis rejected every file with `[Synth 8-6735] net type must be
> explicitly specified`. With implicit nets turned off, an input needs an
> explicit net type: write `input wire`. Outputs driven from `always_ff` stay
> `output logic`. Lesson: a passing simulation says nothing about whether
> synthesis will accept the code, so synthesize early.

---

## Phase 0 — record the pins

- [x] Fill in the `PMOD port:` stub in `datasheets/README.md` *(your working
      copy has this; it isn't committed on either branch)*

The Zybo Z7-20 has six Pmod headers and they are **not** interchangeable:

| Header | Type | Connected to | Use here? |
|---|---|---|---|
| JA | XADC Pmod | PL, shares XADC analog inputs | works, but avoid |
| JB, JC, JD | High-speed Pmod | PL, differential-capable pairs | works |
| JE | Standard Pmod | PL, single-ended, series-protected | **use this** |
| JF | MIO Pmod | PS MIO — **unreachable from the PL** | no |

JE is the pick: plain single-ended PL I/O with series protection resistors and
no shared function to trip over. JF is a silent dead end — a signal in your RTL
can never reach it, because MIO pins belong to the PS, not the fabric.

From Digilent's [`Zybo-Z7-Master.xdc`](https://github.com/Digilent/digilent-xdc)
(checked against the file, not memory):

```tcl
#set_property -dict { PACKAGE_PIN V12   IOSTANDARD LVCMOS33 } [get_ports { je[0] }]; #IO_L4P_T0_34 Sch=je[1]
```

Note the off-by-one: Digilent's `je[0]` is the pin silkscreened **1** on the
board (`Sch=je[1]`). **JE1 = `V12`.**

### Wiring notes for the same file

- **Strip GND must tie to Zybo GND.** A floating ground is the single most common
  cause of "it flickers randomly."
- Strip 5V comes from its own supply, not from the Zybo. 64 LEDs at full white is
  ~3.8 A; the board cannot source that.
- Level shifter (74AHCT125 or 74HCT245): **VCC on the 5V rail**, input side from
  JE1. An HCT part powered at 3.3 V does not shift anything — it just passes the
  signal through and you have wasted an afternoon.
- Your `datasheets/README.md` lists a **TXS0108E**. Be careful with that part
  here: it's an auto-direction shifter with weak one-shot edge accelerators,
  meant for open-drain buses and light loads. It often works with a short wire
  to the first LED, and it's often the cause when things act strangely with a
  longer one. A 74AHCT125 is the usual choice for a push-pull 800 kHz line.

---

## Phase 1 — RTL and simulation only

No board, no bitstream, no bus. This is where most of the learning is, and all of
it is free and fast.

`fpga/scripts/sim.sh` globs `rtl/*.sv` and `sim/*.sv`, and
`fpga/scripts/build.tcl` globs `rtl/*.sv`. `turbo.json`'s `simulate` task lists
`rtl/**` and `sim/**` as inputs, so caching stays correct too.

> ⚠️ **Learned the hard way — `sim.sh` compiled `.sv` files as plain Verilog.**
> The glob picked the files up, but `xvlog` parses everything as Verilog-2001
> unless given `-sv`, so the very first SystemVerilog file failed with
> `'logic' is an unknown type`. `-sv` applies to a whole `xvlog` call, so the
> fix compiles the two languages in two passes into the same library
> (first commit on the branch):
>
> ```bash
> V_SOURCES=(); SV_SOURCES=()
> for f in "${SOURCES[@]}"; do
>     case "$f" in *.sv) SV_SOURCES+=("$f") ;; *) V_SOURCES+=("$f") ;; esac
> done
> [[ ${#V_SOURCES[@]}  -gt 0 ]] && xvlog --relax     "${V_SOURCES[@]}"
> [[ ${#SV_SOURCES[@]} -gt 0 ]] && xvlog --relax -sv "${SV_SOURCES[@]}"
> ```

### 1a. `ws2812_timing.sv` — the bit-slot PHY

- [x] written
- [x] `yarn simulate ws2812_timing_tb` prints `SIM PASS`

Behaviour:

- Idle: `serial = 0`, `bit_ready = 1`.
- On `bit_valid && bit_ready`: latch `bit_val`, start `cnt` at 0, drop
  `bit_ready`.
- `cnt` increments every cycle. At `cnt == BIT_CYC-1` the slot ends.
- `serial` is high while `cnt < (latched_bit ? T1H_CYC : T0H_CYC)`.

**The one hard requirement:** `bit_ready` must be high again on the *final cycle*
of a slot, not the cycle after, so a waiting upstream handshake starts the next
slot with no gap. Get this wrong and you get a 1-cycle hole between every bit —
8 ns, harmless on the wire, but it means your slot is 157 cycles not 156, and it
is the same mistake that becomes a 3744-cycle hole at pixel boundaries in the
FSM. Prove it in the testbench.

That comparator line *is* the encoder. If you find yourself writing a state
machine with `S_HIGH` / `S_LOW` states, back up — the counter already is the
state.

The whole module (header comment trimmed):

```systemverilog
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

    logic [$clog2(BIT_CYC)-1:0] cnt;       // $clog2(156) = 8 bits
    logic                       busy;      // a slot is in progress
    logic                       cur_bit;   // the bit being sent

    logic last;
    logic fire;
    assign last      = busy && (cnt == BIT_CYC - 1);
    assign bit_ready = !busy || last;      // <-- ready on the LAST cycle, not after
    assign fire      = bit_valid && bit_ready;

    always_ff @(posedge clk) begin
        if (!rst_n) begin
            busy    <= 1'b0;
            cnt     <= '0;
            cur_bit <= 1'b0;
        end else if (fire) begin           // start a slot (possibly back-to-back)
            busy    <= 1'b1;
            cnt     <= '0;
            cur_bit <= bit_val;
        end else if (last) begin           // slot over, nothing waiting
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
```

Two things worth noticing:

- The `if / else if` order is the priority. `fire` is checked before `last`, so
  when a new bit is waiting on the final cycle, the slot restarts instead of
  going idle. That ordering is the zero-gap guarantee.
- **`serial` is registered**, which is a change from the original plan (it said
  "combinational off `cnt`"). A comparator's output can glitch for a fraction of
  a nanosecond while `cnt`'s bits change, and this signal leaves the chip, so a
  glitch could reach the LED. Registering it delays every edge by exactly one
  cycle, so the pulse widths stay the same. Registering outputs that go off-chip
  is a good habit in general.

### 1b. `fpga/sim/ws2812_timing_tb.sv`

**The testbench contract** (`fpga/scripts/sim.sh`): print the literal string
`SIM PASS`, and emit nothing matching `^(Fatal|Error|ERROR):`. `xsim` exits 0
whether or not the testbench called `$fatal`, so the log is the only verdict.
Include a watchdog `initial` that `$fatal`s on timeout —
`fpga/sim/rtl_counter_tb.v` is the pattern to copy.

Checks:

- Send `0` → measure high pulse → assert `== T0H_CYC` (50).
- Send `1` → assert `== T1H_CYC` (100).
- Send `1,0,1,1,0` back-to-back → assert each pulse width *and* that slot starts
  are exactly 156 cycles apart, i.e. no dead cycles.

The testbench has two halves. A **measurer** watches the line and records what
it sees, knowing nothing about how the bits were sent:

```systemverilog
int cyc       = 0;
int rise_at   = -1;
int highs[$];        // "[$]" is a queue: a list you can push_back() onto
int periods[$];
logic prev    = 1'b0;

always @(posedge clk) begin
    cyc++;
    if (serial && !prev) begin                        // rising edge
        if (rise_at >= 0) periods.push_back(cyc - rise_at);
        rise_at = cyc;
    end
    if (!serial && prev) highs.push_back(cyc - rise_at);  // falling edge
    prev = serial;
end
```

A **driver** task feeds bits, holding `bit_valid` high the whole time so the PHY
never runs out of bits:

```systemverilog
// Inputs change on the FALLING edge, well away from the rising edge that
// samples them. A signal seen high at a falling edge means the handshake
// completes on the next rising edge.
task automatic send_bits(input logic [31:0] bits, input int n);
    for (int i = n - 1; i >= 0; i--) begin
        @(negedge clk);
        bit_val   = bits[i];
        bit_valid = 1'b1;
        while (!bit_ready) @(negedge clk);
    end
    @(negedge clk);
    bit_valid = 1'b0;
endtask
```

Then the test itself just reads like the checklist:

```systemverilog
send_bits(5'b10110, 5);
idle(2 * BIT_CYC);

expect_eq(highs[0], T1H_CYC, "bit 0 of 10110");
expect_eq(highs[1], T0H_CYC, "bit 1 of 10110");
// ...
foreach (periods[i]) expect_eq(periods[i], BIT_CYC, "back-to-back slot length");
```

**Proof the test has teeth:** changing the PHY to `assign bit_ready = !busy;`
(the classic mistake) makes it fail with
`back-to-back slot length -- got 157, expected 156`. Try it yourself.
A test you have never seen fail hasn't shown you it can catch anything.

Run it, then run it with `--gui` and *look at the waveform*. The entire reason
for starting here is to see the two pulse widths with your own eyes.

### 1c. `fpga/sim/ws2812_monitor.sv` — the receiver

- [x] written

**Highest-value file in the project.** A module that does what the LED does:
watch `serial`, measure each high pulse, classify it against a threshold
halfway between `T0H_CYC` and `T1H_CYC` (75 cycles), assemble 24-bit words, and
treat a long low period as end-of-frame. Exposes the decoded pixels as an array
plus a `frame_done` pulse and a count.

Every testbench above this point then becomes: write pixels in, kick the FSM,
compare the monitor's output against what you wrote. That checks the *protocol*
rather than your assumptions about your own implementation — the same job a
logic analyzer does, in software, for free, on every commit.

The reference monitor also checks the gap rule directly: inside a frame, every
slot must start exactly `BIT_CYC` after the previous one, or it reports an
`$error`. So the pixel-boundary trap in 1e fails any testbench that uses the
monitor, with a message saying which bit of which pixel was late.

The core of it:

```systemverilog
always @(posedge clk) begin
    frame_done <= 1'b0;
    if (since_rise >= 0) since_rise++;

    if (serial && !prev) begin                     // start of a slot
        if (since_rise >= 0 && since_rise != BIT_CYC)
            $error("ws2812_monitor: slot %0d of pixel %0d started %0d clocks after the previous one, expected %0d",
                   nbits, npix, since_rise, BIT_CYC);
        since_rise = 0;
    end

    if (serial) begin
        hi_cnt++;
        lo_cnt = 0;
    end else begin
        if (prev) begin                            // pulse just ended: classify it
            shreg = {shreg[22:0], (hi_cnt > THRESH_CYC)};
            nbits++;
            if (nbits == 24) begin
                pixels[npix] = shreg;
                npix++;
                nbits = 0;
            end
        end
        hi_cnt = 0;
        lo_cnt++;

        if (lo_cnt == LATCH_CYC && since_rise >= 0) begin   // long low: frame over
            count      <= npix;
            frame_done <= 1'b1;
            npix = 0; nbits = 0; since_rise = -1;
        end
    end
    prev = serial;
end
```

Blocking `=` is fine here and makes the code read top to bottom like software.
It is simulation-only (it lives in `sim/`) and never gets synthesized. Don't use
this style in `rtl/`.

**Choosing `LATCH_CYC`.** It has to be longer than the longest low time *inside*
a slot (156 − 50 = 106 cycles), and shorter than the reset gap your testbench
uses. With the testbenches' shrunk 2 µs gap (250 cycles), 200 sits comfortably
in between.

### 1d. `ws2812_framebuffer.sv`

- [x] written

```systemverilog
module ws2812_framebuffer #(
    parameter int MAX_LEDS = 64
) (
    input  wire                         clk,
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
```

That is the entire file. Vivado recognises this shape (an array, read and
written inside clocked blocks) and builds it from a block RAM instead of
flip-flops.

**Do not reset the memory array.** A reset on the array forces Vivado to build it
out of flip-flops instead of block RAM — the classic way to spend 1536 FFs on 64
pixels. Synthesis of the reference design confirms it: the whole Phase 3 core
is **1 Block RAM tile, 170 LUTs, 174 flip-flops**.

**Read latency is one cycle**: `b_rdata` is valid the cycle *after* `b_addr` is
presented. The FSM must account for it. Shifting out the previous pixel's data
is the standard first bug here.

### 1e. `ws2812_frame_fsm.sv`

- [x] written
- [x] `yarn simulate ws2812_frame_fsm_tb` prints `SIM PASS`

States: `IDLE → LOAD → SHIFT → RESET → IDLE`.

- `LOAD`: load `shreg` with pixel 0 and point `fb_addr` at pixel 1.
- `SHIFT`: drive `bit_val = shreg[23]`, `bit_valid = 1`. On each handshake,
  shift left. After 24 bits, either reload `shreg` with the next pixel or, if
  that was the last pixel, go to `RESET`.
- `RESET`: deassert `bit_valid` (the PHY idles the line low), count `RESET_CYC`
  (37500 — needs a 16-bit counter), pulse `frame_done`, return to `IDLE`.

`busy` is high in every state except `IDLE`.

**The pixel-boundary trap.** A naive implementation returns to a `FETCH` state
between pixels, costing a cycle or two of line-low time every 24 bits. That
stretches the 24th slot and, at worst, accumulates. The fix is a prefetch: while
pixel *n* is shifting out, `fb_addr` already points at *n+1*. You have 24 × 156
= 3744 cycles of slack, so there is no excuse to be late.

The plan originally called for a separate `next_pixel` register. It turns out
you don't need one: the framebuffer's `b_rdata` *is* a register, and it keeps
showing `mem[fb_addr]` for as long as `fb_addr` stays put. So when the last bit
of pixel *n* is handed over, `shreg <= fb_rdata` in the same clock. Zero dead
cycles, one register fewer.

The heart of the FSM:

```systemverilog
typedef enum logic [1:0] { IDLE, LOAD, SHIFT, RESET } state_t;
state_t state;

assign busy      = (state != IDLE);
assign bit_val   = shreg[23];            // always offer the MSB
assign bit_valid = (state == SHIFT);
assign fire      = bit_valid && bit_ready;

always_ff @(posedge clk) begin
    frame_done <= 1'b0;                  // default: a 1-cycle pulse
    if (!rst_n) begin
        // ... everything to zero, state <= IDLE
    end else begin
        case (state)
            IDLE: begin
                fb_addr   <= '0;         // so fb_rdata already holds pixel 0
                led_index <= '0;
                if (start && led_count != 0) begin
                    count_q <= (led_count > MAX_LEDS) ? MAX_LEDS : led_count;
                    state   <= LOAD;
                end
            end

            LOAD: begin
                shreg   <= fb_rdata;     // pixel 0
                fb_addr <= 1;            // prefetch pixel 1
                bit_cnt <= '0;
                state   <= SHIFT;
            end

            SHIFT: if (fire) begin
                if (bit_cnt != 23) begin
                    shreg   <= shreg << 1;
                    bit_cnt <= bit_cnt + 1'b1;
                end else if (led_index == count_q - 1) begin
                    reset_cnt <= '0;     // that was the last bit of the frame
                    state     <= RESET;
                end else begin
                    shreg     <= fb_rdata;          // prefetched: zero dead cycles
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
```

Details worth copying:

- **`led_count` is latched into `count_q` at `start`.** If software changes
  `LED_COUNT` mid-frame, the frame in flight isn't affected.
- **The reset gap only counts while `bit_ready` is high.** The FSM enters
  `RESET` the moment the PHY *accepts* the last bit, 156 cycles before that
  bit has finished sending. Counting only while the PHY is ready means the line
  is guaranteed low for the full `RESET_CYC` after the last bit ends.

Build it the naive way first and **look at the stretched slot in the waveform**
before you fix it. With the reference monitor in place, the naive version also
fails the testbench with a message naming the late slot.

### 1f. `fpga/sim/ws2812_frame_fsm_tb.sv`

- [x] written, passes

Instantiate FSM + framebuffer + timing + monitor. Preload the framebuffer with
distinguishable values (`0xFF0000`, `0x00FF00`, `0x0000FF` — deliberately *not*
symmetric, so a byte-order bug shows), pulse `start`, wait for `frame_done`, and
assert the monitor decoded exactly those three words in that order. The
reference then sends a second frame (`0x123456`, `0xA5C381`, `0x800001`) to
prove the FSM comes back out of `RESET` cleanly.

```systemverilog
ws2812_frame_fsm #(.MAX_LEDS(MAX_LEDS), .RESET_NS(2000)) u_fsm ( ... );
//                                      ^^^^^^^^^^^^^^^ 2 us instead of 300 us

for (int i = 0; i < NLEDS; i++) fb_write(i, frame1[i]);
run_frame();                  // pulse start, wait for frame_done
expect_frame(frame1);         // compare u_mon.pixels[] against what we wrote
```

`u_mon.pixels[i]` is a **hierarchical reference**: the testbench reaching
inside the monitor instance to read its array. That's fine in testbenches and
not allowed in synthesizable code.

**Shrink the right parameters.** The repo's convention is `rtl_counter`'s
`TICK_DIV` — 23 synthesized, 4 in the testbench. Here the knobs are different:
leave the *bit* timing at its real values, because that is the thing under
test. Shrink `led_count` to 3 and `RESET_NS` to 2000 instead.

- 3 pixels = 72 bits ≈ 11,000 cycles → sub-second.
- 64 pixels at real reset timing = 277,000 cycles → a wait, made worse by
  `log_wave -recursive *` in `fpga/scripts/sim.tcl`.

> ⚠️ **Learned the hard way — watchdog arithmetic overflows.** A watchdog like
> `#(8000 * 2_000_000)` is 32-bit `int` math, and 1.6 × 10¹⁰ overflows it. The
> delay silently wraps to something tiny and the watchdog kills a healthy
> simulation. Force 64-bit math with `#(64'd8000 * 2_000_000)`, or keep the
> product under ~2.1 × 10⁹.

**Exit criterion for Phase 1:** `ws2812_frame_fsm_tb` passes, and you can open
the waveform and point at a `1` bit and a `0` bit.

---

## Phase 2 — first light, no bus

Prove the electrical path and real-silicon timing before AXI adds variables.

- [x] `ws2812_pattern.sv` — switches pick a colour; auto-pulses `start` every
      2²¹ clocks (16.8 ms, ~60 fps)
- [x] `ws2812_top.sv` (Phase 2 version) — framebuffer + FSM + timing + pattern
- [x] `ws2812_top_tb.sv` — end-to-end: switches in, decoded pixels out
- [ ] `top.v` + XDC for Phase 2 — **skipped on the reference branch**; it went
      straight to the Phase 3 wiring once the pin was known (see Phase 3d)
- [ ] strip lights from Phase 2 alone (not tried: the branch went straight to
      Phase 3 on hardware, which drives the same pin)

The Phase 2 commit on the branch has these files. The Phase 3 commit removes
the pattern generator and replaces `ws2812_top`, so use
`git show <phase-2-commit>:fpga/rtl/ws2812_pattern.sv` to read them later.

The pattern generator rewrites the framebuffer continuously, one pixel per
clock. That avoids having to get a "write, then start" ordering right. One
pixel is drawn full white and moves one LED per frame, which proves the pixels
arrive *in order*, not just that some light came on:

```systemverilog
assign lvl = sw[3] ? 8'h40 : 8'h08;          // sw[3] = bright

always_comb begin
    if (addr == dot) begin
        r = 8'hFF; g = 8'hFF; b = 8'hFF;     // the moving dot
    end else begin
        r = sw[0] ? lvl : 8'h00;
        g = sw[1] ? lvl : 8'h00;
        b = sw[2] ? lvl : 8'h00;
    end
end

assign fb_wdata = {g, r, b};                 // wire order is G, R, B
assign start    = (div == '1);               // free-running prescaler wraps

always_ff @(posedge clk) begin
    div  <= div + 1'b1;
    addr <= (addr == NUM_LEDS - 1) ? '0 : addr + 1'b1;
    if (frame_done) dot <= (dot == NUM_LEDS - 1) ? '0 : dot + 1'b1;
end
```

> ⚠️ **Learned the hard way — "tie `rst_n` high" means nothing is ever reset.**
> The plan said to tie the core's reset high in Phase 2 (for the good reason in
> `top.v`: the BD's reset is held until the PS boots). But then the FSM's
> `state` register has no reset at all. In simulation it starts as `X`
> (unknown) and stays `X` forever, and the testbench just times out. Real
> silicon happens to power up at 0, but that's luck, not design. The fix is a
> tiny power-on reset inside `ws2812_top`. Xilinx FPGAs load every flip-flop's
> initial value when the bitstream is configured, so this is legal
> synthesizable code:
>
> ```systemverilog
> logic [3:0] por = '0;                       // starts at 0000 at configuration
> always_ff @(posedge clk) por <= {por[2:0], 1'b1};   // fills with 1s over 4 clocks
> assign rst_q_n = rst_n && por[3];           // held in reset until then
> ```

`FRAME_DIV` is a parameter of `ws2812_top` so the testbench can shrink it to 17
(a frame every 131 072 clocks rather than 2 million).

Notes:

- No timing constraint on `npx_data`. It is not a synchronous interface, so the
  unconstrained-output warning is expected and harmless.

**If it doesn't light, check in this order:** ground (common ground to the Zybo),
then the level shifter (VCC on 5 V, not 3.3 V), then scope JE1 directly. Phase 1
already proved the waveform is right, which is exactly what earns you the right
to look outward instead of doubting the RTL.

---

## Phase 3 — AXI4-Lite slave, packaged as IP

### 3a. `ws2812_axil_regs.sv`

- [x] written
- [x] `yarn simulate ws2812_axil_regs_tb` prints `SIM PASS`

Written by hand. Five channels (AW, W, B, AR, R); the reference is ~190 lines
with comments. The rules that actually bite, and how the reference handles
each:

**`AWVALID` and `WVALID` are independent.** You don't get to assume address and
data arrive together or in a particular order. Latch each one into a holding
register and commit the write once both have arrived:

```systemverilog
assign s_axi_awready = !aw_held;      // READY comes straight from a flop:
assign s_axi_wready  = !w_held;       // no combinational VALID -> READY path

// Commit when both halves are here, the last response has been taken, and
// no read currently owns the framebuffer address.
assign wr_commit = aw_held && w_held && !s_axi_bvalid && (rd_stage == 0);

always_ff @(posedge s_axi_aclk) begin
    if (s_axi_awvalid && s_axi_awready) begin
        aw_held <= 1'b1;
        aw_word <= s_axi_awaddr[11:2];          // decode on word address
    end
    if (s_axi_wvalid && s_axi_wready) begin
        w_held <= 1'b1;
        w_data <= s_axi_wdata;
    end
    if (wr_commit) begin
        aw_held      <= 1'b0;
        w_held       <= 1'b0;
        s_axi_bvalid <= 1'b1;                   // ...and HOLD it until BREADY:
        case (aw_word) /* ... */ endcase
    end
    if (s_axi_bvalid && s_axi_bready) s_axi_bvalid <= 1'b0;
    // ...
end
```

**`BVALID` must stay asserted until `BREADY`**, and the same goes for
`RVALID`/`RREADY`. Dropping it after one cycle is the classic "works in sim,
hangs on hardware" bug. Above, `bvalid` is only ever cleared by the handshake.

**Framebuffer reads have RAM latency.** The easiest correct approach is to make
*every* read take the same fixed number of cycles: one to present the address,
one for the RAM, then drive `RVALID`:

```systemverilog
assign s_axi_arready = (rd_stage == 0) && !s_axi_rvalid;

case (rd_stage)
    2'd0: if (s_axi_arvalid && s_axi_arready) begin
        ar_word  <= s_axi_araddr[11:2];
        rd_stage <= 2'd1;
    end
    2'd1: rd_stage <= 2'd2;                    // framebuffer samples fb_addr
    2'd2: begin                                // fb_rdata now valid
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
endcase
if (s_axi_rvalid && s_axi_rready) s_axi_rvalid <= 1'b0;
```

The framebuffer has one port for the bus, shared by reads and writes. A read in
flight owns the address, and writes wait for it (`rd_stage == 0` in
`wr_commit`):

```systemverilog
assign fb_addr = (rd_stage != 0) ? AW'(ar_word[7:0]) : AW'(aw_word[7:0]);
```

**`WSTRB` is ignored**: a byte write from software silently becomes a full-word
write. That's a known limitation, noted in the file header.

### Register map (4 KB window)

| Offset | Name | Access | Contents |
|---|---|---|---|
| `0x000` | `ID` | RO | `0x4E454F50` — ASCII `"NEOP"` |
| `0x004` | `CTRL` | RW | `[0]` START (self-clearing) · `[1]` AUTO · `[2]` SOFT_RST (self-clearing) |
| `0x008` | `STATUS` | RO / W1C | `[0]` BUSY · `[1]` FRAME_DONE (W1C) · `[15:8]` current LED index |
| `0x00C` | `LED_COUNT` | RW | active LEDs, 1..`MAX_LEDS` (0 is stored as 1, >64 as 64) |
| `0x400`–`0x4FF` | `FB[0..63]` | RW | pixel *n* at `0x400 + 4n`, format `0x00_GG_RR_BB` |

Design notes on each:

- **`ID` earns its place.** It's the first thing you read over JTAG
  (`mrd 0x43C00000`) and it tells you in one command whether the bus, the address
  decode, and the clock are all alive — before any LED behaviour is involved.
- **`START` self-clears**: write 1 → one-cycle internal pulse → reads back 0.
  Naturally idempotent, and no read-modify-write race against hardware.
- **`AUTO`**: when set, the FSM restarts a frame automatically after
  `frame_done` (`start = start_wr || (auto_q && frame_done && !soft_rst)`).
  Convenient, but it causes tearing: if software writes the framebuffer
  mid-frame, the strip shows a half-updated frame. The fix is a ping-pong
  buffer; see "Later".
- **`SOFT_RST`**: returns the FSM and PHY to idle, aborting any frame in flight.
  The register block itself is only reset by the bus reset.
- **`FRAME_DONE` is W1C** ("write 1 to clear"): writing 0 leaves it alone, and
  writing 1 clears it. If hardware sets it in the same cycle software clears
  it, hardware wins, so an event is never lost.
- **Pixel format is `0x00GGRRBB`**, i.e. the register layout *is* the wire
  format. The FSM shifts `shreg[23:0]` out MSB-first with no reordering
  whatsoever. Do the RGB→GRB swizzle once, in software, where it's cheap and
  visible in a function you can read.

**Everything runs on `sysclk`.** AXI and the LED logic share one 125 MHz domain,
so there is no clock-domain crossing anywhere in this design. That is deliberate.
Keep it that way — CDC is a whole separate topic and mixing it in here would
obscure both.

The Phase 3 `ws2812_top.sv` is just wiring: `u_regs`, `u_fb`, `u_fsm` and `u_phy`
connected together, with the core's reset derived as
`core_rst_n = s_axi_aresetn && !soft_rst`. No power-on-reset trick is needed any
more, because the bus reset is real.

### 3b. `fpga/sim/ws2812_axil_regs_tb.sv`

- [x] written, passes

It drives the AXI channels by hand from tasks. Writing these once teaches you
more about AXI than reading the spec three times, because you have to decide
yourself when to raise and drop each `VALID` and `READY`. The reference gives
each write channel its own little process with `fork ... join`, which also makes
it trivial to send AW and W in either order:

```systemverilog
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
            @(negedge clk);
            bready = 1'b0;
        end
    join                                  // all three finished = write done
endtask

axil_write(FB + 0, {8'h00, px[0]});        // AW and W together
axil_write(FB + 4, {8'h00, px[1]}, 0, 5);  // AW first, W 5 clocks later
axil_write(FB + 8, {8'h00, px[2]}, 5, 0);  // W first, AW 5 clocks later
```

Checks: `ID` reads back; `LED_COUNT` round-trips; all three write orderings
land; `FB[n]` round-trips; `START` self-clears; `STATUS.BUSY` rises then falls;
`FRAME_DONE` latches, survives a write of 0, and clears on a write of 1.

It is also the **full-system testbench**: it instantiates the whole
`ws2812_top` with `ws2812_monitor` on `npx_data`, so the last check is that the
pixels on the wire are the ones software wrote. That one test covers
AXI writes → framebuffer → FSM → PHY → the protocol on the wire.

### 3c. Packaging

- [x] RTL moved to `fpga/ip/ws2812_ctrl/src/`
- [x] `fpga/ip/package_ws2812.tcl`
- [x] `sim.sh` and `build.tcl` updated

⚠️ **`fpga/scripts/build.tcl` globs `rtl/*.sv` into the project.** If your modules
also live inside a packaged IP, Vivado sees two definitions of every module and
synthesis fails in a confusing way. So packaging requires a file move:

```
fpga/ip/ws2812_ctrl/src/*.sv        ← the five RTL files move here (git mv)
fpga/ip/ws2812_ctrl/component.xml   ← generated by the packaging script (gitignored)
fpga/ip/package_ws2812.tcl          ← new
```

The script edits:

```bash
# fpga/scripts/sim.sh -- simulate the IP straight from its sources
SOURCES=("$FPGA_DIR"/rtl/*.v "$FPGA_DIR"/rtl/*.sv "$FPGA_DIR"/ip/*/src/*.sv "$FPGA_DIR"/sim/*.v "$FPGA_DIR"/sim/*.sv)

# fpga/scripts/build.sh -- package every IP before the main build
for pkg in "$FPGA_DIR"/ip/package_*.tcl; do
    "$VIVADO_ROOT/bin/vivado" -mode batch -nojournal -nolog -source "$pkg"
done
```

```tcl
# fpga/scripts/build.tcl -- just before sourcing bd/design_1.tcl
set_property ip_repo_paths "$fpga_dir/ip" [current_project]
update_ip_catalog
```

`turbo.json` also gains `"ip/**"` in the `simulate` and `build_platform` inputs,
so editing the IP invalidates the cache.

The branch runs packaging from `build.sh` and gitignores `component.xml`
instead of committing it. Generated files that are checked in drift away from
their sources. Regenerated on every build, `component.xml` always matches
`src/`, and a fresh clone builds with no extra step.

`package_ws2812.tcl`, trimmed:

```tcl
set ip_dir  [file normalize [file join [file dirname [info script]] ws2812_ctrl]]
set src_dir [file join $ip_dir src]
set tmp_dir [file join $ip_dir .pkg_tmp]

# ipx::package_project packages a *project*, so make a throwaway one.
create_project -force pkg_tmp $tmp_dir -part xc7z020clg400-1
add_files -norecurse [lsort [glob $src_dir/*.sv]]
set_property top ws2812_top [current_fileset]
update_compile_order -fileset sources_1

ipx::package_project -root_dir $ip_dir -vendor forsyth -library ip \
    -taxonomy /UserIP -import_files false -set_current true
set core [ipx::current_core]

set_property name    ws2812_ctrl $core
set_property version 1.0         $core

ipx::associate_bus_interfaces -busif s_axi -clock s_axi_aclk $core
set clk_if [ipx::get_bus_interfaces s_axi_aclk -of_objects $core]
set freq   [ipx::get_bus_parameters FREQ_HZ -of_objects $clk_if]
if {$freq eq ""} { set freq [ipx::add_bus_parameter FREQ_HZ $clk_if] }
set_property value 125000000 $freq

ipx::create_xgui_files $core
ipx::update_checksums  $core
ipx::check_integrity   $core
ipx::save_core         $core
close_project -delete
```

(`ipx::package_project` is a shorter route than the `ipx::infer_core` /
`ipx::edit_ip_in_project` sequence the plan originally named, and ends in the
same place.)

Two things that decide whether this is painless or miserable:

1. **Port naming drives interface inference.** Name the ports exactly
   `s_axi_awaddr`, `s_axi_awprot`, `s_axi_awvalid`, `s_axi_awready`, and so on
   for all five channels, plus `s_axi_aclk` and `s_axi_aresetn`. The packager
   then reports:
   ```
   Inferred bus interface 's_axi' of definition 'xilinx.com:interface:aximm:1.0'
   Bus Interface 's_axi_aclk': Added interface parameter 'ASSOCIATED_BUSIF' with value 's_axi'.
   ```
   Note that the inferred interface is called **`s_axi`**, in lowercase. The block
   design has to use that name.
2. **Associate the clock with the interface** and set `FREQ_HZ`. Skipping this is
   why a packaged IP sometimes drops into a BD with no clock inference and
   silently fails timing.

Expected, harmless packager warnings: *"Packaging a component with a
SystemVerilog top file is not fully supported"* (it works; the IP synthesizes
inside the BD), and *"HDL port or parameter 'reg_addr' has a dependency on
... 'AW'"* (the parser noticing internal signals).

VLNV: **`forsyth:ip:ws2812_ctrl:1.0`**.

### 3d. Block design, `top.v`, XDC

- [x] `fpga/bd/design_1.tcl`
- [x] `fpga/rtl/top.v`
- [x] `fpga/constraints/Zybo_Z7_io.xdc`

Hand-edited rather than re-exported, so the diff stays reviewable. Every change
follows a pattern already in the file:

```tcl
# 1. IP existence check list at the top
  xilinx.com:ip:proc_sys_reset:5.0\
  forsyth:ip:ws2812_ctrl:1.0\

# 2. An output port, next to led_o / sw_i / btn_i
  set npx_data [ create_bd_port -dir O npx_data ]

# 3. The cell, and a third interconnect master
  set ws2812_ctrl_0 [ create_bd_cell -type ip -vlnv forsyth:ip:ws2812_ctrl:1.0 ws2812_ctrl_0 ]
  set_property CONFIG.NUM_MI {3} $ps7_0_axi_periph

# 4. Bus, data pin, clock and reset
  connect_bd_intf_net -intf_net ps7_0_axi_periph_M02_AXI [get_bd_intf_pins ps7_0_axi_periph/M02_AXI] [get_bd_intf_pins ws2812_ctrl_0/s_axi]
  connect_bd_net -net ws2812_ctrl_0_npx_data  [get_bd_pins ws2812_ctrl_0/npx_data] \
  [get_bd_ports npx_data]
  #   ...and in the existing rst_sysclk_125M_peripheral_aresetn fan-out:
  [get_bd_pins ps7_0_axi_periph/M02_ARESETN] \
  [get_bd_pins ws2812_ctrl_0/s_axi_aresetn] \
  #   ...and in the existing sysclk_net fan-out:
  [get_bd_pins ps7_0_axi_periph/M02_ACLK] \
  [get_bd_pins ws2812_ctrl_0/s_axi_aclk] \

# 5. Address
  assign_bd_address -offset 0x43C00000 -range 0x00010000 -target_address_space [get_bd_addr_spaces processing_system7_0/Data] [get_bd_addr_segs ws2812_ctrl_0/s_axi/reg0] -force
```

Note the segment name, **`s_axi/reg0`**. The original plan said `S_AXI/Reg`,
which is what Xilinx's own IP uses. A packaged custom IP gets whatever the
packager inferred, so check with
`get_bd_addr_segs -of_objects [get_bd_addr_spaces processing_system7_0/Data]`.

⚠️ **Missing either clock or reset fan-out is the classic "AXI read hangs
forever" bug.** The symptom is `mrd` in xsdb never returning. Worth knowing the
signature now so you recognize it in three seconds rather than three hours.

`0x43C0_0000` is the conventional base for custom PL IP on Zynq-7000 and doesn't
collide with the GPIOs at `0x4120_0000` / `0x4121_0000`.

In `top.v`, `npx_data` becomes a top-level output wired to the BD port:

```verilog
    input  wire [ 3:0] btn,
    output wire        npx_data   // WS2812B data, Pmod JE pin 1
);
    ...
        .btn_i               (btn),
        .npx_data            (npx_data)
    );
```

And one line in the XDC:

```tcl
set_property -dict { PACKAGE_PIN V12   IOSTANDARD LVCMOS33 } [get_ports { npx_data }]
```

- [x] **Verify before touching software:** after `yarn build_platform`,
      `fpga/dist/address_map.json` contains:
      ```json
      {"instance": "ws2812_ctrl_0", "vlnv": "forsyth:ip:ws2812_ctrl:1.0", "offset": "0x43C00000", ...}
      ```
      If it doesn't, `build.tcl`'s address-map walk didn't see it and nothing
      downstream can possibly work.

The build prints four `CRITICAL WARNING: [PSU-1..4] ... negative DQS skew`
messages. Those come from the Zybo board preset's DDR settings and appear on
`master` too. They aren't related to this IP.

---

## Phase 4 — the Rust driver

### 4a. `libs/xil_bindings/src/ip/ws2812.rs`

- [x] written
- [x] registered in `libs/xil_bindings/src/ip/mod.rs`

Modelled directly on `axi_gpio.rs`. Constants first:

```rust
pub const SUPPORTED_VLNV: &str = "forsyth:ip:ws2812_ctrl:1.0";
pub const ID_VALUE: u32 = 0x4E45_4F50; // "NEOP"
pub const MAX_LEDS: usize = 64;

const REG_ID: usize = 0x000;
const REG_CTRL: usize = 0x004;
const REG_STATUS: usize = 0x008;
const REG_LED_COUNT: usize = 0x00C;
const FB_BASE: usize = 0x400;

const CTRL_START: u32 = 1 << 0;
const CTRL_AUTO: u32 = 1 << 1;
const STATUS_BUSY: u32 = 1 << 0;
const STATUS_FRAME_DONE: u32 = 1 << 1;
```

The swizzle lives in one small function, and a compile-time assert pins its
behaviour down:

```rust
/// Pack R, G, B into the `0x00GGRRBB` word the hardware sends as-is.
pub const fn pack_grb(r: u8, g: u8, b: u8) -> u32 {
    ((g as u32) << 16) | ((r as u32) << 8) | (b as u32)
}

// If someone "fixes" the order, the build fails instead of the colours.
const _: () = assert!(pack_grb(0x12, 0x34, 0x56) == 0x0034_1256);
```

Register access is `read_volatile` / `write_volatile`, exactly as in
`axi_gpio.rs`. *Volatile* tells the compiler "this memory can change behind
your back, and every access has side effects", so it can't cache, merge or drop
a register read or write.

| Method | What it does |
|---|---|
| `id()` | read `ID` — the liveness check |
| `set_led_count(n)` / `led_count()` | `LED_COUNT` |
| `set_pixel(n, r, g, b)` | `FB[n] = pack_grb(r, g, b)`; out-of-range `n` ignored |
| `start()` | clear stale `FRAME_DONE`, then set `CTRL.START` (keeping `AUTO`) |
| `set_auto(on)` | `CTRL.AUTO` |
| `soft_reset()` | `CTRL.SOFT_RST` |
| `is_busy()` | `STATUS.BUSY` |
| `wait_done()` | spin on `STATUS.FRAME_DONE`, then W1C it |

One subtlety in `start()`: it clears `FRAME_DONE` *before* starting, so a
following `wait_done()` waits for *this* frame and not one that finished
earlier:

```rust
pub fn start(&self) {
    self.write(REG_STATUS, STATUS_FRAME_DONE);            // W1C any stale flag
    let auto = self.read(REG_CTRL) & CTRL_AUTO;           // don't clobber AUTO
    self.write(REG_CTRL, auto | CTRL_START);
}
```

`xil_bindings` is `#![no_std]` with **zero dependencies**. Keep it that way — no
`heapless`, no `embedded-hal`. Raw volatile access on a known address is exactly
what a driver at this layer is.

### 4b. `apps/backend/src/main.rs`

- [x] VLNV guard added
- [x] `ID` read and logged at boot
- [x] rainbow animating (switches set brightness): verified via register
      reads; not yet seen on a physical strip

The build-time guard, next to the two that already exist:

```rust
const _: () = assert!(
    konst_str_eq(ws2812_ctrl_0::VLNV, ws2812::SUPPORTED_VLNV),
    "ws2812_ctrl_0 is not the IP version xil_bindings::ip::ws2812 was written for"
);
```

**Understand this mechanism — it's the best thing in this repo.** The base
address and VLNV string come out of `fpga/dist/address_map.json` via
`libs/xil_bindings/build.rs`, which *generates* the `ws2812_ctrl_0` module at
compile time. So: rebuild the bitstream with the IP at a different address and
Rust picks it up automatically, with no edit. Swap the IP for a different one and
the build *fails* rather than cheerfully writing to the wrong peripheral. That's
a compile-time proof that your software and your gateware agree, and it costs
nothing at runtime.

Boot-time liveness check, before anything else touches the IP:

```rust
let npx = unsafe { Ws2812::new(ws2812_ctrl_0::BASE) };

let id = npx.id();
let npx_ok = id == ws2812::ID_VALUE;
if npx_ok {
    info!("ws2812_ctrl_0 ID {id:#010x} (\"NEOP\") -- NeoPixel IP alive");
    npx.set_led_count(NUM_LEDS as u32);
} else {
    error!("ws2812_ctrl_0 ID {id:#010x}, expected {:#010x} -- not driving the strip", ws2812::ID_VALUE);
}
```

The rainbow goes in the existing main loop. It doesn't block: whenever the last
frame has gone out, it writes the next one and starts it.

```rust
if npx_ok && !npx.is_busy() {
    let offset = (frame / 4) as u8;                  // hue moves every 4th frame
    let level = (switches as u8) * 16 + 15;          // 15..=255, never fully dark
    for i in 0..NUM_LEDS {
        let hue = offset.wrapping_add((i * 256 / NUM_LEDS) as u8);
        let (r, g, b) = wheel(hue);
        npx.set_pixel(i, dim(r, level), dim(g, level), dim(b, level));
    }
    npx.start();
    frame = frame.wrapping_add(1);
}
```

`wheel()` and `dim()` are integer-only, so no floating point and no `libm`:

```rust
/// Colour wheel: 0..=255 walks red -> green -> blue -> red.
fn wheel(pos: u8) -> (u8, u8, u8) {
    match pos {
        0..=84 => (255 - pos * 3, pos * 3, 0),
        85..=169 => { let p = pos - 85;  (0, 255 - p * 3, p * 3) }
        _ =>        { let p = pos - 170; (p * 3, 0, 255 - p * 3) }
    }
}

/// Scale a colour channel by a brightness of 0..=255.
fn dim(c: u8, level: u8) -> u8 {
    ((c as u16 * level as u16) / 255) as u8     // widen first, or 255*255 overflows
}
```

> ⚠️ **Learned the hard way — `u8` overflow.** The first draft of the
> brightness line was `((switches as u8) + 1) * 16 - 1`. With all four switches
> on, that is `16 * 16 = 256`, which doesn't fit in a `u8`. It panics in a debug
> build and silently wraps to 0 in release. `switches * 16 + 15` gives the same
> 15..=255 range and never goes past 255. Every `wheel` input 0..=255 was also
> run with overflow checks on to confirm it never overflows.

Build and deploy **from `apps/backend/`**, not the workspace root — the
`.cargo/config.toml` target only applies from that directory, and a root-level
`cargo build -p backend` will build for the host and fail:

```
cd fpga && yarn build_platform && yarn deploy       # bitstream first
cd apps/backend && yarn build && bash scripts/deploy.sh
```

- [ ] Still open: `apps/backend/package.json` has no `deploy` script even though
      `scripts/deploy.sh` exists and the README references `yarn deploy`.

---

## Verification

| Phase | Command | Pass condition | Reference branch |
|---|---|---|---|
| 1 | `cd fpga && yarn simulate ws2812_timing_tb` | `SIM PASS`; pulses measure 50 / 100 / 156 cycles | ✅ |
| 1 | `cd fpga && yarn simulate ws2812_frame_fsm_tb` | `SIM PASS`; monitor decodes exactly the pixels written | ✅ |
| 1 | `cd fpga && yarn simulate ws2812_frame_fsm_tb --gui` | you can visually identify a `1` and a `0` bit | try it |
| 2 | `yarn simulate ws2812_top_tb` (Phase 2 commit) | `SIM PASS`; colour follows switches, dot moves | ✅ |
| 3 | `cd fpga && yarn simulate ws2812_axil_regs_tb` | `SIM PASS`; all AW/W orderings complete, no hangs | ✅ |
| 3 | out-of-context synthesis of `ws2812_top` | completes; framebuffer in block RAM | ✅ 1 BRAM, 170 LUT, 174 FF |
| 3 | `yarn build_platform`, inspect `fpga/dist/address_map.json` | contains `ws2812_ctrl_0` @ `0x43C00000`, correct VLNV | ✅ |
| 3 | `xsdb` → `mrd 0x43C00000` | reads `0x4E454F50` | ✅ `1313165136` = `0x4E454F50` |
| 4 | `cd apps/backend && yarn build` | VLNV `const` assertion compiles | ✅ |
| 4 | `bash scripts/deploy.sh`, UART @ 115200 | logs the ID; rainbow animates | ✅ ID logged; see below |

### What the board actually said (2026-09-28, reference branch)

Bitstream: timing met at 125 MHz, WNS +1.672 ns. UART after deploy:

```
INFO - ws2812_ctrl_0 @ 0x43c00000 (0x10000 bytes)
INFO - counter 11 -> 12 after 162150 reads -- PL clock running
INFO - ws2812_ctrl_0 ID 0x4e454f50 ("NEOP") -- NeoPixel IP alive
```

Then, with the firmware running, registers read over JTAG
(`mrd -force -value <addr>` from `xsdb`; `-force` because the core is
running). `FB[0]` changing between samples means the rainbow is scrolling, and
`STATUS` catches frames both in flight and finished:

```
LED_COUNT 64
STATUS=0x00003f01 busy=1 led_idx=63  FB0=0x070007 FB32=0x000e00
STATUS=0x00000002 busy=0 led_idx= 0  FB0=0x04000a FB32=0x030b00
STATUS=0x00002301 busy=1 led_idx=35  FB0=0x000806 FB32=0x0e0000
```

(The values are dim because all switches were off, which gives the minimum
brightness of 15.) At that point no strip was connected, so the one thing not
yet verified is the electrical path: level shifter, wiring and the strip
itself. Everything on the FPGA side of JE1 has been checked.

**Optional but recommended:** `turbo.json`'s `build_platform` does not currently
depend on `simulate`. Making `@repo/fpga#build_platform` depend on
`@repo/fpga#simulate` means you cannot build a bitstream whose testbenches are
failing. For a peripheral whose entire correctness is timing, that's worth
switching on. (It would need `simulate` to run *every* testbench rather than
just the default one.)

---

## Order of attack

**Finish Phase 1 completely before plugging anything in.**

The temptation with LEDs is to rush to blinking. Resist it. The correctness of
this peripheral is *timing*, timing is fully observable in a waveform and nearly
unobservable in a strip of lights, and every hour spent debugging a flickering
strip is an hour you could have spent looking at the actual signal. Get the PHY
and the monitor right and Phases 2–4 are plumbing you already know how to do from
`rtl_counter`.

And synthesize early: build each module in Vivado as soon as its testbench
passes. The `input logic` problem above passed every simulation and failed
synthesis on every file.

---

## Later, once it works

Deliberately out of scope, in rough order of value:

- **Ping-pong framebuffer** — eliminates tearing under `AUTO`. Two banks, an
  `ACTIVE` bit in `CTRL`, swap on `frame_done`.
- **`WSTRB` support** — makes byte writes behave correctly.
- **Multiple strips** — N parallel channels sharing one `ws2812_timing`. The
  handshake decomposition already makes this cheap: the PHY is stateless per
  channel except for the latched bit.
- **Interrupt on `frame_done`** — one more BD connection to the PS `IRQ_F2P`,
  and the software stops polling.
- **A DMA path** — `AXI-Stream` + `axi_dma` from DDR, for when a 64-pixel
  register-file framebuffer stops being enough.
