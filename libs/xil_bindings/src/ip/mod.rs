//! Hand-written register layouts, one module per IP core type.
//!
//! Keyed to the VLNV recorded in the generated address map -- see the crate
//! docs for why these are not generated.

pub mod axi_gpio;
pub mod ws2812;

pub use axi_gpio::AxiGpio;
pub use ws2812::Ws2812;
