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

The Zybo Z7-20 has two USB peripherals:  `/dev/ttyUSB0 (JTAG)` and `/dev/ttyUSB1 (UART)`. For viewing the boot process, you're going to want to be connected over UART. You can use the following command:

```
sudo minicom -D /dev/ttyUSB1 -b 115200

(Cntl+A then X to leave)
```


