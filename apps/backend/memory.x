/* memory.x — Zybo Z7-10 (Zynq-7010, xc7z010clg400-1)
 *
 * aarch32-rt link.x requires exactly four named regions:
 *   VECTORS, CODE, DATA, STACKS
 *
 * OCM: 256 KB @ 0x0000_0000  (exception vector table lives here)
 * DDR: 512 MB @ 0x0010_0000  (1 MB offset, leaves PS7 init area free)
 *   Split DDR into CODE / DATA / STACKS so each section lands in its own
 *   named region as link.x demands.
 */
MEMORY
{
    VECTORS (rx)  : ORIGIN = 0x00000000, LENGTH = 256K
    CODE    (rx)  : ORIGIN = 0x00100000, LENGTH = 128M
    DATA    (rwx) : ORIGIN = 0x08100000, LENGTH = 256M
    STACKS  (rw)  : ORIGIN = 0x18100000, LENGTH = 64M
}
