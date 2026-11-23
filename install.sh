#!/bin/bash
# SPDX-License-Identifier: GPL-2.0-only
# Installs bc250-sleep behind Steam's "Sleep" on an AMD BC-250 running SteamOS, Bazzite or CachyOS (see
# README.md).
#   sudo ./install.sh              install or update; the ACPI table counts from the next reboot
#   sudo ./install.sh --uninstall  take it out again
# Which sleep the button takes: sudo /etc/bc250-sleep/bc250-sleep mode hibernate|s3
# The power-off a gamepad can undo:  sudo /etc/bc250-sleep/bc250-sleep shutdown wake|default
set -euo pipefail
[ "$(id -u)" = 0 ] || { echo "run with sudo"; exit 1; }
HERE=$(cd "$(dirname "$0")" && pwd)
DIR=/etc/bc250-sleep
VAR=/var/lib/bc250-sleep
DROPIN=/etc/systemd/system/systemd-suspend.service.d/bc250-sleep.conf
# A display-only sleep installed earlier by other means is put aside while this one is installed.
UNIT=/etc/systemd/system/bc250-sleep-boot.service
UPDATE_UNIT=/etc/systemd/system/bc250-sleep-update.service
POWEROFF_DROPIN=/etc/systemd/system/systemd-poweroff.service.d/bc250-sleep.conf
# The same power-off from its earlier, separate package (bc250-wake), taken over here.
OLD_WAKE_DROPIN=/etc/systemd/system/systemd-poweroff.service.d/bc250-wake.conf
# The files in /etc that a SteamOS update keeps (it drops all others there).
KEEP=/etc/atomic-update.conf.d/bc250-sleep.conf
LOG=$VAR/update.log
# shellcheck source=tools/system.sh
. "$HERE/tools/system.sh"

unload() {
	rmmod bc250_pm 2> /dev/null || true
	rmmod s3_smu 2> /dev/null || true # its name in earlier versions
	rmmod gfxcsb 2> /dev/null || true
}

if [ "${1:-}" = --uninstall ]; then
	systemctl disable bc250-sleep-boot.service bc250-sleep-update.service 2> /dev/null || true
	if [ -x "$DIR/bc250-update" ]; then
		"$DIR/bc250-update" acpi remove || echo "the S3 table could not be taken out of the ACPI archive"
	fi
	rm -f "$UNIT" "$UPDATE_UNIT" "$DROPIN" "$POWEROFF_DROPIN" "$KEEP"
	[ ! -x "$DIR/nvme-param.sh" ] || "$DIR/nvme-param.sh" remove > /dev/null || echo "nvme.poll_queues=1 could not be removed"
	unload
	systemctl daemon-reload
	echo "removed. Left in place, to take out by hand if wanted:"
	echo "  $DIR (with your config) and $VAR (the log)"
	echo "  the BIOS option CPU DC BTC (BIOS setup, or: sudo python3 $DIR/setvar.py 0x6f6=0xf 0x6f7=0 0x6f8=0)"
	case "$SYS" in
	steamos | pacman) echo "  the compiler and the kernel's build files (pacman; a SteamOS update takes them out anyway)" ;;
	ostree) echo "  the container image $BUILD_IMAGE (podman rmi $BUILD_IMAGE)" ;;
	esac
	exit 0
fi

[ "$(cat /sys/class/dmi/id/board_name 2> /dev/null)" = "AMD BC-250" ] || { echo "this is not an AMD BC-250"; exit 1; }

install -d -m 755 "$DIR" "$DIR/src" "$DIR/gfxcsb" "$DIR/tmp" "$VAR"
# Files of earlier versions that this one no longer has.
rm -f "$DIR/src/"* "$DIR/gfxcsb/"* "$DIR/hib-image" "$DIR/hib-reserve" "$DIR/cmos.py" "$DIR/memmap-param.sh"
install -m 644 "$HERE/src/bc250_pm.c" "$HERE/src/Makefile" "$DIR/src/"
install -m 644 "$HERE/gfxcsb/gfxcsb.c" "$HERE/gfxcsb/Makefile" "$DIR/gfxcsb/"
install -m 644 "$HERE/tools/setvar.py" "$HERE/tools/wdt.py" "$HERE/tools/acpi-archive.py" \
	"$HERE/tools/system.sh" "$HERE/acpi/SSDT-S3.aml" "$DIR/"
