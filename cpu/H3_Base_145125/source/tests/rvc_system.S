#include "riscv_test.h"
.option rvc
RVTEST_CODE_BEGIN
    la sp, __stack_top
    la t0, expected_trap
    csrw mtvec, t0
    li s0, 0
    li TESTNUM, 1
    csrr t0, misa
    andi t0, t0, 4
    beqz t0, fail
    li TESTNUM, 2
    li a0, 0x123
    .2byte 0x6005
    .2byte 0x0006
    .2byte 0x802a
    .2byte 0x902a
    li t0, 0x123
    bne a0, t0, fail
    li TESTNUM, 3
    li s1, 2
    li s2, 0
    la s3, after_illegal
    .balign 4
    c.nop
illegal_half:
    .2byte 0x0000
after_illegal:
    li t0, 1
    bne s0, t0, fail
    li TESTNUM, 4
    li s1, 3
    la s2, compressed_break
    la s3, after_break
    .balign 4
    c.nop
compressed_break:
    c.ebreak
after_break:
    li t0, 2
    bne s0, t0, fail
    li TESTNUM, 5
    li s1, 11
    li s2, 0
    la s3, after_ecall
    .balign 4
    c.nop
    ecall
after_ecall:
    li t0, 3
    bne s0, t0, fail
    li TESTNUM, 6
    call patch_target
    li t0, 1
    bne a0, t0, fail
    la t0, patch_target
    li t1, 0x4509
    sh t1, 0(t0)
    fence.i
    call patch_target
    li t0, 2
    bne a0, t0, fail
    li TESTNUM, 7
    li s1, 2
    li s2, 0x4002
    la s3, after_reserved
    .balign 4
    c.nop
    .2byte 0x4002
after_reserved:
    li t0, 4
    bne s0, t0, fail
    li TESTNUM, 8
    li t0, 0xfffe
    li t1, 0x0413
    sh t1, 0(t0)
    fence.i
    li s1, 1
    li s2, 0x10000
    la s3, after_boundary_fault
    jr t0
after_boundary_fault:
    li t0, 5
    bne s0, t0, fail
    li TESTNUM, 9
    li s1, 1
    li s2, 0x10002
    la s3, after_range_fault
    jr s2
after_range_fault:
    li t0, 6
    bne s0, t0, fail
    li TESTNUM, 10
    la t0, resume_halfword
    csrw mepc, t0
    mret
    j fail
    .balign 4
    c.nop
resume_halfword:
    RVTEST_PASS
fail:
    RVTEST_FAIL
    .balign 4
expected_trap:
    csrr t0, mcause
    bne t0, s1, fail
    csrr t0, mtval
    bne t0, s2, fail
    csrr t0, mepc
    andi t0, t0, 3
    li t1, 2
    bne t0, t1, fail
    csrw mepc, s3
    addi s0, s0, 1
    mret
    .balign 32
patch_target:
    c.li a0, 1
    c.jr ra
RVTEST_CODE_END
