//! Bare-metal Cortex-A9 firmware for the Zybo Z7-20.
//!
//! Drives the LEDs and reads the switches and buttons over AXI:
//!
//! * LEDs normally mirror the four slide switches.
//! * Holding BTN0 shows the PL's free-running counter on the LEDs instead,
//!   which is a live check that `sysclk` is running in the fabric.
//! * Every change is logged over the PS UART.
//! * A rainbow scrolls along the WS2812B strip on Pmod JE; the slide switches
//!   set its brightness.
//!
//! Peripheral base addresses are generated from the block design -- see
//! `libs/xil_bindings`. Nothing here hardcodes an AXI address.
//!
//! # Logging
//!
//! Logs go out of UART1 on MIO 48/49 at 115200 8N1, which is the pair wired to
//! the board's USB-serial bridge. On the host that is the *second* interface of
//! the Digilent FT2232 -- the first is JTAG -- so watch it with:
//!
//! ```text
//! picocom -b 115200 /dev/ttyUSB2
//! ```
//!
//! Check the device: the number shifts if other USB serial adapters are
//! present. `udevadm info -q property -n /dev/ttyUSBn | grep ID_SERIAL_SHORT`
//! should match the board's JTAG serial.
//!
//! UART is a different FTDI channel from JTAG, so this runs happily alongside
//! xsdb -- you can keep the debugger attached while watching logs.

#![no_std]
#![no_main]

use core::panic::PanicInfo;
use cortex_ar as _;
use fugit::RateExtU32;
use log::{LevelFilter, error, info};
use xil_bindings::{
    axi_gpio_0, axi_gpio_1,
    ip::{AxiGpio, Ws2812, axi_gpio, ws2812},
    ws2812_ctrl_0,
};
use zynq7000_hal::{
    clocks::Clocks,
    gpio::mio::Pins as MioPins,
    log::uart_blocking,
    uart::{ClockConfig, Config as UartConfig, Uart, UartId},
};
use zynq7000_rt as _;

/// The frequency of PS_CLK, the external oscillator feeding the PS PLLs. Fixed
/// by the board and matched by the Zybo preset in `fpga/bd/design_1.tcl`
/// (`PCW_CRYSTAL_PERIPHERAL_FREQMHZ 33.333333`). The clock tree is read back
/// from the SLCR registers at runtime, but that readback is in PLL multiples,
/// so it needs this as its base.
const PS_CLK_HZ: u32 = 33_333_333;

const BAUD: u32 = 115_200;

/// LEDs on the strip. Sending more than are attached is harmless -- the extra
/// bits fall off the end of the chain.
const NUM_LEDS: usize = 64;

#[panic_handler]
fn panic(info: &PanicInfo) -> ! {
    // The logger takes a critical section per write, so it is still usable from
    // here as long as the panic did not happen mid-write.
    error!("panic: {}", info);
    uart_blocking::flush();
    loop {}
}

/// The offsets in the AxiGpio driver are only valid for the IP version they
/// were written against. The block design's version is a generated constant, so
/// a core upgrade in Vivado stops the build here rather than producing reads
/// off the end of the register map.
const _: () = assert!(
    konst_str_eq(axi_gpio_0::VLNV, axi_gpio::SUPPORTED_VLNV),
    "axi_gpio_0 is not the IP version xil_bindings::ip::axi_gpio was written for"
);
const _: () = assert!(
    konst_str_eq(axi_gpio_1::VLNV, axi_gpio::SUPPORTED_VLNV),
    "axi_gpio_1 is not the IP version xil_bindings::ip::axi_gpio was written for"
);
const _: () = assert!(
    konst_str_eq(ws2812_ctrl_0::VLNV, ws2812::SUPPORTED_VLNV),
    "ws2812_ctrl_0 is not the IP version xil_bindings::ip::ws2812 was written for"
);

