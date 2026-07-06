#!/bin/bash

: "${MP01_RELEASE_REPO:=itxjobe/MP01-LineageGSI}"
: "${MP01_SUPPORT_REPO:=https://github.com/itxjobe/MP01-LineageGSI.git}"
: "${MP01_SUPPORT_BRANCH:=15}"
# Manifest still sourced from the upstream fork until we mirror it under itxjobe.
: "${MP01_MANIFEST_REPO:=https://github.com/MP01-LineageOS/treble_manifest.git}"
: "${MP01_MANIFEST_BRANCH:=15-los-qpr2}"
: "${MP01_OTA_JSON_URL:=https://raw.githubusercontent.com/itxjobe/MP01-LineageGSI/15/ota.json}"

: "${MP01_REPO_LAUNCHER_URL:=https://storage.googleapis.com/git-repo-downloads/repo}"
: "${MP01_REPO_LAUNCHER_SHA256:=11bc6893e9e0c0940fc1cc95b75c645f9a29fca879d89ceaa898a4d761a2add7}"

: "${MP01_FINQWERTY_VERSION:=76cef2d}"
: "${MP01_FINQWERTY_APK_NAME:=finqwerty-release.apk}"
: "${MP01_FINQWERTY_APK_URL:=https://github.com/MP01-LineageOS/finqwerty/releases/download/76cef2d/finqwerty-release.apk}"
: "${MP01_FINQWERTY_APK_SHA256:=d5fedb270671d13fa02177c53191bab6d76f99de133bac4c48efec65ed8d683e}"

: "${MP01_FDROID_VERSION:=F-Droid.apk 2026-02-19}"
: "${MP01_FDROID_APK_NAME:=F-Droid.apk}"
: "${MP01_FDROID_APK_URL:=https://f-droid.org/F-Droid.apk}"
: "${MP01_FDROID_APK_SHA256:=985f5181d48bb6bafd54083a048b391271e0ab28385881cc41294fb01a222762}"
: "${MP01_FDROID_CERT_SHA256:=43:23:8D:51:2C:1E:5E:B2:D6:56:9F:4A:3A:FB:F5:52:34:18:B8:2E:0A:3E:D1:55:27:70:AB:B9:A9:C9:CC:AB}"

: "${MP01_TREBLE_PRESETS_COMMIT:=09fdae135930b553c54aba7aa9a07b105132b6ff}"
: "${MP01_TREBLE_PRESETS_NAME:=infos.json}"
: "${MP01_TREBLE_PRESETS_URL:=https://raw.githubusercontent.com/MP01-LineageOS/treble_presets/${MP01_TREBLE_PRESETS_COMMIT}/infos.json}"
: "${MP01_TREBLE_PRESETS_SHA256:=1fef71972d881ea508b15715cd165d0fb7954652c5871e8c054c7cd6fd8ede31}"

: "${MP01_BASELINE_RELEASE_TAG:=1755162498}"
: "${MP01_BASELINE_RELEASE_TITLE:=2025-08-14 (LineageOS 22.2) [1755162498]}"
: "${MP01_BASELINE_TAR_NAME:=MP01-Lineage-1755162498-signed.tar.gz}"
: "${MP01_BASELINE_TAR_SIZE:=1204341111}"
: "${MP01_BASELINE_TAR_SHA256:=d6b3f74d30ca84a186b926027afa7340a15450c5fd05720919cde57e1a887b1f}"

mp01_require_tool() {
    local tool="${1:?tool name is required}"
    if ! command -v "$tool" >/dev/null 2>&1; then
        echo "ERROR: required tool not found: $tool" >&2
        exit 1
    fi
}

mp01_sha256_file() {
    local path="${1:?file path is required}"

    if command -v sha256sum >/dev/null 2>&1; then
        sha256sum "$path" | awk '{print $1}'
    elif command -v shasum >/dev/null 2>&1; then
        shasum -a 256 "$path" | awk '{print $1}'
    else
        echo "ERROR: sha256sum or shasum is required." >&2
        exit 1
    fi
}

mp01_normalize_fingerprint() {
    tr -d '[:space:]:' | tr '[:lower:]' '[:upper:]'
}

mp01_verify_sha256() {
    local path="${1:?file path is required}"
    local expected="${2:?expected SHA256 is required}"
    local label="${3:-$path}"
    local actual

    actual="$(mp01_sha256_file "$path")"
    if [[ "$actual" != "$expected" ]]; then
        echo "ERROR: $label SHA256 mismatch." >&2
        echo "Expected: $expected" >&2
        echo "Actual:   $actual" >&2
        exit 1
    fi
}

mp01_download_and_verify() {
    local url="${1:?download URL is required}"
    local output="${2:?output path is required}"
    local expected_sha256="${3:?expected SHA256 is required}"
    local label="${4:-$output}"
    local tmp_output

    mp01_require_tool curl
    mkdir -p "$(dirname "$output")"
    tmp_output="${output}.tmp.$$"
    rm -f "$tmp_output"

    curl -fsSL --retry 3 --retry-delay 2 -o "$tmp_output" "$url"
    mp01_verify_sha256 "$tmp_output" "$expected_sha256" "$label"
    mv "$tmp_output" "$output"
}

