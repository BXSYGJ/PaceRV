#ifndef ZGTC_CORE_PORTME_H
#define ZGTC_CORE_PORTME_H
#include <stddef.h>
#define HAS_FLOAT 0
#define HAS_TIME_H 0
#define HAS_STDIO 0
#define HAS_PRINTF 0
#define SEED_METHOD SEED_VOLATILE
#define MEM_METHOD MEM_STATIC
#define MEM_LOCATION "64KiB on-chip RAM; cache mode/geometry in ZGTC config"
#define MULTITHREAD 1
#define MAIN_HAS_NOARGC 1
#define MAIN_HAS_NORETURN 0
#define COMPILER_VERSION "GCC " __VERSION__
#define COMPILER_FLAGS FLAGS_STR
#ifndef CPU_CLOCK_HZ
#define CPU_CLOCK_HZ 27000000u
#endif
typedef signed short ee_s16;
typedef unsigned short ee_u16;
typedef signed int ee_s32;
typedef unsigned int ee_u32;
typedef unsigned char ee_u8;
typedef unsigned int ee_ptr_int;
typedef size_t ee_size_t;
typedef double ee_f32;
typedef ee_u32 CORE_TICKS;
typedef struct { ee_u8 portable_id; } core_portable;
#define align_mem(address) ((void *)(4u + (((ee_ptr_int)(address) - 1u) & ~3u)))
extern ee_u32 default_num_contexts;
void portable_init(core_portable *portable, int *argc, char *argv[]);
void portable_fini(core_portable *portable);
int ee_printf(const char *format, ...);
#endif
