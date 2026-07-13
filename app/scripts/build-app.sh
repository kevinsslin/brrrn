#!/bin/sh
set -eu

app_root=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
repo_root=$(CDPATH= cd -- "$app_root/.." && pwd)

cargo build --manifest-path "$repo_root/Cargo.toml" --release
cd "$app_root"
swift build -c release

app="$app_root/dist/BrrrnBar.app"
rm -rf "$app"
mkdir -p "$app/Contents/MacOS"
cp "$app_root/.build/release/BrrrnBar" "$app/Contents/MacOS/BrrrnBar"
cp "$repo_root/target/release/brrrn" "$app/Contents/MacOS/brrrn"
cp "$app_root/Resources/Info.plist" "$app/Contents/Info.plist"
chmod +x "$app/Contents/MacOS/BrrrnBar" "$app/Contents/MacOS/brrrn"

printf 'built %s\n' "$app"
