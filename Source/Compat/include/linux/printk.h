/*
 * RTL8814Native — printk implementation header
 *
 * Copyright (c) 2026 DrogaBox — GPL-2.0
 */
#ifndef _LINUX_PRINTK_H_RTL8814
#define _LINUX_PRINTK_H_RTL8814

#include <linux/types.h>
#include <stdarg.h>

#ifdef __cplusplus
extern "C" {
#endif

void rtl_printk(const char *fmt, ...) __printf(1, 2);
void rtl_vprintk(const char *fmt, va_list args);
void rtl_hexdump(const char *prefix, const void *buf, size_t len);

/* Boot log ring buffer — rtl_printk mirrors here so bring-up traces are
 * always retrievable via the user client, independent of the system
 * log store (which may drop kernel IOLog output). */
#define RTL_BOOTLOG_N    4096
#define RTL_BOOTLOG_TEXT 192
struct rtl_bootlog_entry {
	uint64_t t_ns;                   /* uptime ns at print time */
	uint32_t seq;                    /* 1-based, commit marker (last write) */
	uint32_t len;
	char     text[RTL_BOOTLOG_TEXT];
};
struct rtl_bootlog {
	uint64_t next;                   /* total messages logged */
	uint32_t pad0;
	uint32_t pad1;
	struct rtl_bootlog_entry e[RTL_BOOTLOG_N];
};
void rtl_bootlog_capture(const char *s);
void rtl_bootlog_get(struct rtl_bootlog *out);
extern volatile uint32_t g_rtl_iolog;   /* console IOLog gate (test_uc knob 3) */

#ifdef __cplusplus
}
#endif

#endif /* _LINUX_PRINTK_H_RTL8814 */
