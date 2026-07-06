#!/bin/bash
set -euo pipefail

script_dir="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
workspace_dir="$(cd "$script_dir/.." && pwd)"
workspace_build_dir="${MP01_WORKSPACE_BUILD_DIR:-$workspace_dir/.android-build}"
build_root="${MP01_BUILD_ROOT:-$workspace_build_dir/los22-microg}"
image_dir="${MP01_IMAGE_DIR:-$workspace_dir/images}"
build_tmp_dir="${MP01_BUILD_TMPDIR:-$workspace_build_dir/tmp}"
export CCACHE_DIR="${CCACHE_DIR:-${MP01_CCACHE_DIR:-$workspace_build_dir/ccache}}"
export CCACHE_EXEC="${CCACHE_EXEC:-$(command -v ccache || true)}"
export SOONG_FINDER_THREADS="${SOONG_FINDER_THREADS:-1}"
export BLUEPRINT_PARSE_THREADS="${BLUEPRINT_PARSE_THREADS:-1}"
manifest_repo_override="${MP01_MANIFEST_REPO+x}"
support_repo_override="${MP01_SUPPORT_REPO+x}"
source "$script_dir/scripts/release-inputs.sh"
manifest_repo="$MP01_MANIFEST_REPO"
manifest_branch="$MP01_MANIFEST_BRANCH"
support_repo="$MP01_SUPPORT_REPO"
support_branch="$MP01_SUPPORT_BRANCH"
min_free_gb="${MP01_MIN_FREE_GB:-400}"
repo_sync_jobs="${MP01_REPO_SYNC_JOBS:-8}"
make_jobs="${MP01_MAKE_JOBS:-1}"
skip_repo_sync="${MP01_SKIP_REPO_SYNC:-0}"
skip_source_prep="${MP01_SKIP_SOURCE_PREP:-0}"
required_nofile="${MP01_BUILD_NOFILE:-262144}"
export CODEX_WORKSPACE_DIR="${CODEX_WORKSPACE_DIR:-$workspace_dir}"
export CODEX_ALLOW_NON_WORKSPACE_LARGE_STATE="${MP01_ALLOW_NON_WORKSPACE_BUILD:-${CODEX_ALLOW_NON_WORKSPACE_LARGE_STATE:-0}}"

workspace_paths_helper="${CODEX_HOME:-$HOME/.codex}/lib/codex_container/workspace_paths.sh"
if [[ -f "$workspace_paths_helper" ]]; then
    source "$workspace_paths_helper"
else
    # No Codex container: fall back to portable helpers so the build runs on a
    # plain Linux host (e.g. the ROG).
    source "$script_dir/scripts/portable-workspace.sh"
    export MP01_ALLOW_NON_WORKSPACE_BUILD="${MP01_ALLOW_NON_WORKSPACE_BUILD:-1}"
fi

if [[ -z "$manifest_repo_override" && -d "$script_dir/../treble_manifest/.git" ]]; then
    manifest_repo="$(cd "$script_dir/../treble_manifest" && pwd)"
fi

if [[ -z "$support_repo_override" ]]; then
    support_repo="$script_dir"
    support_branch=""
fi

codex_require_large_state_path "$workspace_build_dir" "workspace build directory"
codex_require_large_state_path "$build_root" "Android build root"
codex_require_large_state_path "$CCACHE_DIR" "ccache directory"
codex_require_large_state_path "$image_dir" "image output directory"
codex_require_large_state_path "$build_tmp_dir" "Android temporary directory"

mkdir -p "$workspace_build_dir" "$build_root" "$image_dir" "$build_tmp_dir"

# The Codex container intentionally mounts /tmp noexec. Android's Go bootstrap
# executes generated helpers from its temp directory, so keep temp state on the
# workspace build volume.
export TMPDIR="$build_tmp_dir"
export TMP="$build_tmp_dir"
export TEMP="$build_tmp_dir"
export GOTMPDIR="${GOTMPDIR:-$build_tmp_dir/go}"
mkdir -p "$GOTMPDIR"

current_nofile="$(ulimit -Sn)"
if [[ "$current_nofile" != "unlimited" && "$current_nofile" -lt "$required_nofile" ]]; then
    if ! ulimit -Sn "$required_nofile"; then
        echo "ERROR: Unable to raise open-file limit to $required_nofile for Android build." >&2
        echo "Current soft limit: $current_nofile; hard limit: $(ulimit -Hn)" >&2
        exit 1
    fi
