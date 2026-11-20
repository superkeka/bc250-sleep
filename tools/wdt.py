#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-2.0-only
"""Arm the southbridge watchdog and leave it running: with nobody feeding it, it resets the board.

A reset by the watchdog keeps standby power, so the BIOS setup survives it (a power cut puts the defaults back).

usage (root): wdt.py <seconds>
              wdt.py stop        stop a running watchdog, whoever started it
"""
import fcntl
import os
import struct
import sys

WDIOC_SETTIMEOUT = 0xC0045706

if len(sys.argv) != 2 or not (sys.argv[1] == 'stop' or sys.argv[1].isdigit()):
    sys.exit(__doc__.strip())
fd = os.open('/dev/watchdog', os.O_WRONLY)
if sys.argv[1] == 'stop':
    # Opening starts the driver's own count; its closing byte then stops the timer for good.
    os.write(fd, b'V')
    os.close(fd)
    print('wdt: stopped')
    sys.exit(0)
seconds = int(sys.argv[1])
got = struct.unpack('i', fcntl.ioctl(fd, WDIOC_SETTIMEOUT, struct.pack('i', seconds)))[0]
os.write(fd, b'\0')
print('wdt: armed, the board resets in %d s' % got)
sys.stdout.flush()
# Leaving without the driver's closing byte keeps the watchdog counting after this process ends.
os._exit(0)
