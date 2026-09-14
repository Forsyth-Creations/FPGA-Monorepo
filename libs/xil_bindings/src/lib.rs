//! Rust bindings for the AXI peripherals in this repo's Vivado block design.
//!
//! Two halves that meet in the middle:
//!
//! * **Base addresses** are generated. `fpga/scripts/build.tcl` exports the
//!   block design's address segments to `fpga/dist/address_map.json`, and
//!   `build.rs` turns each into a module holding [`BASE`], [`RANGE`] and
//!   [`VLNV`]. Re-running Vivado moves an address, and the constant moves with
//!   it -- nothing here needs editing.
//!
//! * **Register layouts** are hand-written, one module per IP type under
//!   [`ip`]. Vivado does not export field-level detail for stock IP, so these
//!   come from the AMD product guides (AXI GPIO is PG144). Each driver checks
//!   the generated `VLNV` so an IP upgrade in the block design cannot silently
//!   invalidate the offsets baked in here.
//!
//! ```ignore
//! use xil_bindings::{axi_gpio_0, axi_gpio_1, ip::AxiGpio};
//!
//! // SAFETY: single-core bare-metal, nothing else touches these windows.
//! let io = unsafe { AxiGpio::new(axi_gpio_0::BASE) };
//! let ui = unsafe { AxiGpio::new(axi_gpio_1::BASE) };
//!
//! io.set_channel1(0b1010);     // drive the LEDs
//! let counter = io.channel2(); // free-running counter slice
//! let switches = ui.channel1();
//! let buttons = ui.channel2();
//! ```

#![no_std]

pub mod ip;

/// One AXI peripheral, as it appears in [`PERIPHERALS`].
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct Peripheral {
    /// Block design instance name, e.g. `axi_gpio_0`.
    pub instance: &'static str,
    /// Vendor:library:name:version of the IP core.
    pub vlnv: &'static str,
    /// Base address in the PS `Data` address space.
    pub base: usize,
    /// Size of the mapped region, in bytes.
    pub range: usize,
}

include!(concat!(env!("OUT_DIR"), "/address_map.rs"));

/// Look a peripheral up by block design instance name.
///
/// Prefer the generated per-instance modules where the name is known at compile
/// time; this is for iterating or logging the map.
pub fn find(instance: &str) -> Option<&'static Peripheral> {
    // `iter().find()` rather than indexing: PERIPHERALS is a handful of entries
    // and this stays const-generic over however many the block design has.
    PERIPHERALS.iter().find(|p| p.instance == instance)
}
