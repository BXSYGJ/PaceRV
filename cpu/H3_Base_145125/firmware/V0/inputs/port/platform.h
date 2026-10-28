#ifndef RV32_PLATFORM_H
#define RV32_PLATFORM_H
typedef unsigned int u32;
_Static_assert(sizeof(u32) == 4, "RV32 requires 32-bit unsigned int");
#define MMIO(address) (*(volatile u32 *)(address))
#define STATUS_CODE MMIO(0x10000000u)
#define UART_DATA MMIO(0x10000100u)
#define UART_STATUS MMIO(0x10000104u)
#define UART_CONTROL MMIO(0x10000108u)
#define GPIO_OUTPUT MMIO(0x10000200u)
#define GPIO_INPUT MMIO(0x10000204u)
#define GPIO_ENABLE MMIO(0x10000208u)
#define GPIO_PENDING MMIO(0x1000020cu)
#define TIME_LOW MMIO(0x10000300u)
#define TIME_HIGH MMIO(0x10000304u)
#define COMPARE_LOW MMIO(0x10000308u)
#define COMPARE_HIGH MMIO(0x1000030cu)
#define SOFTWARE_IRQ MMIO(0x10000310u)
#define PERF_SNAPSHOT MMIO(0x10000400u)
#define PERF_CONFIG MMIO(0x10000404u)
#define PERF_CYCLES_LOW MMIO(0x10000410u)
#define PERF_CYCLES_HIGH MMIO(0x10000414u)
#define PERF_RETIRED_LOW MMIO(0x10000418u)
#define PERF_RETIRED_HIGH MMIO(0x1000041cu)
#define PERF_I_HITS MMIO(0x10000420u)
#define PERF_I_MISSES MMIO(0x10000424u)
#define PERF_D_HITS MMIO(0x10000428u)
#define PERF_D_MISSES MMIO(0x1000042cu)
#define PERF_WRITEBACKS MMIO(0x10000430u)
static inline void uart_putc(unsigned char value) {
    while ((UART_STATUS & 1u) == 0u) { }
    UART_DATA = value;
}
static inline void uart_puts(const char *text) {
    while (*text) uart_putc((unsigned char)*text++);
}
#endif
