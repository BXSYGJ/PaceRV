#include "riscv_test.h"
.option rvc
RVTEST_CODE_BEGIN
    la t0, interrupt_handler
    csrw mtvec, t0
    csrw mstatus, zero
    li s0, 0
    li TESTNUM, 1
    li s1, 0x80000003
    li s4, 0x10000310
    li s5, 0
    li t0, 8
    csrw mie, t0
    li t0, 1
    sw t0, 0(s4)
    la s3, software_resume
    csrw mepc, s3
    li t0, 0x80
    csrw mstatus, t0
    mret
    j fail
    .balign 4
    c.nop
software_resume:
    li t0, 1
    bne s0, t0, fail
    csrci mstatus, 8
    li TESTNUM, 2
    li s1, 0x80000007
    li s4, 0x1000030c
    li s5, -1
    li t0, 128
    csrw mie, t0
    sw zero, -4(s4)
    sw zero, 0(s4)
    la s3, timer_resume
    csrw mepc, s3
    li t0, 0x80
    csrw mstatus, t0
    mret
    j fail
    .balign 4
    c.nop
timer_resume:
    li t0, 2
    bne s0, t0, fail
    csrci mstatus, 8
    li TESTNUM, 3
    li s1, 0x8000000b
    li s4, 0x10000108
    li s5, 0
    li t0, 0x800
    csrw mie, t0
    li t0, 2
    sw t0, 0(s4)
    la s3, external_resume
    csrw mepc, s3
    li t0, 0x80
    csrw mstatus, t0
    mret
    j fail
    .balign 4
    c.nop
external_resume:
    li t0, 3
    bne s0, t0, fail
    csrci mstatus, 8
    RVTEST_PASS
fail:
    RVTEST_FAIL
    .balign 4
interrupt_handler:
    csrr t0, mcause
    bne t0, s1, fail
    csrr t0, mepc
    bne t0, s3, fail
    sw s5, 0(s4)
    addi s0, s0, 1
    mret
RVTEST_CODE_END
