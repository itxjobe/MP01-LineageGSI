#!/usr/bin/env bash
set -euo pipefail
# Sign the microG target-files package with ~/.android-certs and extract a
# signed system.img. Run after a successful `make target-files-package otatools`
# (i.e. after buildmicrog.sh has built the target-files zip).
#
# Env overrides: MP01_BUILD_ROOT, MP01_SUPPORT_DIR, MP01_IMAGE_DIR.
build_root="${MP01_BUILD_ROOT:-$HOME/mp01/.android-build/los22-microg}"
support="${MP01_SUPPORT_DIR:-$HOME/mp01/MP01-LineageGSI}"
img_dir="${MP01_IMAGE_DIR:-$support/images}"
lunch_target="${MP01_LUNCH_TARGET:-treble_arm64_bmN-bp1a-userdebug}"

[ -d "$build_root" ] || { echo "build root not found: $build_root" >&2; exit 1; }
[ -d "$HOME/.android-certs" ] || { echo "no ~/.android-certs (run scripts/gen-keys.sh first)" >&2; exit 1; }

cd "$build_root"
set +u
source build/envsetup.sh
lunch "$lunch_target"
set -u
[ -n "${OUT:-}" ] || { echo "ERROR: lunch did not set OUT" >&2; exit 1; }

ts="$(date +%s)"
signed_zip="$build_root/signed-target-files-${ts}.zip"
echo "=== signing target-files -> $signed_zip ==="
bash "$support/sign.sh" "$signed_zip"

mkdir -p "$img_dir"
img="$img_dir/MP01-Lineage-${ts}-microG-signed.img"
echo "=== extracting signed system.img ==="
unzip -o -j "$signed_zip" IMAGES/system.img -d "$img_dir" >/dev/null
mv -f "$img_dir/system.img" "$img"

echo "=== signed image ready ==="
ls -lh "$img"
( cd "$img_dir" && sha256sum "$(basename "$img")" > "$(basename "$img").sha256" && cat "$(basename "$img").sha256" )
