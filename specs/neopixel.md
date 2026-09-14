# WS2812B NeoPixel driver — implementation spec

Status: **not started**. This document is the plan of attack, not a record of
finished work. Tick the checkboxes as you go.

Target: one WS2812B strip, up to 64 LEDs, driven from the PL on a Zybo Z7-20,
controlled from `no_std` Rust on the PS over AXI4-Lite.

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
localparam int T0H_CYC = (CLK_HZ / 1_000_000) * T0H_NS / 1000;
```

Integer math, elaboration-time, no cost. The numbers then stay correct if the
clock ever changes, and a reader can see where they came from.

Frame time for 64 LEDs: 64 × 24 × 1.248 µs + 300 µs ≈ **2.2 ms** → ~450 fps
ceiling. Never the bottleneck.

---

## Module hierarchy

```
top.v                                  (existing — edit)
 └─ u_neopixel   ws2812_top.sv         becomes the packaged IP in Phase 3
     ├─ u_regs   ws2812_axil_regs.sv   AXI4-Lite slave: ID/CTRL/STATUS/LED_COUNT
     ├─ u_fb     ws2812_framebuffer.sv true dual-port RAM, MAX_LEDS × 24b
     ├─ u_fsm    ws2812_frame_fsm.sv   walks pixels, serializes, times reset gap
     └─ u_phy    ws2812_timing.sv      bit-slot counter + pulse-width encoder
```

Two structural rules worth carrying into future peripherals:

1. **The timing-critical part is the smallest module.** `ws2812_timing` is the
   only thing in the design that knows about nanoseconds. Everything above it
   counts *bits*.
2. **Layers meet at ready/valid handshakes**, never at shared counters. That is
   what lets you testbench the PHY standing completely alone, and what would let
   you drop in an APA102 PHY later without touching the FSM.

### House conventions (from the existing RTL)

- `` `timescale 1 ps / 1 ps `` and `` `default_nettype none `` at the top of every
  file, `` `default_nettype wire `` at the bottom.
- File name == module name, lowercase snake_case.
- Instances named `u_<module>`.
- A comment block at the top of each file explaining the *why*, not the what.
  `fpga/rtl/rtl_counter.v:1-18` is the reference for tone and depth.
- Anything a testbench might want to shrink is a real `parameter`.

---

## Phase 0 — record the pins

- [ ] Fill in the `PMOD port:` stub in `datasheets/README.md`

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

