// SPDX-License-Identifier: GPL-2.0-only
/*
 * bc250_pm: the kernel side of bc250-sleep on the AMD BC-250.
 *
 * The BC-250's firmware does not offer S3, and with a table that names it (acpi/SSDT-S3.aml) the board goes
 * to sleep but comes back with parts of the southbridge in their power-on state. This module puts them back
 * and adds what a sleep on this board needs. Every part is off unless a parameter asks for it:
 *
 *   fch=1        the southbridge as it was before the sleep. A wake-up leaves two bytes at their power-on
 *                values (0xfed802b0 = 0x04 and power-management register 0xbe = 0x53 after a cold start; at
 *                other values the next wake-up hangs early), clears the table of interrupt lines (ports
 *                0xc00/0xc01: devices with a wired interrupt, such as the USB 1.1/2.0 controllers and the
 *                ACPI event line, then raise interrupts that arrive nowhere) and changes a few more
 *                power-management bytes (0x50 among them holds the HPET's switches). All of them are saved
 *                on the way into the sleep and written back first thing on the way out.
 *   gpe=N        enable general purpose event N as a wake source in the last step before S3, S4 or S5. The
 *                firmware's tables name event 0x18 for USB wake-ups, while the southbridge raises 0x0b for
 *                them, which the kernel therefore never enables. With the module loaded, a USB device can
 *                therefore also power the board on after an ordinary shutdown (S5).
 *   rwdt=N       start the southbridge's watchdog for N seconds as soon as the kernel is back from S3: a
 *                wake-up that hangs later, in a device or in user space, ends in a reset by itself. Whoever
 *                comes back alive stops it through /dev/watchdog (tools/wdt.py stop).
 *
 * At run time (root only):
 *   kick         writing anything reads the display clock dividers of the graphics card (DENTIST_DISPCLK_CNTL)
 *                and writes the same value back: without that the first change of the display clock after a
 *                sleep is not applied, and a 4K picture stays flat green
 *   discovery=N  sets amdgpu's option "discovery" (read-only to user space) before the driver is bound to the
 *                card again: 2 makes it read the chip's table of blocks from a file (see bc250-sleep)
 */
#include <linux/acpi.h>
#include <linux/dmi.h>
#include <linux/io.h>
#include <linux/kprobes.h>
#include <linux/module.h>
#include <linux/pci.h>
#include <linux/suspend.h>
#include <linux/syscore_ops.h>

static bool fch;
module_param(fch, bool, 0444);
MODULE_PARM_DESC(fch, "put the southbridge back as it was before the sleep");
static int gpe = -1;
module_param(gpe, int, 0444);
MODULE_PARM_DESC(gpe, "general purpose event to enable as a wake source (11 for USB on the BC-250)");
static unsigned int rwdt;
module_param(rwdt, uint, 0444);
MODULE_PARM_DESC(rwdt, "seconds of the southbridge watchdog started on the way back from S3 (0: none)");

/* The southbridge's power-management registers, behind an index and a data port. */
#define PM_INDEX_PORT 0xcd6
#define PM_DATA_PORT 0xcd7

static u8 pm_read(u8 reg)
{
	outb(reg, PM_INDEX_PORT);
	return inb(PM_DATA_PORT);
}

static void pm_write(u8 reg, u8 val)
{
	outb(reg, PM_INDEX_PORT);
	outb(val, PM_DATA_PORT);
}

/* The two bytes a wake-up leaves at their power-on values, with their values after a cold start. */
#define FCH_SMI_B0 0xfed802b0UL
#define FCH_SMI_B0_COLD 0x04
#define PM_BE 0xbe
#define PM_BE_COLD 0x53
static void __iomem *smi_b0;
static int fch_seen_b0 = -1, fch_seen_be = -1;
/* The table of interrupt lines, behind an index and a data port. */
#define INTR_INDEX_PORT 0xc00
#define INTR_DATA_PORT 0xc01
static u8 intr_saved[256];
static bool intr_valid;
static int intr_put_back = -1;
/* More power-management bytes a wake-up changes. */
static const u8 pm_more[] = { 0x00, 0x04, 0x06, 0x0b, 0x50, 0x7f, 0xa1, 0xed, 0xee, 0xf0 };
static u8 pm_more_saved[ARRAY_SIZE(pm_more)];
static int pm_more_put_back = -1;

static u8 intr_read(u8 index)
{
	outb(index, INTR_INDEX_PORT);
	return inb(INTR_DATA_PORT);
}

static void intr_write(u8 index, u8 val)
{
	outb(index, INTR_INDEX_PORT);
	outb(val, INTR_DATA_PORT);
}

