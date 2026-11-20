#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-2.0-only
"""Read or change single bytes of the BIOS setup variable AmdSetup from the running system.

The variable holds the AMD CBS options; the firmware reads it at the next boot. Every change is printed
with the old value, so it can be put back.

usage (root to write): setvar.py                       show the bytes this test cares about
                       setvar.py 0x268=0 0x26e=0       write, then read back
"""
import os
import subprocess
import sys

PATH = '/sys/firmware/efi/efivars/AmdSetup-3a997502-647a-4c82-998e-52ef9486a247'
NAMES = {
    0x268: 'XHCI0 controller enable (1 on, 0 off, 0xf auto)',
    0x26e: 'XHCI1 controller enable (1 on, 0 off, 0xf auto)',
    0x6f6: 'CPU DC BTC (1 on, 0 off, 0xf auto)',
    0x6f7: 'CPU DC BTC voltage, mV, low byte',
    0x6f8: 'CPU DC BTC voltage, mV, high byte',
    0x275: 'SOC USB S3 WakeUp',
    0x276: 'USB PHY ref_clk stop in S3/S4/S5',
}

raw = open(PATH, 'rb').read()
attrs, data = raw[:4], bytearray(raw[4:])
changes = []
for arg in sys.argv[1:]:
    off, _, val = arg.partition('=')
    changes.append((int(off, 0), int(val, 0)))

if not changes:
    print('setvar: attributes 0x%x, size 0x%x' % (int.from_bytes(attrs, 'little'), len(data)))
    for off, name in NAMES.items():
        print('setvar: 0x%03x = 0x%02x  %s' % (off, data[off], name))
    sys.exit(0)

for off, val in changes:
    if not 0 <= off < len(data) or not 0 <= val <= 0xff:
        sys.exit('setvar: bad change 0x%x=0x%x' % (off, val))
    print('setvar: 0x%03x: 0x%02x -> 0x%02x  %s' % (off, data[off], val, NAMES.get(off, '')))
    data[off] = val

# The kernel marks firmware variables immutable; one write call must carry the whole variable.
subprocess.run(['chattr', '-i', PATH], check=False)
fd = os.open(PATH, os.O_WRONLY)
try:
    os.write(fd, bytes(attrs) + bytes(data))
finally:
    os.close(fd)
after = open(PATH, 'rb').read()[4:]
ok = all(after[off] == val for off, val in changes) and len(after) == len(data)
print('setvar: written and read back: %s' % ('ok' if ok else 'MISMATCH'))
sys.exit(0 if ok else 1)
