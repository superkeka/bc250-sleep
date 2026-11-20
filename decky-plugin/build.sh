#!/bin/bash
# SPDX-License-Identifier: GPL-2.0-only
# Builds the Decky plugin into out/bc250-sleep: the panel, the backend and the bc250-sleep package it
# installs (everything of the repository but this folder). Zip out/bc250-sleep for Decky's installer.
set -euo pipefail
cd "$(dirname "$0")"
pnpm install --frozen-lockfile > /dev/null
pnpm build > /dev/null
OUT=out/bc250-sleep
[ ! -d "$OUT" ] || rm -r "$OUT"
mkdir -p "$OUT/package"
cp -R dist main.py plugin.json package.json "$OUT/"
cp ../LICENSE "$OUT/"
(cd .. && tar cf - --exclude=./decky-plugin --exclude=./.github --exclude=.git --exclude='*.ko' --exclude='*.o' --exclude=__pycache__ --exclude='*.png' .) |
	tar xf - -C "$OUT/package"
echo "$OUT"