/* The southbridge's watchdog: two registers in its memory-mapped block, and its power-management switches. */
#define PM_WDT_CONTROL 0x48	/* bit 0: registers decoded, bit 1: watchdog off */
#define PM_WDT_CONFIG 0x4c	/* bits 1:0: 3 for ticks of a second */
#define WDT_REGS 0xfed80b00UL
#define WDT_RUN BIT(0)
#define WDT_POWER_OFF BIT(2)	/* clear: the watchdog resets the board */
#define WDT_LOAD BIT(7)
static void __iomem *wdt_regs;
static u32 wdt_seen;

/* Set in the last step of an S3 entry: what the way back does is done only after an S3 sleep. */
static bool s3_entered;

/* The ACPI event block, two halves of four bytes: status, then enable. */
static unsigned long gpe0_port;
static u32 gpe_en_before, gpe_en_after;

/* DENTIST_DISPCLK_CNTL, the display clock dividers: dword 292 of the graphics card's register BAR. */
#define KICK_REG (292 * 4)

static int kick_set(const char *val, const struct kernel_param *kp)
{
	struct pci_dev *card = pci_get_domain_bus_and_slot(0, 1, PCI_DEVFN(0, 0));
	void __iomem *io;
	int ret = 0;

	if (!card)
		return -ENODEV;
	if (card->vendor != PCI_VENDOR_ID_ATI || pci_resource_len(card, 5) < KICK_REG + 4) {
		ret = -ENODEV;
		goto out;
	}
	io = ioremap(pci_resource_start(card, 5) + KICK_REG, 4);
	if (!io) {
		ret = -ENOMEM;
		goto out;
	}
	writel(readl(io), io);
	iounmap(io);
out:
	pci_dev_put(card);
	return ret;
}

static const struct kernel_param_ops kick_ops = { .set = kick_set };
module_param_cb(kick, &kick_ops, NULL, 0200);
MODULE_PARM_DESC(kick, "write to rewrite the display clock dividers with their own value");

/* Symbols the kernel does not export, found through a probe placed and taken away at once. */
static unsigned long lookup(const char *name)
{
	struct kprobe kp = { .symbol_name = name };
	unsigned long addr;

	if (register_kprobe(&kp) < 0)
		return 0;
	addr = (unsigned long)kp.addr;
	unregister_kprobe(&kp);
	return addr;
}

/* amdgpu's variable behind its option "discovery"; amdgpu has to be loaded. */
static int *discovery_at(void)
{
	unsigned long (*lookup_name)(const char *name) = (void *)lookup("kallsyms_lookup_name");

	return lookup_name ? (int *)lookup_name("amdgpu_discovery") : NULL;
}

static int discovery_set(const char *val, const struct kernel_param *kp)
{
	int value, *at = discovery_at();

	if (kstrtoint(val, 0, &value))
		return -EINVAL;
	if (!at)
		return -ENOENT;
	pr_info("bc250_pm: amdgpu option discovery: %d -> %d\n", *at, value);
	*at = value;
	return 0;
}

static int discovery_get(char *buffer, const struct kernel_param *kp)
{
	int *at = discovery_at();

	return at ? sysfs_emit(buffer, "%d\n", *at) : -ENOENT;
}

static const struct kernel_param_ops discovery_ops = { .set = discovery_set, .get = discovery_get };
module_param_cb(discovery, &discovery_ops, NULL, 0600);
MODULE_PARM_DESC(discovery, "set amdgpu's option \"discovery\" before its driver is bound again");

/* Called by the kernel right before its PM1 write, with interrupts off and the caches flushed. */
static int bc250_pm_prepare_sleep(u8 state, u32 pm1a, u32 pm1b)
{
	if (state < ACPI_STATE_S3)
		return 0;
	/* The wake event counts for S3, S4 and S5 alike. */
	if (gpe >= 0 && gpe < 32 && gpe0_port) {
		gpe_en_before = inl(gpe0_port + 4);
		outl(BIT(gpe), gpe0_port);
		outl(gpe_en_before | BIT(gpe), gpe0_port + 4);
		gpe_en_after = inl(gpe0_port + 4);
	}
	if (state == ACPI_STATE_S3)
		s3_entered = true;
	return 0;
}

static void (*set_prepare_sleep)(int (*func)(u8 sleep_state, u32 pm1a_ctrl, u32 pm1b_ctrl));

static int bc250_pm_pm(struct notifier_block *nb, unsigned long action, void *data)
{
	if (action != PM_POST_SUSPEND)
		return NOTIFY_DONE;
	if (rwdt)
		pr_info("bc250_pm: watchdog started on the way back, control read 0x%x\n", wdt_seen);
	if (fch)
		pr_info("bc250_pm: southbridge bytes on the way back were 0x%02x 0x%02x, now 0x%02x 0x%02x; interrupt lines put back: %d, power-management bytes put back: %d\n",
			fch_seen_b0, fch_seen_be, smi_b0 ? readb(smi_b0) : 0, pm_read(PM_BE), intr_put_back,
			pm_more_put_back);
	if (gpe >= 0)
		pr_info("bc250_pm: wake event %d: enable bits 0x%x -> 0x%x\n", gpe, gpe_en_before, gpe_en_after);
	return NOTIFY_DONE;
}