[ -e /dev/watchdog ] || echo "note: no /dev/watchdog (driver sp5100_tco): S3 runs without the watchdog on the way back"
install -m 755 "$HERE/tools/nvme-param.sh" "$HERE/tools/gfxcsb-offset.sh" "$DIR/"
install -m 755 "$HERE/bc250-sleep" "$DIR/bc250-sleep.new"
mv -f "$DIR/bc250-sleep.new" "$DIR/bc250-sleep"
install -m 755 "$HERE/bc250-poweroff" "$HERE/bc250-update" "$DIR/"
sys_label "$DIR/bc250-sleep" "$DIR/bc250-poweroff" "$DIR/bc250-update" "$DIR/"*.sh
install -m 644 "$HERE/systemd/systemd-poweroff.conf" "$HERE/VERSION" "$DIR/"
[ -e "$DIR/config" ] || install -m 644 "$HERE/config.example" "$DIR/config"
# The sleep and the power-off are the user's choice once made; a first install takes S3 and the power-off
# the gamepad undoes. First means the boot check is not in place yet, so an install that failed half way
# counts as first again.
FIRST=""
[ -e "$UNIT" ] || FIRST=1
[ -e "$DIR/mode" ] || echo s3 > "$DIR/mode"

# The compiler and the kernel's build files, when they are missing: pacman (SteamOS has neither), or a
# container with the compiler (Bazzite has the build files in its image). bc250-update installs them again
# after a SteamOS update and builds the modules for the new kernel.
"$DIR/bc250-update" tools || exit 1
unload
"$DIR/bc250-update" build --force || exit 1

# The sleep "fast" of versions before 1.2: its boot entry, resume.efi and the kernel parameters that kept the
# firmware's memory free (about 110 MB) go.
entry=$(efibootmgr 2> /dev/null | sed -n 's/^Boot\([0-9A-Fa-f]\{4\}\)\*\{0,1\} bc250 resume.*/\1/p' | head -1 || true)
[ -z "$entry" ] || efibootmgr --bootnum "$entry" --delete-bootnum > /dev/null 2>&1 || true
for esp in /esp /efi /boot/efi /boot; do
	rm -f "$esp/EFI/bc250/resume.efi" "$esp/EFI/bc250/resume.log" 2> /dev/null
done
if sys_karg_configured s3-memmap "memmap=512K!0x100000"; then
	sys_karg remove s3-memmap "memmap=512K!0x100000 memmap=256K!0x1000000 memmap=94868K!0x78000000 memmap=14080K!0x7e240000" &&
		echo "the memmap kernel parameters of the sleep fast are gone from the next boot"
fi

# Without the table only the hibernation works; the status says why.
"$DIR/bc250-update" acpi add || echo "note: the S3 table is not in the boot: S3 stays off until it is"
# With the 8-core unlock S3 needs one polled disk queue (nvme-param.sh); it counts from the next boot.
if [ "$(nproc --all)" = 16 ] && ! grep -qw 'nvme.poll_queues=1' /proc/cmdline &&
	! sys_karg_configured s3-nvme nvme.poll_queues=1; then
	"$DIR/nvme-param.sh" add ||
		echo "note: kernel parameter nvme.poll_queues=1 not set: S3 stays off until it is ($DIR/nvme-param.sh add)"
fi

install -m 644 "$HERE/systemd/bc250-sleep-boot.service" "$UNIT"
install -m 644 "$HERE/systemd/bc250-sleep-update.service" "$UPDATE_UNIT"
install -D -m 644 "$HERE/systemd/systemd-suspend.conf" "$DROPIN"
if [ -e "$OLD_WAKE_DROPIN" ]; then
	rm -f "$OLD_WAKE_DROPIN"
	rmmod bc250_wake 2> /dev/null || true
	install -D -m 644 "$HERE/systemd/systemd-poweroff.conf" "$POWEROFF_DROPIN"
	echo "the power-off of bc250-wake is now this package's (bc250-sleep shutdown wake); /etc/bc250-wake can go"
fi
[ ! -e "$POWEROFF_DROPIN" ] && [ -z "$FIRST" ] || install -D -m 644 "$HERE/systemd/systemd-poweroff.conf" "$POWEROFF_DROPIN"
systemctl daemon-reload
systemctl enable bc250-sleep-boot.service bc250-sleep-update.service > /dev/null 2>&1
# A SteamOS update keeps only the files of /etc that some list names (one path or pattern per line); its own
# list (/usr/lib/rauc/atomic-update-keep.conf) has the systemd units, their links and drop-ins already.
if [ "$SYS" = steamos ]; then
	install -d -m 755 "$(dirname "$KEEP")"
	printf '%s\n' "$DIR/**" '/etc/default/grub.d/bc250-*.cfg' > "$KEEP"
fi
# The check for this boot, so that the answer is known now.
"$DIR/bc250-sleep" boot
"$DIR/bc250-sleep" status
# Left to the user: whoever masked them had a reason before this package was there.
for t in sleep.target suspend.target; do
	[ "$(systemctl is-enabled "$t" 2> /dev/null)" != masked ] ||
		echo "note: $t is masked, so Steam's Sleep does not reach bc250-sleep: sudo systemctl unmask $t"
done
echo "installed: Steam's Sleep takes the sleep named in the first line above; log: $VAR/sleep.log"
