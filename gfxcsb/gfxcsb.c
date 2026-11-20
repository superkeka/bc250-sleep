// SPDX-License-Identifier: GPL-2.0-only
/*
 * Makes amdgpu submit the gfx block's clear state again after a sleep.
 *
 * On an APU this driver submits the clear state (the start values of the graphics context registers) once,
 * notes that in a flag of its device structure, and leaves the step out on every later start of the gfx
 * block. That is right where the block keeps its power through a sleep. On the BC-250 it loses power in S3:
 * the context registers come back holding noise, the first end-of-pipe event never returns, and the driver's
 * test of the gfx ring times out. With the flag cleared before the sleep the driver submits the clear state
 * on the way back, as it does on a first start.
 *
 *   off=N     offset of the flag in the driver's device structure (taken from the driver's code, see
 *             tools/gfxcsb-offset.sh); the module refuses to load without it
 *   clear=1   clear the flag when the module loads, and again before every sleep
 *
 * The parameter "flag" shows the flag as it is now.
 */
#include <linux/dmi.h>
#include <linux/module.h>
#include <linux/pci.h>
#include <linux/suspend.h>

static unsigned long off;
module_param(off, ulong, 0444);
MODULE_PARM_DESC(off, "offset of the flag in amdgpu's device structure (tools/gfxcsb-offset.sh)");
static bool clear = true;
module_param(clear, bool, 0644);
MODULE_PARM_DESC(clear, "clear the flag at load and before every sleep");

static struct pci_dev *card;

/* The driver's device structure starts 0x10 before its DRM device, which is the card's driver data. */
static u8 *flag_at(void)
{
	void *ddev, *adev;

	if (!card || !card->dev.driver || strcmp(card->dev.driver->name, "amdgpu"))
		return NULL;
	ddev = pci_get_drvdata(card);
	if (!ddev)
		return NULL;
	adev = ddev - 0x10;
	/* Its second field is the card itself: anything else, and the layout is not the one expected. */
	if (*(struct pci_dev **)(adev + 8) != card)
		return NULL;
	return adev + off;
}

/* Under the device's lock, so that the driver cannot leave the card meanwhile. */
static int flag_get(char *buffer, const struct kernel_param *kp)
{
	u8 *f;
	int ret;

	if (!card)
		return -ENODEV;
	device_lock(&card->dev);
	f = flag_at();
	ret = f ? sysfs_emit(buffer, "%u\n", *f) : sysfs_emit(buffer, "no driver on the card\n");
	device_unlock(&card->dev);
	return ret;
}

static const struct kernel_param_ops flag_ops = { .get = flag_get };
module_param_cb(flag, &flag_ops, NULL, 0444);
MODULE_PARM_DESC(flag, "the flag as it is now");

static void do_clear(const char *when)
{
	u8 *f;

	device_lock(&card->dev);
	f = flag_at();
	if (!f)
		pr_info("gfxcsb: %s: no driver on the card\n", when);
	else if (*f > 1)
		pr_warn("gfxcsb: %s: the byte holds %u, not a flag: left alone\n", when, *f);
	else {
		pr_info("gfxcsb: %s: flag was %u, cleared\n", when, *f);
		*f = 0;
	}
	device_unlock(&card->dev);
}

static int gfxcsb_pm(struct notifier_block *nb, unsigned long action, void *data)
{
	if (clear && (action == PM_SUSPEND_PREPARE || action == PM_HIBERNATION_PREPARE))
		do_clear("before the sleep");
	return NOTIFY_DONE;
}

static struct notifier_block gfxcsb_nb = { .notifier_call = gfxcsb_pm };

static int __init gfxcsb_init(void)
{
	if (!dmi_match(DMI_BOARD_NAME, "AMD BC-250"))
		return -ENODEV;
	if (!off)
		return -EINVAL;
	card = pci_get_domain_bus_and_slot(0, 1, PCI_DEVFN(0, 0));
	if (!card)
		return -ENODEV;
	if (clear)
		do_clear("at load");
	return register_pm_notifier(&gfxcsb_nb);
}

static void __exit gfxcsb_exit(void)
{
	unregister_pm_notifier(&gfxcsb_nb);
	pci_dev_put(card);
}

module_init(gfxcsb_init);
module_exit(gfxcsb_exit);
MODULE_LICENSE("GPL");
MODULE_DESCRIPTION("BC-250: amdgpu submits the gfx clear state again after a sleep");