static struct notifier_block bc250_pm_nb = {
	.notifier_call = bc250_pm_pm,
};

static int bc250_pm_syscore_suspend(void *data)
{
	unsigned int i;

	wdt_seen = 0;
	if (fch) {
		for (i = 0; i < 256; i++)
			intr_saved[i] = intr_read(i);
		for (i = 0; i < ARRAY_SIZE(pm_more); i++)
			pm_more_saved[i] = pm_read(pm_more[i]);
		intr_valid = true;
	}
	return 0;
}

/*
 * The module's first step on the way back: interrupts are off, only the first thread runs. The kernel calls
 * this after every syscore suspend, also around a hibernation image; only a return from S3 is acted on.
 */
static void bc250_pm_syscore_resume(void *data)
{
	unsigned int i, n;

	if (!s3_entered)
		return;
	s3_entered = false;
	if (fch && smi_b0) {
		fch_seen_b0 = readb(smi_b0);
		fch_seen_be = pm_read(PM_BE);
		writeb(FCH_SMI_B0_COLD, smi_b0);
		pm_write(PM_BE, PM_BE_COLD);
	}
	if (fch && intr_valid) {
		for (i = 0, n = 0; i < 256; i++) {
			if (intr_read(i) == intr_saved[i])
				continue;
			intr_write(i, intr_saved[i]);
			n++;
		}
		intr_put_back = n;
		for (i = 0, n = 0; i < ARRAY_SIZE(pm_more); i++) {
			if (pm_read(pm_more[i]) == pm_more_saved[i])
				continue;
			pm_write(pm_more[i], pm_more_saved[i]);
			n++;
		}
		pm_more_put_back = n;
	}
	if (!rwdt || !wdt_regs)
		return;
	/* The sleep may have put the switches back. */
	pm_write(PM_WDT_CONFIG, pm_read(PM_WDT_CONFIG) | 3);
	pm_write(PM_WDT_CONTROL, (pm_read(PM_WDT_CONTROL) & ~2) | 1);
	writel(readl(wdt_regs) & ~WDT_POWER_OFF, wdt_regs);
	writel(rwdt, wdt_regs + 4);
	writel(readl(wdt_regs) | WDT_RUN, wdt_regs);
	writel(readl(wdt_regs) | WDT_LOAD, wdt_regs);
	wdt_seen = readl(wdt_regs);
}

static const struct syscore_ops bc250_pm_syscore_ops = {
	.suspend = bc250_pm_syscore_suspend,
	.resume = bc250_pm_syscore_resume,
};

static struct syscore bc250_pm_syscore = {
	.ops = &bc250_pm_syscore_ops,
};

static int __init bc250_pm_init(void)
{
	if (!dmi_match(DMI_BOARD_NAME, "AMD BC-250")) {
		pr_err("bc250_pm: this is not an AMD BC-250\n");
		return -ENODEV;
	}
	/* Status and enable halves of four bytes each. */
	if (acpi_gbl_FADT.xgpe0_block.space_id == ACPI_ADR_SPACE_SYSTEM_IO && acpi_gbl_FADT.gpe0_block_length == 8)
		gpe0_port = acpi_gbl_FADT.xgpe0_block.address;
	set_prepare_sleep = (void *)lookup("acpi_os_set_prepare_sleep");
	if (!set_prepare_sleep)
		return -ENOENT;
	if (rwdt)
		wdt_regs = ioremap(WDT_REGS, 8);
	if (fch)
		smi_b0 = ioremap(FCH_SMI_B0, 1);
	register_syscore(&bc250_pm_syscore);
	register_pm_notifier(&bc250_pm_nb);
	set_prepare_sleep(bc250_pm_prepare_sleep);
	pr_info("bc250_pm: loaded: fch=%d gpe=%d rwdt=%u; gpe0 port 0x%lx\n", fch, gpe, rwdt, gpe0_port);
	return 0;
}

static void __exit bc250_pm_exit(void)
{
	set_prepare_sleep(NULL);
	unregister_pm_notifier(&bc250_pm_nb);
	unregister_syscore(&bc250_pm_syscore);
	if (wdt_regs)
		iounmap(wdt_regs);
	if (smi_b0)
		iounmap(smi_b0);
}

module_init(bc250_pm_init);
module_exit(bc250_pm_exit);
MODULE_DESCRIPTION("AMD BC-250: what S3 and hibernation need on this board");
MODULE_LICENSE("GPL");
