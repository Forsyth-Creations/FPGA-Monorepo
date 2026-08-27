#![no_std]
#![no_main]

use core::panic::PanicInfo;
use cortex_ar as _;
use defmt::println;
use defmt_brtt as _;
use zynq7000_rt as _;

#[panic_handler]
fn panic(_info: &PanicInfo) -> ! {
    loop {}
}

defmt::timestamp!("{=u64}", { 0u64 });

#[zynq7000_rt::entry]
fn main() -> ! {
    println!("Hello, world!");
    loop {}
}
