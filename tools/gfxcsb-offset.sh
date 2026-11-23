#!/bin/bash
# SPDX-License-Identifier: GPL-2.0-only
# Prints the offset, in amdgpu's device structure, of the flag "the gfx clear state has been submitted",
# read out of the driver's code for the running kernel; "none" when the driver has no such flag and submits
# the clear state on every start of the gfx block. Nothing is printed when the code does not look as
# expected.
#
# What is looked for, in gfx_v10_0_cp_gfx_start: a test of a byte of the device structure against 0 that
# leaves the function early, and near the end, after the wait for the gfx block to go idle, the same byte
# set to 1. Where the compiler has that wait inline there is no call to go by (CachyOS's deckify kernel,
# which carries the flag too): the flag is then the one byte the function both tests against 0 and later
# sets to 1.
#
#   gfxcsb-offset.sh                  the driver of the running kernel (the answer is kept for the boot)
#   gfxcsb-offset.sh amdgpu.ko[.zst]  that module file, to check a kernel without booting it
set -u
# shellcheck source=system.sh
. "$(dirname "$(readlink -f "$0")")/system.sh"
# Once per kernel: where the host has no objdump (an ostree system without a compiler) it runs in the build container.
CACHE=/run/bc250-sleep/gfxcsb-offset-$KVER
if [ -n "${1:-}" ]; then
	# A module file named by hand says nothing about the running kernel: its answer is not kept.
	F=$1
	CACHE=/dev/null
else
	[ -s "$CACHE" ] && { cat "$CACHE"; exit 0; }
	# The file of the module the running kernel loads (not some other copy under the modules directory).
	F=$(modinfo -k "$KVER" -n amdgpu 2> /dev/null)
	[ -n "$F" ] || F=$(find "/usr/lib/modules/$KVER" -name 'amdgpu.ko*' 2> /dev/null | head -1)
fi
[ -n "$F" ] && [ -f "$F" ] || exit 1
T=$(mktemp -d /tmp/gfxcsb.XXXXXX) || exit 1
trap 'rm -f "$T/amdgpu.ko" "$T/dis.txt"; rmdir "$T" 2> /dev/null' EXIT
case "$F" in
*.zst) sys_exec zstd -dcq "$F" > "$T/amdgpu.ko" ;;
*.xz) sys_exec xz -dc "$F" > "$T/amdgpu.ko" ;;
*.gz) sys_exec gzip -dc "$F" > "$T/amdgpu.ko" ;;
*) cp "$F" "$T/amdgpu.ko" ;;
esac
SYM=$(sys_exec objdump -t "$T/amdgpu.ko" 2> /dev/null | awk '$NF ~ /^gfx_v10_0_cp_gfx_start/ { print $NF; exit }')
[ -n "$SYM" ] || exit 1
sys_exec objdump -d --no-show-raw-insn --disassemble="$SYM" "$T/amdgpu.ko" > "$T/dis.txt" 2> /dev/null || exit 1
# A driver that reads no byte of its device structure here submits the clear state on every start (the
# upstream driver; the flag is SteamOS's): nothing to clear, "none".
if ! grep -qE '(cmpb|testb|movb|movzbl|movzbw|movsbl) .*\(%r' "$T/dis.txt"; then
	mkdir -p /run/bc250-sleep 2> /dev/null && echo none > "$CACHE" 2> /dev/null
	echo none
	exit 0
fi
# The byte set to 1 after the call that waits for idle.
SET=$(awk '/call .*wait_for_idle/ { seen = 1; next } seen && /movb +\$0x1,0x[0-9a-f]+\(%r/ { print; exit }' "$T/dis.txt" |
	sed -n 's/.*movb *\$0x1,\(0x[0-9a-f]*\)(%r.*/\1/p')
# No such call: the wait is inline (a delay and an indirect call in a loop). The flag is then the byte that
# is tested against 0 and, further down, set to 1. The stack is left out, and with no such byte or more than
# one, nothing is printed: a wrong place would be written to before every sleep.
if [ -z "$SET" ]; then
	SET=$(awk '
		/\(%r[sb]p\)/ { next }
		/cmpb +\$0x0,0x[0-9a-f]+\(%r/ {
			o = $0; sub(/.*cmpb +\$0x0,/, "", o); sub(/\(.*/, "", o)
			tested[o] = 1
		}
		/movb +\$0x1,0x[0-9a-f]+\(%r/ {
			o = $0; sub(/.*movb +\$0x1,/, "", o); sub(/\(.*/, "", o)
			if ((o in tested) && !(o in set)) { set[o] = 1; n++; found = o }
		}
		END { if (n == 1) print found }' "$T/dis.txt")
fi
[ -n "$SET" ] || exit 1
# The same byte tested against 0 earlier in the function.
grep -q "cmpb *\$0x0,$SET(%r" "$T/dis.txt" || exit 1
mkdir -p /run/bc250-sleep 2> /dev/null && echo "$SET" > "$CACHE" 2> /dev/null
echo "$SET"