fi
echo "Android build open-file soft limit: $(ulimit -Sn)"
echo "Android build Soong finder threads: $SOONG_FINDER_THREADS"
echo "Android build Blueprint parse threads: $BLUEPRINT_PARSE_THREADS"
echo "Android build make jobs: $make_jobs"

if [[ -n "${CCACHE_EXEC}" ]]; then
    export USE_CCACHE=1
    mkdir -p "$CCACHE_DIR"
    ccache -M 200G
fi

codex_check_free_space_gib "$workspace_build_dir" "$min_free_gb"

case "$skip_repo_sync" in
    0|1) ;;
    *)
        echo "ERROR: MP01_SKIP_REPO_SYNC must be 0 or 1." >&2
        exit 1
        ;;
esac

case "$skip_source_prep" in
    0|1) ;;
    *)
        echo "ERROR: MP01_SKIP_SOURCE_PREP must be 0 or 1." >&2
        exit 1
        ;;
esac

if ! [[ "$make_jobs" =~ ^[1-9][0-9]*$ ]]; then
    echo "ERROR: MP01_MAKE_JOBS must be a positive integer." >&2
    exit 1
fi

case_check_dir="$workspace_build_dir/.mp01-case-check"
rm -rf "$case_check_dir"
mkdir -p "$case_check_dir"
: > "$case_check_dir/casecheck"
if [[ -e "$case_check_dir/CASECHECK" ]]; then
    rm -rf "$case_check_dir"
    echo "ERROR: Android source builds require a case-sensitive filesystem." >&2
    echo "Path is case-insensitive: $workspace_build_dir" >&2
    echo "Mount a case-sensitive volume under the MP01 workspace and set MP01_WORKSPACE_BUILD_DIR to that path." >&2
    exit 1
fi
: > "$case_check_dir/CASECHECK"
rm -rf "$case_check_dir"

mp01_ensure_repo_launcher "$build_root/.bin"
cd "$build_root"

# Android checkouts create nested git repos after the container launcher has
# already built its safe.directory list.
android_build_safe_directory="$build_root/*"
if ! git config --global --get-all safe.directory | grep -Fx -- "$android_build_safe_directory" >/dev/null; then
    git config --global --add safe.directory "$android_build_safe_directory"
fi
git_config_index="${GIT_CONFIG_COUNT:-0}"
export "GIT_CONFIG_KEY_${git_config_index}=safe.directory"
# repo creates transient nested git directories such as .repo/repo.tmp before
# project paths exist, so the child process needs Git's full opt-out form.
export "GIT_CONFIG_VALUE_${git_config_index}=*"
export GIT_CONFIG_COUNT=$((git_config_index + 1))

# repo 2.54 enables TRACE_FILE by default; parallel sync workers can trip over
# the shared trace file on the mounted workspace volume.
export REPO_TRACE="${REPO_TRACE:-0}"

# TrebleDroid patches are applied with git-am inside freshly synced Android
# projects, where the container does not have a user identity configured.
export GIT_COMMITTER_NAME="${GIT_COMMITTER_NAME:-MP01 Build Automation}"
export GIT_COMMITTER_EMAIL="${GIT_COMMITTER_EMAIL:-mp01-build@example.invalid}"

if [[ "$skip_source_prep" == "1" ]]; then
    echo "Skipping Android source preparation because MP01_SKIP_SOURCE_PREP=1; reusing prepared checkout."
    required_prepared_paths=(
        build/envsetup.sh
        device/phh/treble/AndroidProducts.mk
        vendor/partner_gms/vendorsetup.sh
        vendor/finqwerty/"$MP01_FINQWERTY_APK_NAME"
    )
    for prepared_path in "${required_prepared_paths[@]}"; do
        if [[ ! -e "$prepared_path" ]]; then
            echo "ERROR: Prepared Android checkout is missing: $prepared_path" >&2
            exit 1
        fi
    done
else
repo init -u https://github.com/LineageOS/android.git -b lineage-22.2 --git-lfs -g default,microg

rm -rf .repo/local_manifests
mkdir -p .repo/local_manifests
git clone --depth 1 --branch "$manifest_branch" "$manifest_repo" .repo/local_manifests

cat > .repo/local_manifests/zz_mp01_microg.xml <<'EOF'
<?xml version="1.0" encoding="UTF-8"?>
<manifest>
    <remove-project name="MisterZtr/vendor_gapps" />
    <remove-project name="privileged-extension.git" />
