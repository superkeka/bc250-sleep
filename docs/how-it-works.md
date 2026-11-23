# How it works

Out of the box the BC-250 cannot sleep: its firmware offers no S3, and the kernel's s2idle does not come
back. Each step below adds one missing piece.

- **The S3 table.** The board's DSDT has no `\_S3`, so the kernel offers only s2idle. `SSDT-S3` names it.
- **BIOS option "CPU DC BTC".** It is set to on at 690 mV (`AmdSetup` bytes 0x6f6-0x6f8, `tools/setvar.py`).
  At its default (Auto) the firmware hangs on the way back from S3. A power cut of some seconds puts the
  BIOS defaults back: the boot check then writes the option again, and S3 works from the next boot.
- **The southbridge** (`bc250_pm fch=1`). A wake-up leaves parts of it in their power-on state: two
  bytes that make the next wake-up hang, the table of interrupt lines (then the USB 1.1/2.0 controllers and
  the ACPI event line raise interrupts that arrive nowhere), and a few power-management bytes, among them
  the HPET's. All are saved before the sleep and written back first thing after it.
- **USB wake-ups** (`gpe=11`). The firmware's tables name event 0x18 for USB, while the southbridge raises
  0x0b, which the kernel therefore never enables. It is enabled for an ordinary shutdown too, so a USB
  device can power the board on.
- **The HPET** is not used as a clock source around a sleep: after one it can read all ones and stop the time.
- **Unlocked cores** (`BC250_SPARE_CPUS`). The BC-250's APU has eight cores, of which the firmware enables
  six; a separate modification (the "8-core unlock", not part of this package) unmasks the other two from
  the running system. After S3 the firmware starts only its six, so the others are taken offline before
  the sleep. The disk then needs one polled queue (`nvme.poll_queues=1`): with it the block layer rebuilds
  its queue maps for the threads that are left. It has to be a kernel parameter: the driver sets up its
  queue maps when it finds the disk, and a polled queue added later with a reset of the controller does not
  get one.
- **The GPU driver** (`gfxcsb`). On an APU SteamOS's amdgpu submits the gfx block's clear state only once.
  On this board the block loses power in S3, so after the wake-up the ring test fails. The module clears the
  driver's "submitted" flag before every sleep; the offset of the flag is read out of the driver's code for
  the running kernel (`tools/gfxcsb-offset.sh`). The upstream driver (Bazzite, CachyOS) has no such flag
  and submits the clear state on every start, so there the module is not needed. CachyOS's deckify kernel
  carries SteamOS's flag, so there it is. If the code is neither,
  the old way is taken: the display session is closed and the driver comes off the card for the sleep.
- **The display clock** (`kick`). The first change of the display clock dividers after a sleep is not applied
  (a 4K picture stays flat green) unless the register is written once with its own value.
- **A watchdog** (`rwdt=240`) runs from the kernel's return until the script stops it, so a wake-up that
  hangs after the firmware ends in a reset by itself.

## Power off with wake-up

`shutdown wake` replaces the power-off with `bc250-poweroff`: the board goes down the hibernation
path with an image nobody reads (in zram, nothing goes to the disk). The firmware then leaves USB armed,
as after a hibernation, so the gamepad switches the board on; every start is a fresh boot. The power-off
lasts some seconds longer than the system's own.
