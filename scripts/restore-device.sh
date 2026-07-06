#!/usr/bin/env bash
set -euo pipefail
# Restore stock (or any backup set) to the MP01 via mtkclient BROM mode.
#
# Usage:
#   scripts/restore-device.sh <source-dir>                  # full restore (all partitions in dir)
#   scripts/restore-device.sh <source-dir> boot_a vbmeta_a  # restore only the named partitions
#
# Before running: power the phone OFF, then hold both volume buttons while
# plugging in USB to enter BROM mode (screen stays black).
#
# NOTE: a FULL restore writes back seccfg, which returns the bootloader to the
# lock state captured in the backup (this device was LOCKED at backup time).
# Always restore the whole consistent set together so verified boot stays
# satisfied; do not re-lock over a modified system.
src="${1:?usage: restore-device.sh <source-dir> [partition ...]}"
shift || true
mtk="${MTK_BIN:-$HOME/.venvs/mtk/bin/mtk}"
[ -d "$src" ] || { echo "no such dir: $src" >&2; exit 1; }

echo "Verifying source checksums..."
( cd "$src" && shasum -a 256 -c MANIFEST.sha256 )

echo "Put the MP01 into BROM mode now (power off, hold both volume keys, plug in USB)."
if [ "$#" -eq 0 ]; then
    # Full restore: write every partition present in the source (userdata absent by design).
    "$mtk" wl "$src" --skip userdata
else
    # Targeted restore: write only the named partitions.
    for p in "$@"; do
        [ -f "$src/$p.bin" ] || { echo "missing: $src/$p.bin" >&2; exit 1; }
        echo "Writing $p ..."
        "$mtk" w "$p" "$src/$p.bin"
    done
fi
echo "Restore complete. Reboot the device (hold power ~10s if it stays black)."
