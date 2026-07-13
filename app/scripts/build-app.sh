#!/bin/sh
set -eu

root=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
cd "$root"

swift build -c release
bin_dir=$(swift build -c release --show-bin-path)
app="$root/dist/BrrrnBar.app"

rm -rf "$app"
mkdir -p "$app/Contents/MacOS"
cp "$bin_dir/BrrrnBar" "$app/Contents/MacOS/BrrrnBar"
cp "$root/Resources/Info.plist" "$app/Contents/Info.plist"
chmod +x "$app/Contents/MacOS/BrrrnBar"

printf 'built %s\n' "$app"
