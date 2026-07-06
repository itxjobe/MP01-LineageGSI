#!/usr/bin/env bash
set -euo pipefail
# Generate a static, e-ink-friendly boot animation for the MP01 (600x800,
# black text on white, zero motion = no ghosting). Output is a STORED
# (uncompressed) bootanimation.zip, which the bootanimation service requires.
#
# Usage: scripts/make-eink-bootanim.sh [output-dir]
# Env: MP01_BOOT_TITLE, MP01_BOOT_SUBTITLE, MP01_BOOT_W, MP01_BOOT_H
title="${MP01_BOOT_TITLE:-Minimal Phone}"
subtitle="${MP01_BOOT_SUBTITLE:-LineageOS microG}"
w="${MP01_BOOT_W:-600}"
h="${MP01_BOOT_H:-800}"
outdir="${1:-.}"

command -v convert >/dev/null 2>&1 || { echo "ERROR: ImageMagick 'convert' not found" >&2; exit 1; }
command -v zip     >/dev/null 2>&1 || { echo "ERROR: 'zip' not found" >&2; exit 1; }

tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT
mkdir -p "$tmp/part0"

font="$(fc-match -f '%{file}' 'DejaVu Sans' 2>/dev/null || true)"
[ -n "$font" ] || font="$(find /usr/share/fonts -name '*.ttf' 2>/dev/null | head -1 || true)"

convert -size "${w}x${h}" xc:white -gravity center \
    ${font:+-font "$font"} \
    -pointsize 46 -fill black     -annotate +0-24 "$title" \
    -pointsize 22 -fill '#333333'  -annotate +0+30 "$subtitle" \
    "$tmp/part0/000.png"

# desc.txt: WIDTH HEIGHT FPS, then one part looped forever (p 0) until boot done.
printf '%s %s 2\np 0 0 part0\n' "$w" "$h" > "$tmp/desc.txt"

( cd "$tmp" && zip -0 -q -r bootanimation.zip desc.txt part0 )
mkdir -p "$outdir"
mv -f "$tmp/bootanimation.zip" "$outdir/bootanimation.zip"
echo "wrote $outdir/bootanimation.zip"
