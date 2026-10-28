#include <stdarg.h>
#include "platform.h"
static void console_putc(unsigned char value) {
    uart_putc(value);
#if CONSOLE_DELAY_CYCLES > 0
    u32 started, current;
    started = TIME_LOW;
    do {
        current = TIME_LOW;
    } while ((u32)(current - started) < CONSOLE_DELAY_CYCLES);
#endif
}
static int output_number(unsigned long value, unsigned int base, int width, int zero_pad, int negative) {
    char digits[32];
    int count = 0, written = 0;
    do {
        unsigned int digit = value % base;
        digits[count++] = (char)(digit < 10 ? '0' + digit : 'a' + digit - 10);
        value /= base;
    } while (value);
    if (negative && zero_pad) { console_putc('-'); written++; }
    while (width > count + negative) { console_putc(zero_pad ? '0' : ' '); width--; written++; }
    if (negative && !zero_pad) { console_putc('-'); written++; }
    while (count) { console_putc((unsigned char)digits[--count]); written++; }
    return written;
}
int ee_printf(const char *format, ...) {
    va_list arguments;
    int written = 0;
    va_start(arguments, format);
    while (*format) {
        if (*format != '%') { console_putc((unsigned char)*format++); written++; continue; }
        format++;
        int width = 0, zero_pad = *format == '0', long_value = 0;
        while (*format >= '0' && *format <= '9') width = width * 10 + *format++ - '0';
        if (*format == 'l') { long_value = 1; format++; }
        char conversion = *format;
        if (!conversion) break;
        format++;
        if (conversion == 's') {
            const char *text = va_arg(arguments, const char *);
            while (*text) { console_putc((unsigned char)*text++); written++; }
        } else if (conversion == 'd' || conversion == 'i') {
            long value = long_value ? va_arg(arguments, long) : va_arg(arguments, int);
            unsigned long magnitude = value < 0 ? 0u - (unsigned long)value : (unsigned long)value;
            written += output_number(magnitude, 10, width, zero_pad, value < 0);
        } else if (conversion == 'u' || conversion == 'x') {
            unsigned long value = long_value ? va_arg(arguments, unsigned long) : va_arg(arguments, unsigned int);
            written += output_number(value, conversion == 'x' ? 16 : 10, width, zero_pad, 0);
        } else if (conversion == 'c') { console_putc((unsigned char)va_arg(arguments, int)); written++; }
        else { console_putc((unsigned char)conversion); written++; }
    }
    va_end(arguments);
    return written;
}
