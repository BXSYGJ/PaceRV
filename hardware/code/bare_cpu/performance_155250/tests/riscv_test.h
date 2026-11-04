#ifndef RV32IMC_TEST_ENVIRONMENT
#define RV32IMC_TEST_ENVIRONMENT
#define RVTEST_RV32U
#define RVTEST_RV64U
#define TESTNUM gp
#define RVTEST_CODE_BEGIN .section .text.start; .global _start; _start:; la t0, unexpected_trap; csrw mtvec, t0;
#define RVTEST_CODE_END .balign 4; unexpected_trap:; li t0, 0x10000000; li t1, 0xbad00000; csrr t2, mcause; or t1, t1, t2; sw t1, 0(t0); 1: j 1b;
#define RVTEST_PASS li t0, 0x10000000; li t1, 0xc0decafe; sw t1, 0(t0); 1: j 1b;
#define RVTEST_FAIL li t0, 0x10000000; li t1, 0xbad10000; or t1, t1, TESTNUM; sw t1, 0(t0); 1: j 1b;
#define RVTEST_DATA_BEGIN .balign 16;
#define RVTEST_DATA_END
#endif
