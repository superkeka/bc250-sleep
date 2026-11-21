# Unlocked cores after S3

Notes for anyone who wants all eight cores back after S3 on a board with the 8-core unlock. Nothing here is
needed to use bc250-sleep: with the unlock, S3 comes back with six cores, and a hibernation keeps all eight.

## What happens

- Before the sleep, with the unlock: SMN `0x0115A818` (thread enable) = `0xfffe`, `0x0115A81C` (thread
  layout) = `0x13`, `0x0115A870` (core mask) = `0xff`.
- After the sleep: `0x3f3e`, `0x12` and `0x77`, the firmware's own six cores. These three are the only
  registers in `0x0115A800`-`0x0115A8FF` that change. All twelve threads of the six cores come back (CPUs 0-5
  and 8-13); the threads of the two unlocked cores (CPUs 6, 7, 14, 15) never report alive and stay offline
  until a reboot.
- The unlock, done in the BIOS (a DXE driver) or by an EFI program before the boot loader, sets the core mask
  to `0xff` through an SMU message, and the mask counts from the next warm reset. A cold boot and a
  hibernation go through the unlock and that reset; an S3 resume does not, since the firmware does not run
  DXE on the way back from S3.
- The firmware's setup form says it too: S3 is not supported on systems where cores or threads have been
  removed or disabled.
- With those cores offline the NVMe queues whose interrupts were on them stall, which `nvme.poll_queues=1`
  works around. A hibernation started later in the same boot hung (1 of 1), so bc250-sleep takes S3 for the
  rest of such a boot.

## What was tried

1. **From Linux after the wake-up.** Writes from the CPU to `0x0115A818` and `0x0115A81C` are dropped.
   Through the SMU message both read back `0xff`, but CPUs 6, 7, 14, 15 still do not start ("failed to
   report alive state"): the registers show the state, they do not set it.
2. **A reset in place of the sleep.** The last step of the S3 entry writes `0xCF9` = `0x06` with the sleep
   type still set. The firmware hangs at about 81 W, from a fresh boot and after a real S3 alike.
3. **A sleep that keeps the power on.** A normal S3 entry with PM1_CNT moved to another port, so that the
   final write does not cut the power, and the southbridge watchdog to reset the board afterwards. The board
   stays at 54 W and does not come back. A 3 s power cut then leaves it hung at 82 W; only a 20 s cut gets
   it out, and that resets the BIOS settings.
4. **Unlock and reset at the kernel's waking vector**, before Linux runs: the SMU answers, the mask is
   `0xff`, then a reset with the sleep type cleared, so that the firmware takes its S3 path a second time
   with eight cores. The board hangs at about 78 W and the waking vector is not reached again. A 3 s power
   cut gives a normal boot.
5. **The same with markers in the firmware's S3 boot script.** A DXE driver adds CMOS writes to the boot
   script at EndOfDxe (`EFI_S3_SAVE_STATE_PROTOCOL`): the first one before the firmware's own entries, more
   after its SMU messages. On the first pass all markers are written. On the second pass, after the reset in
   item 4, not even the first one is: the firmware stops in its early stage (PEI), before the boot script.
6. **The firmware's own reset on the S3 path.** With SMT disabled in the setup, the firmware resets the board
   at every start to apply it, S3 resume included. Two S3 sleeps in that setting hung at 79-80 W. So far
   every reset during an S3 resume has ended it, wherever it came from.
7. **A second pass through a normal boot instead of the S3 path.** At the waking vector: the unlock message,
   the southbridge PM bytes put back, the sleep type cleared, a reset. The firmware then boots normally with
   eight cores and starts an EFI program, which checks the RAM against a small correcting code per page
   computed before the sleep, leaves boot services and jumps to the kernel's waking vector in real mode.
   Linux comes back as from S3, with 16 threads. It worked 10 times out of 14, but:
   - a sleep within about two minutes of the previous wake-up hung 4 of 4, in the firmware's own S3 path,
     before any of this ran;
   - the 512 MiB of video memory is not covered, and Steam showed artifacts after a wake-up;
   - the kernel needs `memmap=` reservations for the areas the firmware writes during the boot;
   - RAM is not guaranteed to survive a reset: 4-8 single-bit flips per pass were seen, in cells that are not
     always the same.

   It was taken out of bc250-sleep as not reliable enough.

## What might help

None of this has been tried.

- **Eight cores in the early S3 path without a reset.** If the firmware set the eight-core thread enable and
  layout before it starts the cores on the S3 path, no reset would be needed. That takes a modified firmware
  image, and whether the chip accepts those values at that point is not known (from Linux it does not).
- **Seeing where the second pass stops.** The firmware's progress codes (port `0x80`) or any debug output
  would show what it waits for after the reset in item 4. The board has no POST code display.
- **Making item 7 reliable:** finding why a sleep shortly after a wake-up hangs, and covering the video
  memory.

Issues and pull requests are welcome.

## Before experimenting

- A hang inside the firmware (the board at 54-102 W and no network) needs the power cut. Usually 3 s is
  enough; after item 3 it took about 20 s, and a cut that long resets the BIOS settings, the S3 option among
  them (bc250-sleep writes it again at the next boot, and S3 works from the boot after that).
- With fast boot on in the BIOS, a 3 s cut once left the board hung at 61 W, and a 6 s cut emptied the CMOS.
- Before changing any firmware volume, keep a full copy of the flash and a way to write it back without the
  board booting (an external SPI programmer).