Copy the exact `PACKAGE_PIN` values for JE out of Digilent's
[`Zybo-Z7-Master.xdc`](https://github.com/Digilent/digilent-xdc). Do not take
pin numbers from memory — anyone's. The master XDC is the authority. Record the
whole header even though you only need JE pin 1, so the next peripheral is free.

### Wiring notes for the same file

- **Strip GND must tie to Zybo GND.** A floating ground is the single most common
  cause of "it flickers randomly."
- Strip 5V comes from its own supply, not from the Zybo. 64 LEDs at full white is
  ~3.8 A; the board cannot source that.
- Level shifter (74AHCT125 or 74HCT245): **VCC on the 5V rail**, input side from
  JE1. An HCT part powered at 3.3 V does not shift anything — it just passes the
  signal through and you have wasted an afternoon.

---

## Phase 1 — RTL and simulation only

No board, no bitstream, no bus. This is where most of the learning is, and all of
it is free and fast.

`fpga/scripts/sim.sh:32` already globs `rtl/*.sv` and `sim/*.sv`, and
`fpga/scripts/build.tcl` globs `rtl/*.sv`. **Dropping a file in is the whole of
adding it.** `turbo.json`'s `simulate` task already lists `rtl/**` and `sim/**`
as inputs, so caching stays correct too.

### 1a. `fpga/rtl/ws2812_timing.sv` — the bit-slot PHY

- [ ] written
- [ ] `yarn simulate ws2812_timing_tb` prints `SIM PASS`

```systemverilog
module ws2812_timing #(
    parameter int CLK_HZ = 125_000_000,
    parameter int T0H_NS = 400,
    parameter int T1H_NS = 800,
    parameter int BIT_NS = 1250
) (
    input  logic clk,
    input  logic rst_n,        // active low, synchronous
    input  logic bit_val,      // bit to send; sampled when the handshake fires
    input  logic bit_valid,    // upstream has a bit ready
    output logic bit_ready,    // high when able to accept a bit
    output logic serial        // the encoded line
);
```

Behaviour:

- Idle: `serial = 0`, `bit_ready = 1`.
- On `bit_valid && bit_ready`: latch `bit_val`, start `cnt` at 0, drop
  `bit_ready`.
- `cnt` increments every cycle. At `cnt == BIT_CYC-1` the slot ends.
- `serial = (cnt < (latched_bit ? T1H_CYC : T0H_CYC))` — combinational off `cnt`.

**The one hard requirement:** `bit_ready` must be high again on the *final cycle*
of a slot, not the cycle after, so a waiting upstream handshake starts the next
slot with no gap. Get this wrong and you get a 1-cycle hole between every bit —
8 ns, harmless on the wire, but it means your slot is 157 cycles not 156, and it
is the same mistake that becomes a 3744-cycle hole at pixel boundaries in the
FSM. Prove it in the testbench.

That comparator line *is* the encoder. If you find yourself writing a state
machine with `S_HIGH` / `S_LOW` states, back up — the counter already is the
state.

### 1b. `fpga/sim/ws2812_timing_tb.sv`

**The testbench contract** (`fpga/scripts/sim.sh:69-76`): print the literal
string `SIM PASS`, and emit nothing matching `^(Fatal|Error|ERROR):`. `xsim`
exits 0 whether or not the testbench called `$fatal`, so the log is the only
verdict. Include a watchdog `initial` that `$fatal`s on timeout —
`fpga/sim/rtl_counter_tb.v:98-102` is the pattern to copy.

Checks:

- Send `0` → measure high pulse → assert `== T0H_CYC` (50).
- Send `1` → assert `== T1H_CYC` (100).
- Assert total slot `== BIT_CYC` (156) for both.
- Send `1,0,1,1,0` back-to-back → assert slot starts are exactly 156 cycles
  apart, i.e. no dead cycles.

Run it, then run it with `--gui` and *look at the waveform*. The entire reason
for starting here is to see the two pulse widths with your own eyes.

### 1c. `fpga/sim/ws2812_monitor.sv` — the receiver

- [ ] written

**Highest-value file in the project.** Write a module that does what the LED
does: watch `serial`, measure each high pulse, classify it against a threshold
halfway between `T0H_CYC` and `T1H_CYC` (75 cycles), assemble 24-bit words, and
treat a long low period as end-of-frame. Expose the decoded pixels as an array
plus a `frame_done` pulse and a count.

Every testbench above this point then becomes: write pixels in, kick the FSM,
compare the monitor's output against what you wrote. That checks the *protocol*
rather than your assumptions about your own implementation — the same job a
logic analyzer does, in software, for free, on every commit.

Non-synthesizable, lives in `sim/`, and that's fine.

### 1d. `fpga/rtl/ws2812_framebuffer.sv`

- [ ] written

```systemverilog
module ws2812_framebuffer #(
    parameter int MAX_LEDS = 64
) (
    input  logic clk,
    // Port A — AXI (Phase 3) / pattern generator (Phase 2)
    input  logic [$clog2(MAX_LEDS)-1:0] a_addr,
    input  logic [23:0]                 a_wdata,
    input  logic                        a_we,
    output logic [23:0]                 a_rdata,
    // Port B — read-only, frame FSM
    input  logic [$clog2(MAX_LEDS)-1:0] b_addr,
    output logic [23:0]                 b_rdata
);
```

Body is an inferred true dual-port RAM: `logic [23:0] mem [0:MAX_LEDS-1];` with
two `always_ff` blocks, one per port.

**Do not reset the memory array.** A reset on the array forces Vivado to build it
out of flip-flops instead of block RAM — the classic way to spend 1536 FFs on 64
pixels. After your first synthesis run, grep the log for BRAM inference to
confirm.

64 × 24 bits = 1536 bits, so it'll land as distributed RAM or a single RAMB18.
Either is fine. `MAX_LEDS` being a parameter makes growing to 300 LEDs a one-line
change later.

**Read latency is one cycle**: `b_rdata` is valid the cycle *after* `b_addr` is
presented. The FSM must account for it. Shifting out the previous pixel's data
is the standard first bug here.

### 1e. `fpga/rtl/ws2812_frame_fsm.sv`

- [ ] written
- [ ] `yarn simulate ws2812_frame_fsm_tb` prints `SIM PASS`

```systemverilog
module ws2812_frame_fsm #(
    parameter int CLK_HZ   = 125_000_000,
    parameter int MAX_LEDS = 64,
    parameter int RESET_NS = 300_000
) (
    input  logic clk,
    input  logic rst_n,
    input  logic start,                              // 1-cycle pulse
    input  logic [$clog2(MAX_LEDS+1)-1:0] led_count,
    output logic busy,
    output logic frame_done,                         // 1-cycle pulse
    output logic [$clog2(MAX_LEDS+1)-1:0] led_index, // for STATUS
    // framebuffer port B
    output logic [$clog2(MAX_LEDS)-1:0]   fb_addr,
    input  logic [23:0]                   fb_rdata,
    // PHY handshake
    output logic bit_val,
    output logic bit_valid,
    input  logic bit_ready
);
```

States: `IDLE → LOAD → SHIFT → RESET → IDLE`.

- `LOAD`: present `fb_addr = 0`, wait one cycle for RAM latency, load `shreg`.
  Only needed for the first pixel.
- `SHIFT`: drive `bit_val = shreg[23]`, `bit_valid = 1`. On
  `bit_valid && bit_ready`, shift left and decrement the bit counter. After 24
  bits, advance `led_idx`; if `led_idx == led_count` go to `RESET`, else reload
  `shreg` and continue.
- `RESET`: deassert `bit_valid` (the PHY idles the line low), count `RESET_CYC`
  (37500 — needs a 16-bit counter), pulse `frame_done`, return to `IDLE`.

`busy` is high in every state except `IDLE`.

**The pixel-boundary trap.** A naive implementation returns to a `FETCH` state
between pixels, costing a cycle or two of line-low time every 24 bits. That
stretches the 24th slot and, at worst, accumulates. The fix is a prefetch: the
moment you load `shreg` for pixel *n*, present `fb_addr = n+1` and capture
`fb_rdata` into a `next_pixel` register on the following cycle. You have 24 × 156
= 3744 cycles of slack, so there is no excuse to be late. When the last bit's
handshake completes, `shreg <= next_pixel` with zero dead cycles.

Build it the naive way first and **look at the stretched slot in the waveform**
before you fix it. Seeing the bug is worth more than avoiding it.

### 1f. `fpga/sim/ws2812_frame_fsm_tb.sv`

Instantiate FSM + framebuffer + timing + monitor. Preload the framebuffer with
distinguishable values (`0xFF0000`, `0x00FF00`, `0x0000FF` — deliberately *not*
symmetric, so a byte-order bug shows), pulse `start`, wait for `frame_done`, and
assert the monitor decoded exactly those three words in that order.

**Shrink the right parameters.** The repo's convention is `rtl_counter`'s
`TICK_DIV` — 23 synthesized, 4 in the testbench (`fpga/rtl/rtl_counter.v:14-16`).
Here the knobs are different: leave the *bit* timing at its real values, because
that is the thing under test. Shrink `led_count` to 3 and `RESET_NS` to ~2000
instead.

- 3 pixels = 72 bits ≈ 11,000 cycles → sub-second.
- 64 pixels at real reset timing = 277,000 cycles → a wait, made worse by
  `log_wave -recursive *` in `fpga/scripts/sim.tcl`.

**Exit criterion for Phase 1:** `ws2812_frame_fsm_tb` passes, and you can open
the waveform and point at a `1` bit and a `0` bit.

---

## Phase 2 — first light, no bus

Prove the electrical path and real-silicon timing before AXI adds variables.

- [ ] `fpga/rtl/ws2812_pattern.sv` — trivial source writing framebuffer port A.
      Map the four slide switches to a colour; auto-pulse `start` every ~20 ms
      off a prescaler (`rtl_counter` is the pattern).
- [ ] `fpga/rtl/ws2812_top.sv` — framebuffer + FSM + timing + pattern, single
      `npx_data` output.
- [ ] `fpga/rtl/top.v` — add `output wire npx_data` to the port list, instantiate
      `u_neopixel`.
- [ ] `fpga/constraints/Zybo_Z7_io.xdc` — one line:
      `set_property -dict { PACKAGE_PIN <JE1> IOSTANDARD LVCMOS33 } [get_ports { npx_data }]`
      in the existing commented-block style.
- [ ] `cd fpga && yarn build_platform && yarn deploy` → lights move

Notes:

- `top.v:105-108` explains why `rtl_counter` deliberately does *not* use `resetn`
  from the BD: it's derived from the PS, so anything held by it sits dead until
  `ps7_init` runs. For Phase 2, tie your core's `rst_n` high for the same reason —
  the strip should run from configuration. In Phase 3 it moves onto
  `s_axi_aresetn`, which is correct once it's a bus peripheral.
- No timing constraint on `npx_data`. It is not a synchronous interface, so the
  unconstrained-output warning is expected and harmless.

**If it doesn't light, check in this order:** ground (common ground to the Zybo),
then the level shifter (VCC on 5 V, not 3.3 V), then scope JE1 directly. Phase 1
already proved the waveform is right, which is exactly what earns you the right
to look outward instead of doubting the RTL.

---

## Phase 3 — AXI4-Lite slave, packaged as IP

### 3a. `fpga/rtl/ws2812_axil_regs.sv`

- [ ] written
- [ ] `yarn simulate ws2812_axil_regs_tb` prints `SIM PASS`

Write the slave by hand. Five channels (AW, W, B, AR, R); a minimal correct
implementation is ~120 lines. The rules that actually bite:

- **`AWVALID` and `WVALID` are independent.** You do not get to assume address
  and data arrive together, or in either order. Latch each into a holding
  register and commit the write once both have landed.
- **`BVALID` must stay asserted until `BREADY`.** Same for `RVALID`/`RREADY`.
  Dropping it after one cycle is the classic "works in sim, hangs on hardware"
  bug.
- **No combinational loop from `AWVALID` to `AWREADY`.** Register your ready
  signals.
- **Decode on `AWADDR[11:2]`** — word addresses within the 4 KB window.
- **Framebuffer reads have RAM latency.** A read of `FB[n]` cannot assert
  `RVALID` in the same cycle it accepts `ARVALID`; insert the one-cycle wait.
  Register reads can be immediate. Easiest correct approach: make *every* read
  take the same fixed number of cycles.
- **`WSTRB` may be ignored initially**, but know what you're giving up: a byte
  write from software silently becomes a full word write. Write it down as a
  known limitation rather than forgetting it.

### Register map (4 KB window)

| Offset | Name | Access | Contents |
|---|---|---|---|
| `0x000` | `ID` | RO | `0x4E454F50` — ASCII `"NEOP"` |
| `0x004` | `CTRL` | RW | `[0]` START (self-clearing) · `[1]` AUTO · `[2]` SOFT_RST (self-clearing) |
| `0x008` | `STATUS` | RO / W1C | `[0]` BUSY · `[1]` FRAME_DONE (W1C) · `[15:8]` current LED index |
| `0x00C` | `LED_COUNT` | RW | active LEDs, 1..`MAX_LEDS` |
| `0x400`–`0x4FF` | `FB[0..63]` | RW | pixel *n* at `0x400 + 4n`, format `0x00_GG_RR_BB` |

Design notes on each:

- **`ID` earns its place.** It's the first thing you read over JTAG
  (`mrd 0x43C00000`) and it tells you in one command whether the bus, the address
  decode, and the clock are all alive — before any LED behaviour is involved.
  Same spirit as the VLNV assertions already in `apps/backend/src/main.rs`.
- **`START` self-clears**: write 1 → one-cycle internal pulse → reads back 0.
  Naturally idempotent, and no read-modify-write race against hardware.
- **`AUTO`**: when set, the FSM restarts a frame automatically after
  `frame_done`. Convenient, but note it introduces tearing — software writing the
  framebuffer mid-frame will show a half-updated strip. Acceptable at this stage;
  the fix is a ping-pong buffer, which is a good Phase 5 exercise.
- **`SOFT_RST`**: returns the FSM to `IDLE`, aborting any frame in flight.
- **`FRAME_DONE` is W1C**, so software can poll for completion without missing
  the event.
- **Pixel format is `0x00GGRRBB`**, i.e. the register layout *is* the wire
  format. The FSM shifts `shreg[23:0]` out MSB-first with no reordering
  whatsoever. Do the RGB→GRB swizzle once, in software, where it's cheap and
  visible in a function you can read.

**Everything runs on `sysclk`.** AXI and the LED logic share one 125 MHz domain,
so there is no clock-domain crossing anywhere in this design. That is deliberate.
Keep it that way — CDC is a whole separate topic and mixing it in here would
obscure both.

### 3b. `fpga/sim/ws2812_axil_regs_tb.sv`

Drive the AXI channels by hand from tasks — `axil_write(addr, data)` and
`axil_read(addr, data)`. Writing those once teaches you more about AXI than
reading the spec three times, precisely because you have to decide when to assert
and release each `VALID`/`READY` yourself.

Checks: `ID` reads back; `LED_COUNT` round-trips; `START` self-clears;
`STATUS.BUSY` rises then falls; `FRAME_DONE` latches and only clears on a W1C;
`FB[n]` round-trips; and deliberately send AW before W, then W before AW, and
confirm both orderings complete.

Then a full-system testbench: AXI writes → framebuffer → FSM → PHY → monitor
decodes → compare. That is the regression test for the entire peripheral.

### 3c. Packaging — read this before you start

⚠️ **`fpga/scripts/build.tcl` globs `rtl/*.sv` into the project.** If your modules
also live inside a packaged IP, Vivado sees two definitions of every module and
synthesis fails in a confusing way. So packaging requires a file move:

```
fpga/ip/ws2812_ctrl/src/*.sv        ← the five RTL files move here
fpga/ip/ws2812_ctrl/component.xml   ← generated by the packaging script
fpga/ip/package_ws2812.tcl          ← new
```

Two script edits:

- [ ] `fpga/scripts/sim.sh:32` — add `"$FPGA_DIR"/ip/*/src/*.sv` to the `SOURCES`
      glob so simulation keeps working against the IP's sources.
- [ ] `fpga/scripts/build.tcl` — before sourcing `bd/design_1.tcl`, add
      `set_property ip_repo_paths [file normalize ../ip] [current_project]`
      followed by `update_ip_catalog`.

`package_ws2812.tcl` is the usual `ipx::` sequence: `ipx::infer_core` on the src
directory, `ipx::edit_ip_in_project`, set identity (vendor / library / name /
version), `ipx::create_xgui_files`, `ipx::update_checksums`, `ipx::save_core`.

Two things that decide whether this is painless or miserable:

1. **Port naming drives interface inference.** Name them exactly `s_axi_awaddr`,
   `s_axi_awprot`, `s_axi_awvalid`, `s_axi_awready`, `s_axi_wdata`,
   `s_axi_wstrb`, `s_axi_wvalid`, `s_axi_wready`, `s_axi_bresp`, `s_axi_bvalid`,
   `s_axi_bready`, `s_axi_araddr`, `s_axi_arprot`, `s_axi_arvalid`,
   `s_axi_arready`, `s_axi_rdata`, `s_axi_rresp`, `s_axi_rvalid`, `s_axi_rready`,
   plus `s_axi_aclk` and `s_axi_aresetn`. Get these right and Vivado infers the
   whole AXI4-Lite interface automatically. Get one wrong and you'll be mapping
   ports by hand in the GUI.
2. **Associate the clock with the interface.** Set `ASSOCIATED_BUSIF` on
   `s_axi_aclk` to your interface name, and set its `FREQ_HZ`. Skipping this is
   the reason a packaged IP sometimes drops into a BD with no clock inference and
   silently fails timing.

VLNV: pick one you control, e.g. **`forsyth:ip:ws2812_ctrl:1.0`**.

### 3d. Block design — `fpga/bd/design_1.tcl`

Hand-edit rather than re-exporting, so the diff stays reviewable. Four changes,
all following patterns already in the file:

- [ ] Add `forsyth:ip:ws2812_ctrl:1.0` to the IP existence check list at the top.
- [ ] Bump `ps7_0_axi_periph`'s `CONFIG.NUM_MI` from `{2}` to `{3}`.
- [ ] Create the cell; connect `M02_AXI` → its `S_AXI`; add `M02_ACLK` to the
      `sysclk_net` fan-out and `M02_ARESETN` to the
      `rst_sysclk_125M_peripheral_aresetn` fan-out.
- [ ] `create_bd_port -dir O npx_data` (matching the `led_o` pattern around
      L79-84), and
      `assign_bd_address -offset 0x43C00000 -range 0x00010000 ... ws2812_ctrl_0/S_AXI/Reg -force`

⚠️ **Missing either clock or reset fan-out is the classic "AXI read hangs
forever" bug.** The symptom is `mrd` in xsdb never returning. Worth knowing the
signature now so you recognize it in three seconds rather than three hours.

`0x43C0_0000` is the conventional base for custom PL IP on Zynq-7000 and doesn't
collide with the GPIOs at `0x4120_0000` / `0x4121_0000`.

`top.v` then simplifies: `u_neopixel` disappears from it, and `npx_data` comes
out of `design_1_i` instead. The XDC line is unchanged.

- [ ] **Verify before touching software:** after `yarn build_platform`, confirm
      `fpga/dist/address_map.json` contains `ws2812_ctrl_0` with the right base
      and VLNV. If it doesn't, `build.tcl`'s address-map walk didn't see it and
      nothing downstream can possibly work.

---

## Phase 4 — the Rust driver

### 4a. `libs/xil_bindings/src/ip/ws2812.rs`

- [ ] written
- [ ] registered in `libs/xil_bindings/src/ip/mod.rs`

Model it directly on the existing `libs/xil_bindings/src/ip/axi_gpio.rs`:

```rust
pub const SUPPORTED_VLNV: &str = "forsyth:ip:ws2812_ctrl:1.0";

const REG_ID:        usize = 0x000;
const REG_CTRL:      usize = 0x004;
const REG_STATUS:    usize = 0x008;
const REG_LED_COUNT: usize = 0x00C;
const FB_BASE:       usize = 0x400;

pub struct Ws2812 { base: usize }
```

`const unsafe fn new(base)`, private `read`/`write` helpers over
`ptr::read_volatile` / `write_volatile`, and a public surface of roughly:

| Method | Notes |
|---|---|
| `id()` | for the liveness check |
| `set_led_count(n)` | |
| `set_pixel(n, r, g, b)` | does the RGB→GRB swizzle and `0x00GGRRBB` packing |
| `start()` | write `CTRL[0]` |
| `is_busy()` | read `STATUS[0]` |
| `wait_done()` | poll + W1C `FRAME_DONE` |

`xil_bindings` is `#![no_std]` with **zero dependencies**. Keep it that way — no
`heapless`, no `embedded-hal`. Raw volatile access on a known address is exactly
what a driver at this layer is.

### 4b. `apps/backend/src/main.rs`

- [ ] VLNV guard added
- [ ] rainbow animating

Add the build-time guard next to the two that already exist:

```rust
const _: () = assert!(konst_str_eq(ws2812_ctrl_0::VLNV, ws2812::SUPPORTED_VLNV));
```

**Understand this mechanism — it's the best thing in this repo.** The base
address and VLNV string come out of `fpga/dist/address_map.json` via
`libs/xil_bindings/build.rs`, which *generates* the `ws2812_ctrl_0` module at
compile time. So: rebuild the bitstream with the IP at a different address and
Rust picks it up automatically, with no edit. Swap the IP for a different one and
the build *fails* rather than cheerfully writing to the wrong peripheral. That's
a compile-time proof that your software and your gateware agree, and it costs
nothing at runtime.

Then, in order: read `ID` and log it (first, before anything else — it's your
one-line proof the bus works), set `LED_COUNT`, write a rainbow into the
framebuffer, `start()`, and animate in the main loop by shifting a hue offset.
Reuse the existing switch/button reads for interaction — BTN0 cycles patterns,
switches set brightness.

Build and deploy **from `apps/backend/`**, not the workspace root — the
`.cargo/config.toml` target only applies from that directory, and a root-level
`cargo build -p backend` will build for the host and fail:

```
cd apps/backend && yarn build && bash scripts/deploy.sh
```

- [ ] While you're there: `apps/backend/package.json` has no `deploy` script even
      though `scripts/deploy.sh` exists and the README references `yarn deploy`.
      Worth adding.

---

## Verification

| Phase | Command | Pass condition |
|---|---|---|
| 1 | `cd fpga && yarn simulate ws2812_timing_tb` | `SIM PASS`; pulses measure 50 / 100 / 156 cycles |
| 1 | `cd fpga && yarn simulate ws2812_frame_fsm_tb` | `SIM PASS`; monitor decodes exactly the pixels written |
| 1 | `cd fpga && yarn simulate ws2812_frame_fsm_tb --gui` | you can visually identify a `1` and a `0` bit |
| 2 | `cd fpga && yarn build_platform && yarn deploy` | strip lights; colour follows the switches |
| 3 | `cd fpga && yarn simulate ws2812_axil_regs_tb` | `SIM PASS`; both AW/W orderings complete, no hangs |
| 3 | `yarn build_platform`, inspect `fpga/dist/address_map.json` | contains `ws2812_ctrl_0` @ `0x43C00000`, correct VLNV |
| 3 | `xsdb` → `mrd 0x43C00000` | reads `0x4E454F50` |
| 4 | `cd apps/backend && yarn build` | VLNV `const` assertion compiles |
| 4 | `bash scripts/deploy.sh`, UART @ 115200 | logs the ID; rainbow animates |

**Optional but recommended:** `turbo.json`'s `build_platform` does not currently
depend on `simulate`. Making `@repo/fpga#build_platform` depend on
`@repo/fpga#simulate` means you cannot build a bitstream whose testbenches are
failing. For a peripheral whose entire correctness is timing, that's worth
switching on. The README already documents the one-line change.

---

## Order of attack

**Finish Phase 1 completely before plugging anything in.**

The temptation with LEDs is to rush to blinking. Resist it. The correctness of
this peripheral is *timing*, timing is fully observable in a waveform and nearly
unobservable in a strip of lights, and every hour spent debugging a flickering
strip is an hour you could have spent looking at the actual signal. Get the PHY
and the monitor right and Phases 2–4 are plumbing you already know how to do from
`rtl_counter`.

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