</manifest>
EOF

# This build root is intentionally variant-specific and can be force-synced.
repo_sync_args=(
    --force-sync
    --optimized-fetch
    --no-tags
    --no-clone-bundle
    --prune
    --force-checkout
    --force-remove-dirty
)
if [[ "$skip_repo_sync" == "1" ]]; then
    echo "Skipping network repo sync because MP01_SKIP_REPO_SYNC=1; resetting worktree from local repo cache."
    repo sync -l -d --force-sync --force-checkout --force-remove-dirty --no-manifest-update -j"$repo_sync_jobs" --fail-fast
elif ! repo sync "${repo_sync_args[@]}" -j"$repo_sync_jobs"; then
    echo "repo sync failed with -j$repo_sync_jobs; retrying serially with --fail-fast." >&2
    repo sync "${repo_sync_args[@]}" -j1 --fail-fast
fi

if [[ -d vendor/gapps ]]; then
    echo "ERROR: vendor/gapps is present in the microG build graph." >&2
    exit 1
fi

if [[ -d vendor/F-DroidPrivilegedExtension ]]; then
    echo "ERROR: standalone F-DroidPrivilegedExtension is present in the microG build graph." >&2
    exit 1
fi

if [[ ! -d vendor/partner_gms ]]; then
    echo "ERROR: vendor/partner_gms was not synced. Check manifest groups." >&2
    exit 1
fi

rm -rf MP01Support
if [[ -n "$support_branch" ]]; then
    git clone --depth 1 --branch "$support_branch" "$support_repo" MP01Support
else
    git clone "$support_repo" MP01Support
fi

# Apply TrebleDroid and MP01 patches.
rm -rf patches
cp -R MP01Support/patches patches
bash patches/apply-patches.sh "$build_root"
rm -rf patches

# Generate TrebleDroid makefiles, then replace the MP01 targets explicitly.
cd device/phh/treble
bash generate.sh lineage
rm -f treble_arm64*
cp "$build_root"/MP01Support/treble_arm64* .
cp "$build_root"/MP01Support/AndroidProducts.mk .
cd "$build_root"

# Copy MP01 vendor additions into the Android tree.
mkdir -p vendor
cp -R MP01Support/vendor/. vendor/
rm -rf MP01Support

mp01_download_finqwerty_apk "vendor/finqwerty/$MP01_FINQWERTY_APK_NAME"
fi

mp01_ensure_fdroid_apk "vendor/F-Droid/$MP01_FDROID_APK_NAME"

bash vendor/partner_gms/vendorsetup.sh

expected_microg_apks=(
    vendor/partner_gms/GmsCore/GmsCore.apk
    vendor/partner_gms/FakeStore/FakeStore.apk
    vendor/partner_gms/GsfProxy/GsfProxy.apk
    vendor/partner_gms/FDroid/FDroid.apk
    vendor/partner_gms/FDroidPrivilegedExtension/FDroidPrivilegedExtension.apk
)

for apk in "${expected_microg_apks[@]}"; do
    if [[ ! -f "$apk" ]]; then
        echo "ERROR: Missing expected microG APK: $apk" >&2
        exit 1
    fi
done

set +u
source build/envsetup.sh
if ! lunch treble_arm64_bmN-bp1a-userdebug; then
    set -u
    echo "ERROR: lunch failed for treble_arm64_bmN-bp1a-userdebug" >&2
    exit 1
fi
set -u

if [[ -z "${OUT:-}" ]]; then
    echo "ERROR: lunch did not set OUT for treble_arm64_bmN-bp1a-userdebug" >&2
    exit 1
fi

make target-files-package otatools -j"$make_jobs"

build_date=$(date +%s)
image_filename="MP01-Lineage-${build_date}-microG-unsigned.img"
tar_filename="MP01-Lineage-${build_date}-microG-unsigned.tar.gz"
image_path="$image_dir/$image_filename"
tar_path="$image_dir/$tar_filename"

if [[ ! -f "$OUT/system.img" ]]; then
    echo "ERROR: System image file not found: $OUT/system.img" >&2
    exit 1
fi

mkdir -p "$image_dir"
cp "$OUT/system.img" "$image_path"
tar -czvf "$tar_path" -C "$image_dir" "$image_filename"

echo "Build completed successfully."
echo "Image file: $image_path"
echo "Archive file: $tar_path"
echo "Signing status: unsigned local test image"
