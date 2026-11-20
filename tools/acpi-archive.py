#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-2.0-only
"""Adds a table to, or takes it out of, the archive of ACPI tables the kernel reads early in a boot (a cpio
archive in the "newc" format with the tables under kernel/firmware/acpi/).

usage: acpi-archive.py list <archive>
       acpi-archive.py has <archive> <table.aml>                 (exit 0 when it holds that very table)
       acpi-archive.py add <archive> <table.aml> [<output>]     (a table of the same name is replaced)
       acpi-archive.py remove <archive> <name> [<output>]
Without <output> the archive is rewritten in place.
"""
import os
import sys

DIR = 'kernel/firmware/acpi'


def read(path):
    data = open(path, 'rb').read()
    entries, at = [], 0
    while True:
        if data[at:at + 6] != b'070701':
            sys.exit('%s: not a newc cpio archive at offset %d' % (path, at))
        fields = [int(data[at + 6 + 8 * i:at + 14 + 8 * i], 16) for i in range(13)]
        mode, size, namesize = fields[1], fields[6], fields[11]
        name = data[at + 110:at + 110 + namesize - 1].decode()
        at = (at + 110 + namesize + 3) & ~3
        if name == 'TRAILER!!!':
            return entries
        entries.append((name, mode, data[at:at + size]))
        at = (at + size + 3) & ~3


def write(path, entries):
    out = bytearray()
    for ino, (name, mode, body) in enumerate(entries + [('TRAILER!!!', 0, b'')], 1):
        raw = name.encode() + b'\0'
        fields = [ino if name != 'TRAILER!!!' else 0, mode, 0, 0, 2 if mode & 0o40000 else 1, 0, len(body),
                  0, 0, 0, 0, len(raw), 0]
        out += b'070701' + b''.join(b'%08X' % f for f in fields) + raw
        out += b'\0' * (-len(out) % 4) + body
        out += b'\0' * (-len(out) % 4)
    out += b'\0' * (-len(out) % 512)
    tmp = path + '.new'
    with open(tmp, 'wb') as f:
        f.write(out)
        f.flush()
        os.fsync(f.fileno())
    os.replace(tmp, path)


def main():
    if len(sys.argv) < 3 or sys.argv[1] not in ('list', 'has', 'add', 'remove'):
        sys.exit(__doc__.strip())
    cmd, archive = sys.argv[1], sys.argv[2]
    entries = read(archive) if os.path.exists(archive) else []
    if cmd == 'list':
        for name, mode, body in entries:
            print('%s%s' % (name, '/' if mode & 0o40000 else ' (%d bytes)' % len(body)))
        return
    if len(sys.argv) < 4:
        sys.exit(__doc__.strip())
    if cmd == 'has':
        name = '%s/%s' % (DIR, os.path.basename(sys.argv[3]))
        body = open(sys.argv[3], 'rb').read()
        sys.exit(0 if any(e[0] == name and e[2] == body for e in entries) else 1)
    output = sys.argv[4] if len(sys.argv) > 4 else archive
    table = os.path.basename(sys.argv[3])
    entries = [e for e in entries if e[0] != '%s/%s' % (DIR, table)]
    if cmd == 'add':
        names = {e[0] for e in entries}
        for d in ('kernel', 'kernel/firmware', DIR):
            if d not in names:
                entries.append((d, 0o40755, b''))
        entries.append(('%s/%s' % (DIR, table), 0o100644, open(sys.argv[3], 'rb').read()))
    write(output, entries)


main()
