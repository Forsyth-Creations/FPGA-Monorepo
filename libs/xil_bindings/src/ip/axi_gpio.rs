//! AXI GPIO (`xilinx.com:ip:axi_gpio:2.0`), register map per AMD PG144.
//!
//! The block design instantiates two of these, both dual-channel and 4 bits
//! wide:
//!
//! | Instance | Channel 1 | Channel 2 |
//! |---|---|---|
//! | `axi_gpio_0` | LEDs, **outputs** | free-running counter, inputs |
//! | `axi_gpio_1` | slide switches, inputs | pushbuttons, inputs |
//!
//! So [`AxiGpio::set_channel1`] on `axi_gpio_0` is what lights the LEDs, and
//! everything else here reads.
//!
//! The counter on `axi_gpio_0` channel 2 is the PL clock's liveness indicator:
//! it is clocked by `sysclk` with its reset tied high, so it advances from the
//! moment the bitstream is configured, whether or not the PS came up. A value
//! that never changes means the fabric is not running.

use core::ptr;

/// VLNV this driver's register offsets were written against.
///
/// Compare against a generated `VLNV` constant before trusting the offsets --
/// [`AxiGpio::new`] does not do it for you, because the check is only
/// meaningful at the call site that knows which instance it is opening.
pub const SUPPORTED_VLNV: &str = "xilinx.com:ip:axi_gpio:2.0";

// PG144 Table 2-4. Channel 2 registers exist only when the core is generated
// with C_IS_DUAL=1, which this block design's instance is.
const GPIO_DATA: usize = 0x0000;
const GPIO_TRI: usize = 0x0004;
const GPIO2_DATA: usize = 0x0008;
const GPIO2_TRI: usize = 0x000C;

/// A memory-mapped AXI GPIO instance.
///
/// Not `Sync`: the registers are read-modify-write and the core offers no
/// atomic set/clear aliases, so sharing one across contexts needs external
/// synchronisation.
pub struct AxiGpio {
    base: usize,
}

impl AxiGpio {
    /// # Safety
    ///
    /// `base` must be the base address of an AXI GPIO whose window is mapped,
    /// clocked and out of reset -- an access to an unclocked AXI slave hangs the
    /// bus rather than faulting. Pass a generated `BASE` constant, and make sure
    /// the bitstream is loaded first. No other `AxiGpio` may alias this window.
    pub const unsafe fn new(base: usize) -> Self {
        Self { base }
    }

    #[inline]
    fn read(&self, offset: usize) -> u32 {
        // SAFETY: `new` established that the whole register window is valid and
        // exclusively ours; every offset used here is within PG144's map.
        unsafe { ptr::read_volatile((self.base + offset) as *const u32) }
    }

    #[inline]
    fn write(&self, offset: usize, value: u32) {
        // SAFETY: as `read`.
        unsafe { ptr::write_volatile((self.base + offset) as *mut u32, value) }
    }

    /// Drive channel 1's outputs.
    #[inline]
    pub fn set_channel1(&self, value: u32) {
        self.write(GPIO_DATA, value);
    }

    /// Read channel 1. On an all-inputs channel (`axi_gpio_1`, the switches)
    /// this is the pin state; on an all-outputs channel (`axi_gpio_0`, the
    /// LEDs) it reads the output register back.
    #[inline]
    pub fn channel1(&self) -> u32 {
        self.read(GPIO_DATA)
    }

    /// Read channel 2's inputs.
    #[inline]
    pub fn channel2(&self) -> u32 {
        self.read(GPIO2_DATA)
    }

    /// Set channel 1's three-state register: a 1 bit makes that line an input,
    /// a 0 bit an output.
    ///
    /// Both instances tie channel 1's direction in hardware (`C_ALL_OUTPUTS=1`
    /// on `axi_gpio_0`, `C_ALL_INPUTS=1` on `axi_gpio_1`), which makes this
    /// write a no-op. It is here for a block design that later relaxes that.
    #[inline]
    pub fn set_channel1_direction(&self, tri: u32) {
        self.write(GPIO_TRI, tri);
    }

    /// Channel 2's three-state register. `C_ALL_INPUTS_2=1` ties this too.
    #[inline]
    pub fn set_channel2_direction(&self, tri: u32) {
        self.write(GPIO2_TRI, tri);
    }
}
