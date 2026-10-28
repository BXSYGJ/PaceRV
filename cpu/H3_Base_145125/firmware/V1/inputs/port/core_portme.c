#include "coremark.h"
#include "platform.h"
#if VALIDATION_RUN
volatile ee_s32 seed1_volatile = 0x3415;
volatile ee_s32 seed2_volatile = 0x3415;
#else
volatile ee_s32 seed1_volatile = 0;
volatile ee_s32 seed2_volatile = 0;
#endif
volatile ee_s32 seed3_volatile = 0x66;
volatile ee_s32 seed4_volatile = ITERATIONS;
volatile ee_s32 seed5_volatile = 0;
ee_u32 default_num_contexts = 1;
static unsigned long long start_cycles, stop_cycles, start_retired, stop_retired;
static u32 start_cache[5], stop_cache[5];
/* One hardware snapshot supplies every counter in a common interval. */
static void snapshot_all(unsigned long long *cycles, unsigned long long *retired, u32 *cache) {
    PERF_SNAPSHOT = 1;
    u32 cycle_low = PERF_CYCLES_LOW, cycle_high = PERF_CYCLES_HIGH;
    u32 retired_low = PERF_RETIRED_LOW, retired_high = PERF_RETIRED_HIGH;
    *cycles = ((unsigned long long)cycle_high << 32) | cycle_low;
    *retired = ((unsigned long long)retired_high << 32) | retired_low;
    cache[0] = PERF_I_HITS;
    cache[1] = PERF_I_MISSES;
    cache[2] = PERF_D_HITS;
    cache[3] = PERF_D_MISSES;
    cache[4] = PERF_WRITEBACKS;
}
void start_time(void) { snapshot_all(&start_cycles, &start_retired, start_cache); }
void stop_time(void) { snapshot_all(&stop_cycles, &stop_retired, stop_cache); }
CORE_TICKS get_time(void) { return (CORE_TICKS)((stop_cycles - start_cycles) / (CPU_CLOCK_HZ / 1000u)); }
secs_ret time_in_secs(CORE_TICKS ticks) { return ticks / 1000u; }
void portable_init(core_portable *portable, int *argc, char *argv[]) {
    (void)argc;
    (void)argv;
    _Static_assert(sizeof(ee_ptr_int) == sizeof(void *), "pointer width");
    _Static_assert(sizeof(ee_u32) == 4 && sizeof(ee_u16) == 2, "integer widths");
    UART_CONTROL = 0;
    GPIO_OUTPUT = 0x5a;
    STATUS_CODE = 0xc0100000u;
    ee_printf("ZGTC COREMARK READY send G; clock=%u Hz\n", CPU_CLOCK_HZ);
    while (UART_DATA != 0x47u) { }
    STATUS_CODE = 0xc0100002u;
    portable->portable_id = 1;
    ee_printf("ZGTC COREMARK START iterations=%u validation=%u\n", ITERATIONS, VALIDATION_RUN);
}
void portable_fini(core_portable *portable) {
    unsigned long long elapsed = stop_cycles - start_cycles;
    unsigned long long instructions = stop_retired - start_retired;
    ee_printf("ZGTC cycles_hex=%08x%08x retired_hex=%08x%08x clock_hz=%u\n",
        (u32)(elapsed >> 32), (u32)elapsed, (u32)(instructions >> 32), (u32)instructions, CPU_CLOCK_HZ);
    ee_printf("ZGTC config=%08x ihit=%u imiss=%u dhit=%u dmiss=%u writebacks=%u\n", PERF_CONFIG,
        stop_cache[0]-start_cache[0], stop_cache[1]-start_cache[1], stop_cache[2]-start_cache[2],
        stop_cache[3]-start_cache[3], stop_cache[4]-start_cache[4]);
    ee_printf("ZGTC COREMARK FINISHED\n");
    while ((UART_STATUS & 2u) == 0) { }
    GPIO_OUTPUT = 0xa5;
    STATUS_CODE = 0xc0100001u;
    portable->portable_id = 0;
}
void trap_handler(void) {
    u32 cause, pc, value;
    __asm__ volatile ("csrr %0, mcause" : "=r"(cause));
    __asm__ volatile ("csrr %0, mepc" : "=r"(pc));
    __asm__ volatile ("csrr %0, mtval" : "=r"(value));
    ee_printf("ZGTC TRAP cause=%08x pc=%08x value=%08x\n", cause, pc, value);
    GPIO_OUTPUT = 0xee;
    STATUS_CODE = 0xdead0000u | cause;
    for (;;) { }
}
