//! WS2812B NeoPixel controller (`forsyth:ip:ws2812_ctrl:1.0`), this repo's own
//! IP. RTL in `fpga/rtl/ws2812_*.sv`; register map in `specs/neopixel.md`.
//!
//! Typical use:
//!
//! ```ignore
//! let npx = unsafe { Ws2812::new(ws2812_ctrl_0::BASE) };
//! assert_eq!(npx.id(), ws2812::ID_VALUE);
//! npx.set_led_count(8);
//! npx.set_pixel(0, 255, 0, 0);   // LED 0 red
//! npx.start();
//! npx.wait_done();
//! ```
//!
//! The hardware shifts each framebuffer word out MSB first with no reordering,
//! so the word *is* the wire format, `0x00GGRRBB`. [`Ws2812::set_pixel`] takes
//! the usual R, G, B order and does the swizzle.

use core::ptr;

/// VLNV this driver's register offsets were written against.
pub const SUPPORTED_VLNV: &str = "forsyth:ip:ws2812_ctrl:1.0";

/// What the `ID` register reads: ASCII `"NEOP"`.
pub const ID_VALUE: u32 = 0x4E45_4F50;

/// Framebuffer depth the IP is built with (`MAX_LEDS` in the RTL).
pub const MAX_LEDS: usize = 64;

const REG_ID: usize = 0x000;
const REG_CTRL: usize = 0x004;
const REG_STATUS: usize = 0x008;
const REG_LED_COUNT: usize = 0x00C;
const FB_BASE: usize = 0x400;

const CTRL_START: u32 = 1 << 0;
const CTRL_AUTO: u32 = 1 << 1;
const CTRL_SOFT_RST: u32 = 1 << 2;

const STATUS_BUSY: u32 = 1 << 0;
const STATUS_FRAME_DONE: u32 = 1 << 1;

/// Pack R, G, B into the `0x00GGRRBB` word the hardware sends as-is.
#[inline]
pub const fn pack_grb(r: u8, g: u8, b: u8) -> u32 {
    ((g as u32) << 16) | ((r as u32) << 8) | (b as u32)
}

// The swizzle is the one place a byte-order bug can hide, so pin it down.
const _: () = assert!(pack_grb(0x12, 0x34, 0x56) == 0x0034_1256);

/// A memory-mapped WS2812 controller instance.
pub struct Ws2812 {
    base: usize,
}

impl Ws2812 {
    /// # Safety
    ///
    /// `base` must be the base address of a `ws2812_ctrl` whose window is
    /// mapped, clocked and out of reset -- an access to an unclocked AXI slave
    /// hangs the bus rather than faulting. Pass a generated `BASE` constant,
    /// and make sure the bitstream is loaded first. No other `Ws2812` may alias
    /// this window.
    pub const unsafe fn new(base: usize) -> Self {
        Self { base }
    }

    #[inline]
    fn read(&self, offset: usize) -> u32 {
        // SAFETY: `new` established that the register window is valid and
        // exclusively ours; every offset used here is inside the 4 KB map.
        unsafe { ptr::read_volatile((self.base + offset) as *const u32) }
    }

    #[inline]
    fn write(&self, offset: usize, value: u32) {
        // SAFETY: as `read`.
        unsafe { ptr::write_volatile((self.base + offset) as *mut u32, value) }
    }

    /// The `ID` register. Reads [`ID_VALUE`] when the bus, the address decode
    /// and the clock are all working.
    #[inline]
    pub fn id(&self) -> u32 {
        self.read(REG_ID)
    }

    /// Number of LEDs sent per frame. The hardware clamps to 1..=MAX_LEDS.
    #[inline]
    pub fn set_led_count(&self, n: u32) {
        self.write(REG_LED_COUNT, n);
    }

    #[inline]
    pub fn led_count(&self) -> u32 {
        self.read(REG_LED_COUNT)
    }

    /// Set pixel `n` in the framebuffer. Takes effect on the next frame.
    /// Out-of-range indices are ignored.
    #[inline]
    pub fn set_pixel(&self, n: usize, r: u8, g: u8, b: u8) {
        if n < MAX_LEDS {
            self.write(FB_BASE + 4 * n, pack_grb(r, g, b));
        }
    }

    /// Send one frame. Clears a stale FRAME_DONE first, so a following
    /// [`wait_done`](Self::wait_done) waits for *this* frame.
    #[inline]
    pub fn start(&self) {
        self.write(REG_STATUS, STATUS_FRAME_DONE);
        let auto = self.read(REG_CTRL) & CTRL_AUTO;
        self.write(REG_CTRL, auto | CTRL_START);
    }

    /// With AUTO set, the hardware starts a new frame as soon as one finishes.
    #[inline]
    pub fn set_auto(&self, on: bool) {
        self.write(REG_CTRL, if on { CTRL_AUTO } else { 0 });
    }

    /// Abort any frame in flight and return the sequencer to idle.
    #[inline]
    pub fn soft_reset(&self) {
        let auto = self.read(REG_CTRL) & CTRL_AUTO;
        self.write(REG_CTRL, auto | CTRL_SOFT_RST);
    }

    #[inline]
    pub fn is_busy(&self) -> bool {
        self.read(REG_STATUS) & STATUS_BUSY != 0
    }

    /// Spin until the current frame has been sent and latched, then clear
    /// FRAME_DONE. A 64-LED frame takes about 2.2 ms.
    pub fn wait_done(&self) {
        while self.read(REG_STATUS) & STATUS_FRAME_DONE == 0 {}
        self.write(REG_STATUS, STATUS_FRAME_DONE);
    }
}
