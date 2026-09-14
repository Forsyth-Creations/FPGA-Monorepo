# How this repo is structured

The idea behind this repo is to produce a canonical way of developing on a ZyboZ7 in Rust, while also using node to create a frontend

The build process will leverage turbo, so that we can orchestrate our build process all the way from bare-metal to frontend, essentially giving us the complete "full stack".

# Board Info

[Zybo Z7-20](https://digilent.com/reference/programmable-logic/zybo-z7/reference-manual?srsltid=AfmBOooj7Os0Line1PlxzMIGfUC497xVmNC3hLKUtyMpWrvWURj9_AcU)

FPGA: Programmable logic equivalent to Artix-7 FPGA
ARM Processor: 667 MHz dual-core Cortex-A9 processor

# Mental Modal

You need three things installed on your host machine: the Xilinx/AMD tools (Vivado and Vitis), a cross-compiler for ARM Cortex-A9 (aarch32, not aarch64 — the A9 is a 32-bit core), and the Yocto build environment. We will set these up one at a time. Vivado is what configures the FPGA fabric. Vitis is what builds and deploys software to the PS. Yocto builds the Linux image that runs on Core 0.

Vivado: FPGA  (PL, Programmable Logic)
Vitis: Core 0 (PS, Processing System)

# Architecture

FPGA -> Bitsteam
Core 0 -> Linux image, for web app (AMD Zynq-7000, ARM Cortex A9)
Core 1 -> no_std Rust, for bare-metal (AMD Zynq-7000, ARM Cortex A9)

**Note** the std library in Rust is the gateway to the OS. However, if you're not connecting to an OS (say, for a bare metal application) you can't reap these benefits. Everything in std that involves memory, files, threads, time, or networking ultimately makes a syscal: a call to the OS kernel to do something on your behalf

no_std at the top of a crate tells the copiler to not link to the standard library. This gives you much of the core library, including `Option` `Result` and `panic`. However, you lose anything that is heap allocated, unless you define the a heap allocator for alloc (In which case, you get back Vec, String, Box, and Arc). In base metal, you write or import an allocator that manages a fixed block of RAM. You may only use crates that have the no_std pattern.
What you lose regardless running Rust as bare-metal: File I/O, sockets, threads (OS threads), environment variables, process exit codes — anything that requires a kernel.

The no_std will need three things defined: 

1. A panic handler: usually a print to UART then a loop to capture execution (or reset the board)
2. A memory allocator: to get back Vec, String, etc
3. An entry point: You define an entrypoint to set up your environment/run things

The linker script
This is the thing most tutorials gloss over and then people get confused later. On bare metal, you are responsible for telling the linker where everything goes in memory. A linker script is a file (usually memory.x or link.x) that defines the memory map: where flash starts, where RAM starts, how big each region is, and which sections of your binary (.text, .data, .bss, .rodata) go where.

TLDR of no_std Rust: you will need an embedded-hal to support SPI, I2C, UART, and GPIO

# Creating a Bootable .wic file and flashing it to the board

```bash
sudo dd if=edf-linux-disk-image-amd-cortexa9thf-neon-common.rootfs.wic of=/dev/sdd bs=4M status=progress conv=fsync
```

To confirm the partitions after, you can use the following:

```bash
sudo fdisk -l /dev/sdd
```

You should see something like the following:

```bash
$ sudo fdisk -l /dev/sdd


Disk /dev/sdd: 58.24 GiB, 62537072640 bytes, 122142720 sectors
Disk model: MassStorageClass
Units: sectors of 1 * 512 = 512 bytes
Sector size (logical/physical): 512 bytes / 512 bytes
I/O size (minimum/optimal): 512 bytes / 512 bytes
Disklabel type: dos
Disk identifier: 0x076c4a2a

Device     Boot    Start      End  Sectors  Size Id Type
/dev/sdd1             32  1048607  1048576  512M  c W95 FAT32 (LBA)
/dev/sdd2  *     1048608  2097183  1048576  512M 83 Linux
/dev/sdd3        2097184 14680095 12582912    6G 83 Linux
/dev/sdd4       14680096 16777247  2097152    1G  c W95 FAT32 (LBA)
```

As a sanity check to ensure your boot image is present on your drive, you can do the following:

```
sudo mkdir -p /mnt/zybo-boot
sudo mount /dev/sdd1 /mnt/zybo-boot
ls -la /mnt/zybo-boot
```


# What to expect once booting

The board's FT2232 exposes two USB interfaces: interface 00 is JTAG (Vivado's
`hw_server` claims it) and interface 01 is the UART. Both show up as
`/dev/ttyUSB*`, but **the numbering is not fixed** -- it shifts when other USB
serial adapters are plugged in. Do not assume `ttyUSB1`.

