#!/usr/bin/env bash
set -euo pipefail
# Generate the release signing key set that sign.sh expects: the standard AOSP
# keys plus one apk key (.pk8/.x509.pem) and one apex payload key (.pem) for
# every APEX referenced in sign.sh. Keys are unencrypted and live in
# ~/.android-certs; they are NEVER committed.
#
# Usage: scripts/gen-keys.sh [path-to-sign.sh]
certs="${ANDROID_CERTS_DIR:-$HOME/.android-certs}"
signsh="${1:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/sign.sh}"
subj='/C=US/ST=CA/L=NA/O=MP01/OU=MP01/CN=MP01/emailAddress=mp01@mp01.invalid'
[ -f "$signsh" ] || { echo "sign.sh not found: $signsh" >&2; exit 1; }
mkdir -p "$certs"; cd "$certs"

gen_apk_key() {  # $1 = base name -> $1.pk8 + $1.x509.pem (exponent 3, 2048-bit)
    local n="$1"
    [ -f "$n.pk8" ] && [ -f "$n.x509.pem" ] && return 0
    openssl genrsa -3 -out "$n._priv" 2048 >/dev/null 2>&1
    openssl req -new -x509 -key "$n._priv" -out "$n.x509.pem" -days 10000 -subj "$subj" >/dev/null 2>&1
    openssl pkcs8 -topk8 -outform DER -in "$n._priv" -inform PEM -out "$n.pk8" -nocrypt >/dev/null 2>&1
    rm -f "$n._priv"
}

echo "### standard keys ###"
for k in releasekey platform shared media networkstack sdk_sandbox bluetooth nfc; do
    gen_apk_key "$k"; echo "  $k"
done

echo "### APEX keys (parsed from sign.sh) ###"
apexes="$(grep -oE 'android-certs/[A-Za-z0-9._]+\.pem' "$signsh" | sed 's#.*android-certs/##; s#\.pem$##' | sort -u)"
for a in $apexes; do
    gen_apk_key "$a"                                                    # apk signing key
    [ -f "$a.pem" ] || openssl genrsa -f4 -out "$a.pem" 4096 >/dev/null 2>&1   # apex payload key (4096/F4)
    echo "  $a"
done

echo "### done: $(ls "$certs" | wc -l | tr -d ' ') files in $certs ###"
