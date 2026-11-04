OUTPUT_ARCH(riscv)
ENTRY(_start)
/* ROM 8 KiB at 0x0 (firmware), RAM 8 KiB at 0x2000_0000 (data/bss/stack). */
MEMORY {
    ROM (rx)  : ORIGIN = 0x00000000, LENGTH = 8K
    RAM (rw)  : ORIGIN = 0x20000000, LENGTH = 8K
}
SECTIONS {
    .text : {
        KEEP(*(.text.start))
        *(.text .text.*)
    } > ROM
    .rodata : {
        *(.rodata .rodata.*)
        *(.srodata .srodata.*)
    } > ROM
    .data : {
        __data_start = .;
        *(.data .data.*)
        *(.sdata .sdata.*)
        __data_end = .;
    } > RAM AT > ROM
    __data_load_start = LOADADDR(.data);
    .bss (NOLOAD) : {
        __bss_start = .;
        *(.bss .bss.*)
        *(.sbss .sbss.*)
        *(COMMON)
        . = ALIGN(4);
        __bss_end = .;
    } > RAM
    __stack_top = ORIGIN(RAM) + LENGTH(RAM);
    __global_pointer$ = __data_start + 0x400;
    ASSERT(__data_end <= __stack_top - 1024, "firmware leaves insufficient stack")
}
