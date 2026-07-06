#!/usr/bin/env bash
set -euo pipefail
# Full MediaTek partition readback via mtkclient BROM mode.
# Reads every partition except userdata into ~/mp01-backups/<label>/ and checksums it.
# Usage: scripts/backup-device.sh <label>   e.g. stock-2026-07-06
#
# Before running: power the phone OFF, then hold both volume buttons while
# plugging in USB to enter BROM/preloader mode (screen stays black). mtkclient
# will wait for the device to appear.
label="${1:?usage: backup-device.sh <label>}"
mtk="${MTK_BIN:-$HOME/.venvs/mtk/bin/mtk}"
out="$HOME/mp01-backups/$label"
mkdir -p "$out"
echo "Reading all partitions (except userdata) to: $out"
"$mtk" rl "$out" --skip userdata
( cd "$out" && shasum -a 256 ./*.bin > MANIFEST.sha256 )
echo "Backup complete: $out"
echo "Partitions captured:"; ls -1 "$out"
