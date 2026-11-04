.option rvc
.text
.align 2
.global rvc_vectors
rvc_vectors:
    c.nop
    c.addi x1, 1
    c.addi x2, -1
    c.li x5, -1
    c.lui x6, 1
    addi sp, sp, 16
    c.slli x7, 3
    c.srli x8, 2
    c.srai x9, 1
    c.andi x10, -4
    c.add x11, x12
    c.sub x13, x14
    xor x15, x15, x14
    or x15, x15, x14
    and x15, x15, x14
    c.mv x21, x22
    c.add x23, x24
    c.j 8
    c.jal 8
    c.beqz x8, 8
    c.bnez x9, -8
    c.jr x1
    c.jalr x1
    c.ebreak
    c.lw x8, 0(x9)
    c.sw x8, 4(x9)
    c.lwsp x10, 8(sp)
    c.swsp x10, 12(sp)
    addi x8, sp, 16

.section .rvcraw,"ax"
.align 2
rvc_raw_vectors:
    .hword 0xa021
    .hword 0x2021
    .hword 0xc011
    .hword 0xe011
