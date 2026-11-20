#!/bin/bash
# SPDX-License-Identifier: GPL-2.0-only
# Adds or removes one kernel parameter for the disk driver: nvme.poll_queues=1.
#
# After a sleep on a board with the 8-core unlock two cores do not come back. The disk driver then spreads
# its interrupts over the threads that are left, while the block layer keeps the thread-to-queue map of the
# boot, because the number of queues did not change. Some threads end up on queues whose interrupt is off, and every disk
# access from them waits for a timeout. With one polled queue the disk has more than one queue map, and the
# block layer rebuilds the maps on every reset of the controller.
#   sudo nvme-param.sh add       takes effect from the next boot
#   sudo nvme-param.sh remove
#   nvme-param.sh status
set -uo pipefail
# shellcheck disable=SC2034 # read by system.sh
LOG=/var/lib/bc250-sleep/update.log
# shellcheck source=system.sh
. "$(dirname "$(readlink -f "$0")")/system.sh"
ARGS=nvme.poll_queues=1

case "${1:-status}" in
add | remove)
	[ "$(id -u)" = 0 ] || { echo "run with sudo"; exit 1; }
	sys_karg "$1" s3-nvme "$ARGS" || exit 1
	if [ "$1" = add ]; then echo "added: $ARGS from the next boot"; else echo "removed: back to the usual parameters from the next boot"; fi
	;;
status)
	if sys_karg_configured s3-nvme "$ARGS"; then echo "configured for the next boot: yes"; else echo "configured for the next boot: no"; fi
	echo "this boot: poll_queues=$(cat /sys/module/nvme/parameters/poll_queues 2> /dev/null), $(grep -o 'nvme[^ ]*' /proc/cmdline | tr '\n' ' ')"
	for h in /sys/block/nvme0n1/mq/*; do printf '%s=%s ' "${h##*/}" "$(tr -d ' ' < "$h/cpu_list")"; done
	echo
	;;
*)
	echo "usage: $0 add | remove | status"
	exit 1
	;;
esac
