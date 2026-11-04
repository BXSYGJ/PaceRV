.option rvc
.text
.global _start
_start:
    c.li x8, 0
    .4byte 0x00140413
    c.addi x8, 1
    c.ebreak
