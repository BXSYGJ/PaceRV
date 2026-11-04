/* ---------------------------------------------------------------------------
 * start.S -- RV32IM boot stub for the InstRec control core
 *
 * ROM is at 0x0000_0000 (8 KiB), RAM at 0x2000_0000 (8 KiB).  .data is linked
 * into RAM but stored in ROM, so the stub copies it before zeroing .bss.
 * ------------------------------------------------------------------------- */
.section .text.start
.globl _start
.option norvc
_start:
    la sp, __stack_top
    .option push
    .option norelax
    la gp, __global_pointer$
    .option pop

    /* .data copy: ROM -> RAM */
    la t0, __data_load_start
    la t1, __data_start
    la t2, __data_end
1:  bgeu t1, t2, 2f
    lw t3, 0(t0)
    sw t3, 0(t1)
    addi t0, t0, 4
    addi t1, t1, 4
    j 1b

    /* .bss zero */
2:  la t0, __bss_start
    la t1, __bss_end
3:  bgeu t0, t1, 4f
    sw zero, 0(t0)
    addi t0, t0, 4
    j 3b

4:  la t0, trap_entry
    csrw mtvec, t0
    call main
5:  wfi
    j 5b

.balign 4
trap_entry:
    addi sp, sp, -64
    sw ra, 0(sp)
    sw t0, 4(sp)
    sw t1, 8(sp)
    sw t2, 12(sp)
    sw a0, 16(sp)
    sw a1, 20(sp)
    sw a2, 24(sp)
    sw a3, 28(sp)
    sw a4, 32(sp)
    sw a5, 36(sp)
    sw a6, 40(sp)
    sw a7, 44(sp)
    sw t3, 48(sp)
    sw t4, 52(sp)
    sw t5, 56(sp)
    sw t6, 60(sp)
    call trap_handler
    lw ra, 0(sp)
    lw t0, 4(sp)
    lw t1, 8(sp)
    lw t2, 12(sp)
    lw a0, 16(sp)
    lw a1, 20(sp)
    lw a2, 24(sp)
    lw a3, 28(sp)
    lw a4, 32(sp)
    lw a5, 36(sp)
    lw a6, 40(sp)
    lw a7, 44(sp)
    lw t3, 48(sp)
    lw t4, 52(sp)
    lw t5, 56(sp)
    lw t6, 60(sp)
    addi sp, sp, 64
    mret