mp01_validate_apk() {
    local apk_path="${1:?APK path is required}"
    local label="${2:-$apk_path}"

    if command -v aapt >/dev/null 2>&1; then
        if ! aapt dump badging "$apk_path" >/dev/null 2>&1; then
            echo "ERROR: $label is not a valid APK according to aapt." >&2
            exit 1
        fi
        return
    fi

    mp01_require_tool unzip
    if ! unzip -tq "$apk_path" >/dev/null; then
        echo "ERROR: $label is not a valid ZIP/APK archive." >&2
        exit 1
    fi
}

mp01_extract_apk_cert_sha256() {
    local apk_path="${1:?APK path is required}"
    local cert_entry
    local tmp_dir
    local actual

    if command -v keytool >/dev/null 2>&1; then
        keytool -printcert -jarfile "$apk_path" 2>/dev/null \
            | awk -F': ' '/SHA256:/ {gsub(/ /,"",$2); print $2; exit}'
        return
    fi

    mp01_require_tool unzip
    mp01_require_tool openssl

    cert_entry="$(unzip -Z1 "$apk_path" 'META-INF/*' | grep -E '\.(RSA|DSA|EC)$' | head -n1 || true)"
    if [[ -z "$cert_entry" ]]; then
        echo "ERROR: no APK signing certificate block found in $apk_path." >&2
        exit 1
    fi

    tmp_dir="$(mktemp -d)"
    unzip -p "$apk_path" "$cert_entry" > "$tmp_dir/certblock"
    openssl pkcs7 -inform DER -in "$tmp_dir/certblock" -print_certs -out "$tmp_dir/certs.pem" 2>/dev/null
    actual="$(openssl x509 -in "$tmp_dir/certs.pem" -noout -fingerprint -sha256 | awk -F= '{print $2}')"
    rm -rf "$tmp_dir"
    printf '%s\n' "$actual"
}

mp01_verify_apk_cert_sha256() {
    local apk_path="${1:?APK path is required}"
    local expected="${2:?expected certificate SHA256 is required}"
    local label="${3:-$apk_path}"
    local actual
    local expected_normalized
    local actual_normalized

    expected_normalized="$(printf '%s' "$expected" | mp01_normalize_fingerprint)"
    actual="$(mp01_extract_apk_cert_sha256 "$apk_path")"
    actual_normalized="$(printf '%s' "$actual" | mp01_normalize_fingerprint)"

    if [[ "$actual_normalized" != "$expected_normalized" ]]; then
        echo "ERROR: $label signing certificate SHA256 mismatch." >&2
        echo "Expected: $expected" >&2
        echo "Actual:   $actual" >&2
        exit 1
    fi
}

mp01_download_finqwerty_apk() {
    local output="${1:?output APK path is required}"

    mp01_download_and_verify \
        "$MP01_FINQWERTY_APK_URL" \
        "$output" \
        "$MP01_FINQWERTY_APK_SHA256" \
        "FinQwerty ${MP01_FINQWERTY_VERSION}"
    mp01_validate_apk "$output" "FinQwerty ${MP01_FINQWERTY_VERSION}"
}

mp01_download_fdroid_apk() {
    local output="${1:?output APK path is required}"

    mp01_download_and_verify \
        "$MP01_FDROID_APK_URL" \
        "$output" \
        "$MP01_FDROID_APK_SHA256" \
        "F-Droid ${MP01_FDROID_VERSION}"
    mp01_validate_apk "$output" "F-Droid ${MP01_FDROID_VERSION}"
    mp01_verify_apk_cert_sha256 "$output" "$MP01_FDROID_CERT_SHA256" "F-Droid ${MP01_FDROID_VERSION}"
}

mp01_ensure_fdroid_apk() {
    local output="${1:?output APK path is required}"

    if [[ -f "$output" ]]; then
        mp01_verify_sha256 "$output" "$MP01_FDROID_APK_SHA256" "F-Droid ${MP01_FDROID_VERSION}"
        mp01_validate_apk "$output" "F-Droid ${MP01_FDROID_VERSION}"
        mp01_verify_apk_cert_sha256 "$output" "$MP01_FDROID_CERT_SHA256" "F-Droid ${MP01_FDROID_VERSION}"
        return
    fi

    mp01_download_fdroid_apk "$output"
}

mp01_download_treble_presets() {
    local output="${1:?output presets path is required}"

    mp01_download_and_verify \
        "$MP01_TREBLE_PRESETS_URL" \
        "$output" \
        "$MP01_TREBLE_PRESETS_SHA256" \
        "Treble presets ${MP01_TREBLE_PRESETS_COMMIT}"
}

mp01_ensure_repo_launcher() {
    local bin_dir="${1:?repo launcher bin directory is required}"
    local repo_path="$bin_dir/repo"

    mkdir -p "$bin_dir"
    if [[ ! -f "$repo_path" ]]; then
        mp01_download_and_verify \
            "$MP01_REPO_LAUNCHER_URL" \
            "$repo_path" \
            "$MP01_REPO_LAUNCHER_SHA256" \
            "repo launcher"
    else
        mp01_verify_sha256 "$repo_path" "$MP01_REPO_LAUNCHER_SHA256" "repo launcher"
    fi

    chmod 755 "$repo_path"
    export PATH="$bin_dir:$PATH"
}