Identify it by serial number rather than guessing. The UART's `ID_SERIAL_SHORT`
matches the JTAG cable serial that xsdb reports:

```bash
for d in /dev/ttyUSB*; do
  echo "== $d"
  udevadm info -q property -n $d | grep -E "ID_SERIAL_SHORT|ID_MODEL|ID_USB_INTERFACE_NUM"
done
```

Look for the FT2232 with `ID_USB_INTERFACE_NUM=01`. Then:

```
picocom -b 115200 /dev/ttyUSB2      # substitute the device you found

(Ctrl+A then Ctrl+X to leave)
```

No `sudo` needed if the device is world-writable or you are in `dialout`.

This carries both the Linux boot log and, on a bare-metal build, whatever
`apps/backend` logs -- see [Running Rust on the board](#running-rust-on-the-board).

# Running Rust on the board

The PS-side pipeline already exists end to end. `apps/backend` is a `no_std`
Cortex-A9 binary; `libs/xil_bindings` gives it the peripheral addresses; xsdb
downloads it over the same JTAG cable the bitstream goes over.

```bash
cd fpga         && yarn build_platform && yarn deploy   # PL: bitstream first
cd apps/backend && yarn build          && yarn deploy   # PS: then the ELF
```

Order matters: the ELF's addresses come from the block design the bitstream was
built from, and `xil_bindings` will not compile without `fpga/dist/address_map.json`.

Build `apps/backend` **from its own directory**. The target triple lives in
`apps/backend/.cargo/config.toml`, which cargo only reads when invoked from
there -- `cargo build -p backend` at the workspace root builds for the host and
fails inside `zynq7000-rt`.

## How the address map reaches Rust

Nothing hardcodes a base address:

1. `fpga/scripts/build.tcl` queries the block design's address segments and
   writes `fpga/dist/address_map.json`.
2. `libs/xil_bindings/build.rs` turns each entry into a module with `BASE`,
   `RANGE` and `VLNV`.
3. Register layouts *within* a peripheral are hand-written per IP type in
   `libs/xil_bindings/src/ip/`, from the AMD product guides (AXI GPIO is PG144).

Move a peripheral in Vivado and the constant moves with it. The `VLNV` is the
seam between the generated and hand-written halves: `main.rs` `const`-asserts it
against the driver's `SUPPORTED_VLNV`, so bumping an IP version in the block
design fails the build instead of producing reads off the end of a register map.

## The IO map

| Instance | Base | Channel 1 | Channel 2 |
|---|---|---|---|
| `axi_gpio_0` | `0x4120_0000` | LEDs, **outputs** | counter, inputs |
| `axi_gpio_1` | `0x4121_0000` | slide switches, inputs | pushbuttons, inputs |

```rust
use xil_bindings::{axi_gpio_0, axi_gpio_1, ip::AxiGpio};

// SAFETY: single core, nothing else touches these windows, bitstream loaded.
let io = unsafe { AxiGpio::new(axi_gpio_0::BASE) };
let ui = unsafe { AxiGpio::new(axi_gpio_1::BASE) };

io.set_channel1(0b1010);      // drive the LEDs
let counter  = io.channel2(); // PL liveness
let switches = ui.channel1();
let buttons  = ui.channel2();
```

The shipped `main.rs` mirrors the switches onto the LEDs, and shows the counter
instead while BTN0 is held.

Buttons are not debounced in hardware. Sampling the level is fine; counting
edges needs debouncing in software.

## Watching the logs

`apps/backend` logs over **UART1 on MIO 48/49 at 115200 8N1** -- the pair wired
to the USB-serial bridge, enabled by the Zybo preset in the block design
(`PCW_UART1_PERIPHERAL_ENABLE`, `UART1_IO MIO 48..49`).

```bash
picocom -b 115200 /dev/ttyUSB2     # find the right device -- see "What to expect once booting"
```

Leave it running across a `yarn deploy` and you get:

```text
INFO - backend starting -- UART1 @ 115200 baud (0.006% error)
INFO - axi_gpio_0 @ 0x41200000 (0x10000 bytes)
INFO - axi_gpio_1 @ 0x41210000 (0x10000 bytes)
INFO - counter 10 -> 11 after 509817 reads -- PL clock running
INFO - switches=0b0000 buttons=0b0000 leds=0b0000
```

then a line each time a switch or button changes.

UART is a **different FTDI channel from JTAG**, so this coexists with xsdb --
keep `picocom` open while deploying and debugging.

The logger is the `log` crate facade over `zynq7000_hal::log::uart_blocking`,
which writes inside a critical section. That means logging from a hot loop
serialises against everything else, which is why the loop in `main.rs` logs only
on input *change* while still writing the LED register every iteration.

### Reading it

Two lines are worth understanding:

* **`counter A -> B after N reads -- PL clock running`.** The counter advances
  at ~7.45 Hz, so a pair of back-to-back reads always matches; this polls until
  the value moves. `N` in the hundreds of thousands is normal (~260 ns per AXI
  read at 134 ms per tick).
* **Banner, then silence.** `sysclk` clocks the AXI fabric *and* the counter, so
  a genuinely dead PL clock does not return a stale value -- the first AXI read
  hangs on an unclocked slave. Startup lines followed by nothing is the
  signature of that, not a crash.

## Checking it from the host

`dow` gives no feedback about whether the firmware is doing anything. Two reads
over JTAG settle it without needing eyes on the board:

```bash
# Is the PL clocked? This must change between reads.
xsdb -eval 'connect; targets -set -nocase -filter {name =~ "*A9*#0"};
            configparams force-mem-access 1;
            for {set i 0} {$i < 5} {incr i} { puts [mrd -value 0x41200008]; after 250 }'

# Is software actually driving the LEDs? Poke the register and watch it
# get taken back -- main.rs writes it every iteration for exactly this reason.
xsdb -eval 'connect; targets -set -nocase -filter {name =~ "*A9*#0"};
            configparams force-mem-access 1;
            mwr 0x41200000 0xF; puts [mrd -value 0x41200000]'
```

A counter that never moves means the fabric is not clocked. A `0xF` that sticks
means the firmware is not running.

# Where are the PL Files?

Everything the PL is built from lives under `fpga/`, and all of it is either
Verilog you write or Tcl you can read. There is no `.xpr`, no `.bd` blob and no
`.xci` in version control -- `build_platform` creates the Vivado project from
scratch on every build.

```
fpga/
  rtl/                     <- YOUR VERILOG. top.v is the top level.
    top.v
    rtl_counter.v
  constraints/
    Zybo_Z7_io.xdc         <- pin + IOSTANDARD constraints
  bd/
    design_1.tcl           <- block design, exported as a reviewable Tcl proc
  sim/
    rtl_counter_tb.v       <- YOUR TESTBENCHES. one per module under test.
  scripts/
    build.sh  build.tcl    <- create project, add rtl/, synth, impl, bitstream
    sim.sh    sim.tcl      <- compile rtl/ + sim/ and run xsim
    deploy.sh deploy.tcl   <- xsdb: ps7_init, program the PL, level shifters
    xilinx-env.sh
  build/                   <- generated Vivado project (gitignored, disposable)
  sim_build/               <- generated xsim work library (gitignored, disposable)
  dist/                    <- .bit, .xsa, ps7_init.tcl, address_map.json
```

## Writing Verilog

`rtl/` is the whole story. Add a `.v` there and `build_platform` picks it up --
`build.tcl` globs the directory, so there is no file list to maintain and no
project to mutate.

`top.v` is the real top module. It owns the physical pins and instantiates two
things: the block design (`design_1`) and your own RTL. Wiring new logic means
editing `top.v`, not touching the block design.

```verilog
rtl_counter #(
    .WIDTH    (4),
    .TICK_DIV (24)   // ~7.5 increments/sec on the 125 MHz sysclk
) u_counter (
    .clk    (sysclk),
    .resetn (1'b1),   // tied off -- free-runs from configuration, see below
    .count  (count)
);

assign led = led_o;   // LEDs come from AXI GPIO 0 ch1: software owns them
```

`rtl_counter.v` is the worked example: a 4-bit counter clocked off `sysclk`,
readable from the PS on AXI GPIO 0 channel 2. Its reset is tied high, so it
advances from the moment the bitstream is configured, with no dependency on the
PS. That makes it the PL's liveness indicator -- if the count moves, the fabric
is clocked and configured. If it never moves, something upstream is wrong.

A 4-bit counter clocked straight off a 125 MHz `sysclk` would roll over around
7.6 MHz, so a prescaler gates it. `TICK_DIV` sets that divider to
`2**TICK_DIV`, so each step is a factor of two:

| `TICK_DIV` | Increments/sec | Full 0-15 cycle |
|---|---|---|
| 22 | 29.8 | 0.54 s |
| 24 (default) | 7.45 | 2.15 s |
| 26 | 1.86 | 8.59 s |

`WIDTH` and `TICK_DIV` are real module parameters, which also makes the counter
testable -- see [Simulating](#simulating).

## Clocking: the PL owns it

`sysclk` is the board's 125 MHz oscillator on pin K17, and it is the clock for
everything in the PL -- the AXI interconnect, both GPIOs, the reset block and
the counter. The PS does not generate it. `FCLK_CLK0` is disabled outright, and
the PS instead *consumes* `sysclk` on `M_AXI_GP0_ACLK` to clock its own AXI
master port.

That inverts the usual Zynq arrangement, and it is worth understanding why:

* **Under `FCLK_CLK0`**, the PL's only clock came out of the PS PLLs. Program
  the bitstream without running `ps7_init` and the fabric is configured but
  frozen -- no counter, no LEDs, and no error anywhere to tell you so.
* **Under `sysclk`**, the fabric runs the instant configuration completes. The
  PS still has to come up before *AXI* works (the interconnect resets off
  `FCLK_RESET0_N`), but PL logic that does not talk to the PS no longer waits
  on it at all.

The counter is the visible consequence: its reset is tied high, so it free-runs
regardless of PS state and is a direct readout of whether the fabric is alive.

The PS-side reset is still PS-sourced on purpose -- AXI slaves genuinely should
reset with the master driving them. `resetn` is exported from the block design
for RTL that joins the AXI fabric. Do not clock or reset free-running PL logic
from it, or you reintroduce the dependency this design removes.

## Simulating

`sim/` holds testbenches, `yarn simulate` runs them:

```bash
cd fpga
yarn simulate              # run sim/rtl_counter_tb.v, batch
yarn simulate --gui        # same run, then open the waveform viewer
yarn simulate my_tb        # pick a different testbench top
```

This is behavioral simulation of your own Verilog, and it needs nothing else to
have run first -- no project, no synthesis, no `build_platform`. `sim.sh`
compiles `rtl/*.v` and `sim/*.v` straight into a throwaway work library under
`sim_build/` with `xvlog`, elaborates the testbench with `xelab`, and runs
`xsim`. `sim_build/` is wiped on every run and gitignored, exactly like
`build/`. Sources are globbed, so adding a testbench to `sim/` is the whole of
adding a testbench.

Two things to know when writing one:

**Print `SIM PASS`.** `xsim` exits 0 even when a testbench calls `$fatal`, so
`sim.sh` reads the verdict out of the log instead: a run passes when it printed
`SIM PASS` and reported no `Fatal:`/`Error:`. A testbench that hangs, crashes or
stays silent therefore fails rather than quietly succeeding. `rtl_counter_tb.v`
is the worked example -- it counts mismatches, `$fatal`s if any survived, and
prints the sentinel otherwise.

**Turn the prescaler down.** Anything driving LEDs is divided down to human
speed, and simulating 2**23 clocks per visible event is pointless. Parameterize
the divider and override it from the testbench: `rtl_counter_tb` builds the DUT
with `TICK_DIV = 4`, so two full rollovers of the count cost 512 clocks instead
of 268 million.

`yarn simulate` is not wired into `build_platform`, so a broken testbench does
not currently block a bitstream. To make it gate the build, add this to the
`@repo/fpga#build_platform` task in `turbo.json`:

```json
"dependsOn": ["@repo/fpga#simulate"]
```

### What this does not cover

`top` itself is not worth simulating as it stands. It instantiates `design_1`,
whose centerpiece is `processing_system7_0` -- and in behavioral simulation that
is a black box with no processor model behind it. It issues no AXI transactions
and never drives `FCLK_CLK0` or `resetn`, so a `top` testbench would sit and
watch a counter that never ticks.

Verifying anything AXI-facing means building a simulation-only block design
that swaps the PS7 for an AXI Verification IP master and driving reads and
writes from the testbench. That is worth doing once you have AXI logic of your
own; right now the only thing on the bus is a stock Xilinx `axi_gpio`, which
needs no verification from you.

## Why the block design still exists

On a Zynq you cannot drop it. `processing_system7_0` is what brings up DDR, the
clocks and the AXI ports to the ARM cores -- a configured macro with roughly two
thousand ports, not something you instantiate by hand. IP Integrator also does
the AXI interconnect wiring and address assignment for you.

So the block design is the chassis and `top.v` bolts logic onto it. It is
checked in as `bd/design_1.tcl` rather than a binary `.bd`, so changes to it
show up as a readable diff. It exposes exactly four pins to `top.v`:

| Port | Direction | Meaning |
|---|---|---|
| `sysclk` | **in** | 125 MHz board oscillator -- the PL's clock, fed *into* the BD |
| `resetn` | out | peripheral reset, active low, synchronous to `sysclk` |
| `led_o` | out | AXI GPIO 0 ch1, 4-bit -- software drives the LEDs |
| `count_i` | in | AXI GPIO 0 ch2, 4-bit -- PS reads the counter |
| `sw_i` | in | AXI GPIO 1 ch1, 4-bit -- slide switches |
| `btn_i` | in | AXI GPIO 1 ch2, 4-bit -- pushbuttons |

To change the block design, edit `bd/design_1.tcl` directly, or open the
generated project under `build/`, change it in the GUI and re-export with
`write_bd_tcl -force -no_project_wrapper ../bd/design_1.tcl`.

## Building

```bash
cd fpga
yarn simulate            # behavioral sim of rtl/ (see above) -- seconds
yarn build_platform      # create project -> synth -> impl -> bitstream -> dist/
yarn deploy              # bring up the PS, program the PL, over JTAG
```

`build/` is wiped and recreated each time, so a stale project can never mask a
source change. Delete it whenever you like; it costs a rebuild and nothing else.

`dist/` holds `top.bit`, `top.xsa` (the handoff to Vitis for the PS side),
`ps7_init.tcl` (brings up the PS clocks, MIO and DDR controller), and
`address_map.json`, which `libs/xil_bindings/build.rs` turns into Rust
base-address constants.

## Deploying

`yarn deploy` runs `xsdb`, not Vivado's hardware manager, because on a Zynq the
bitstream is only half the job:

| Step | Why |
|---|---|
| `rst -system` | Clear PS and PL. Must precede `fpga` -- a later system reset would wipe the configuration. |
| `ps7_init` | PLLs, clocks, MIO, DDR. **`FCLK_CLK0` starts running here.** |
| `fpga -file top.bit` | Configure the PL. |
| `ps7_post_config` | Enable the PS-PL level shifters. Must come last, once the PL holds a valid configuration. |

`FCLK_CLK0` is the only clock the PL has and it is generated by the PS PLLs, so
programming the bitstream on its own leaves the fabric correctly configured and
completely stopped. That failure is quiet: configuration reports `End of startup
status: HIGH`, and the LEDs just sit there. If the board ever goes dark after a
deploy, this is the first thing to check.

To confirm the fabric is actually clocked without staring at the LEDs, read the
counter over AXI -- channel 2 of the AXI GPIO is wired to `count`:

```bash
xsdb -eval 'connect; targets -set -nocase -filter {name =~ "*A9*#0"};
            configparams force-mem-access 1;
            for {set i 0} {$i < 5} {incr i} { puts [mrd -value 0x41200008]; after 250 }'
```

A changing value means the clock is live. A constant one means it is not.