#[zynq7000_rt::entry]
fn main() -> ! {
    // --- Logging over UART1 -----------------------------------------------
    //
    // ps7_init (run by the deploy script) has already configured the PLLs, so
    // the clock tree is read back from the SLCR rather than recomputed.
    let clocks = Clocks::new_from_regs(PS_CLK_HZ.Hz()).expect("reading PS clock config");

    // SAFETY: called once, before anything else takes the GPIO or UART1 blocks.
    let mio = MioPins::new(unsafe { zynq7000::gpio::Gpio::new_mmio_fixed() });
    let uart_regs = unsafe { UartId::Uart1.regs() };

    // The divisors come out of the actual UART reference clock, so this stays
    // correct if the PS clock configuration ever changes.
    let (clk_cfg, baud_error) = ClockConfig::new_autocalc_with_error(clocks.io_clocks(), BAUD)
        .expect("no viable UART divisor for the target baud");

    let uart = Uart::new_with_mio(
        uart_regs,
        UartConfig::new_with_clk_config(clk_cfg),
        (mio.mio48, mio.mio49), // MIO48 = TX, MIO49 = RX -- the USB-serial bridge
    )
    .expect("UART1 on MIO48/49");

    uart_blocking::init_with_locks(uart, LevelFilter::Info);

    info!("backend starting -- UART1 @ {} baud ({:.3}% error)", BAUD, baud_error);

    for p in xil_bindings::PERIPHERALS {
        info!("{} @ {:#x} ({:#x} bytes)", p.instance, p.base, p.range);
    }

    // SAFETY: single core, nothing else in this binary touches these windows,
    // and the bitstream is loaded before this ELF is downloaded. Both bases are
    // generated from the block design that bitstream was built from.
    let io = unsafe { AxiGpio::new(axi_gpio_0::BASE) };
    let ui = unsafe { AxiGpio::new(axi_gpio_1::BASE) };
    // SAFETY: as above.
    let npx = unsafe { Ws2812::new(ws2812_ctrl_0::BASE) };

    // PL liveness. The counter runs off sysclk with its reset tied high, so it
    // advances from configuration onward -- but only at ~7.45 Hz, i.e. once per
    // 134 ms. Two back-to-back reads are microseconds apart and would always
    // match, so this polls until the value moves rather than sampling twice.
    //
    // Note what this can and cannot catch. sysclk clocks the AXI fabric as well
    // as the counter, so if it were truly dead the read below would hang on an
    // unclocked AXI slave rather than returning a stale value -- a firmware
    // that logs the banner above and then goes silent is the signature of that.
    // What this check catches is the narrower case: fabric clocked, counter not
    // advancing.
    const LIVENESS_READS: u32 = 2_000_000;
    let start = io.channel2();
    let mut reads = 0u32;
    let mut now = start;
    while now == start && reads < LIVENESS_READS {
        now = io.channel2();
        reads += 1;
    }
    if now == start {
        error!("counter stuck at {start} over {reads} reads -- PL clock suspect");
    } else {
        info!("counter {start} -> {now} after {reads} reads -- PL clock running");
    }

    // NeoPixel liveness: one read proves the bus, the address decode and the
    // IP's clock, before any LED behaviour is involved.
    let id = npx.id();
    let npx_ok = id == ws2812::ID_VALUE;
    if npx_ok {
        info!("ws2812_ctrl_0 ID {id:#010x} (\"NEOP\") -- NeoPixel IP alive");
        npx.set_led_count(NUM_LEDS as u32);
    } else {
        error!("ws2812_ctrl_0 ID {id:#010x}, expected {:#010x} -- not driving the strip", ws2812::ID_VALUE);
    }

    let mut frame: u32 = 0;
    let mut last = None;

    loop {
        let switches = ui.channel1() & 0xF;
        let buttons = ui.channel2() & 0xF;

        // BTN0 held: show the free-running counter instead of the switches.
        let leds = if buttons & 0b0001 != 0 {
            io.channel2() & 0xF
        } else {
            switches
        };

        // Written unconditionally rather than only on change. It costs one AXI
        // write per iteration and makes ownership observable: poke the register
        // over JTAG and this loop puts it back, which is how you tell "software
        // is driving the LEDs" from "the register happens to hold that value".
        io.set_channel1(leds);

        // Next rainbow frame whenever the last one has gone out (~450 fps for
        // 64 LEDs). The hue advances every 4th frame, so one trip round the
        // wheel takes a couple of seconds.
        if npx_ok && !npx.is_busy() {
            let offset = (frame / 4) as u8;
            let level = (switches as u8) * 16 + 15; // 15..=255, never fully dark
            for i in 0..NUM_LEDS {
                let hue = offset.wrapping_add((i * 256 / NUM_LEDS) as u8);
                let (r, g, b) = wheel(hue);
                npx.set_pixel(i, dim(r, level), dim(g, level), dim(b, level));
            }
            npx.start();
            frame = frame.wrapping_add(1);
        }

        // The log, unlike the register write, is rate-limited to actual input
        // changes -- a blocking UART write per loop iteration would dominate
        // the loop and flood the terminal.
        if last != Some((switches, buttons)) {
            info!("switches={switches:#06b} buttons={buttons:#06b} leds={leds:#06b}");
            last = Some((switches, buttons));
        }
    }
}

/// Colour wheel: 0..=255 walks red -> green -> blue -> red. Integer-only, so it
/// needs no floating point or libm.
fn wheel(pos: u8) -> (u8, u8, u8) {
    match pos {
        0..=84 => (255 - pos * 3, pos * 3, 0),
        85..=169 => {
            let p = pos - 85;
            (0, 255 - p * 3, p * 3)
        }
        _ => {
            let p = pos - 170;
            (p * 3, 0, 255 - p * 3)
        }
    }
}

/// Scale a colour channel by a brightness of 0..=255.
fn dim(c: u8, level: u8) -> u8 {
    ((c as u16 * level as u16) / 255) as u8
}

/// `str` equality is not `const` on stable, and this needs to run in a
/// `const` assert.
const fn konst_str_eq(a: &str, b: &str) -> bool {
    let (a, b) = (a.as_bytes(), b.as_bytes());
    if a.len() != b.len() {
        return false;
    }
    let mut i = 0;
    while i < a.len() {
        if a[i] != b[i] {
            return false;
        }
        i += 1;
    }
    true
}
