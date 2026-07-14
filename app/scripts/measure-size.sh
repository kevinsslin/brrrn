#!/bin/sh
set -eu

app_root=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
app=${1:-"$app_root/dist/BrrrnBar.app"}
max_zip_bytes=${BRRRN_MAX_ZIP_BYTES:-2097152}

if [ ! -d "$app" ]; then
    printf 'app bundle not found: %s\n' "$app" >&2
    printf 'run ./scripts/build-app.sh first\n' >&2
    exit 1
fi

archive=$(mktemp /tmp/BrrrnBar-size.XXXXXX.zip)
trap 'rm -f "$archive"' EXIT

ditto -c -k --sequesterRsrc --keepParent "$app" "$archive"
app_kb=$(du -sk "$app" | cut -f1)
zip_bytes=$(stat -f '%z' "$archive")
rust_bytes=$(stat -f '%z' "$app/Contents/MacOS/brrrn")
swift_bytes=$(stat -f '%z' "$app/Contents/MacOS/BrrrnBar")

printf 'app_bundle_kb=%s\n' "$app_kb"
printf 'compressed_bytes=%s\n' "$zip_bytes"
printf 'rust_cli_bytes=%s\n' "$rust_bytes"
printf 'swift_ui_bytes=%s\n' "$swift_bytes"
printf 'compressed_budget_bytes=%s\n' "$max_zip_bytes"

if [ "$zip_bytes" -gt "$max_zip_bytes" ]; then
    printf 'compressed app exceeds the ultralight size budget\n' >&2
    exit 1
fi
