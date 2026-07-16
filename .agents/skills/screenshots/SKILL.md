---
name: screenshots
description: Regenerate the README screenshot gallery from code, or render the operator's real data for sharing.
---

# Screenshots

The gallery is rendered by the app itself with seeded demo data, so images
never drift from the code and never leak real usage. Regenerate after any
visible UI change; CI does not do this for you.

## README gallery (demo data, committed)

```sh
cd app
swift build
.build/debug/BrrrnBar --screenshots ../docs/screenshots
```

Review the PNGs (they are the product's face), then commit them with the UI
change. Fixture data lives in `app/Sources/BrrrnBar/Screenshots.swift`.

## Your own data (for social posts, never committed)

```sh
cd app
BRRRN_BIN=$PWD/../target/release/brrrn .build/debug/BrrrnBar --screenshots-real ~/Desktop/brrrn-shots
```

Contains real costs, model mix, and pit members. Do not put these under
`docs/`.

## Gotchas

- `ImageRenderer` cannot lay out `ScrollView` content or AppKit-backed
  controls (TextField, native Picker, Menu). Views take a `snapshotMode`
  flag that swaps those for static equivalents; pure-SwiftUI controls
  (`TabStrip`, `RangePicker`) render fine.
- The rhythm shot varies with the current hour (the readout is anchored to
  "now"); a diff on that PNG alone is expected noise.
- Verifying equal tab heights: render, then compare `sips -g pixelHeight`
  across the `menu-*.png` files.
