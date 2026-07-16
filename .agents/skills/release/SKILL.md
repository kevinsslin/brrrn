---
name: release
description: Cut and publish a brrrn release end to end, with version sync, changelog, CI gate, and checksummed artifact.
---

# Release

1. **Version sync** (all three must match):
   - `Cargo.toml` `version`
   - `app/Resources/Info.plist` `CFBundleShortVersionString`
   - the new `CHANGELOG.md` heading
2. **CHANGELOG.md**: Keep-a-Changelog format, Added/Changed/Fixed sections,
   link reference at the bottom. Honest "Known limitations" beat marketing.
3. **Gate on CI**: push to `main`, wait for green
   (`gh run watch $(gh run list --branch main --limit 1 --json databaseId -q '.[0].databaseId') --exit-status`).
   Never tag a red commit.
4. **Artifact**:
   ```sh
   cd app && ./scripts/build-app.sh
   ditto -c -k --sequesterRsrc --keepParent dist/BrrrnBar.app /tmp/BrrrnBar.app.zip
   shasum -a 256 /tmp/BrrrnBar.app.zip   # goes verbatim into the release notes
   ```
5. **Tag and publish**:
   ```sh
   git tag -a vX.Y.Z -m "brrrn vX.Y.Z: <one line>"
   git push origin vX.Y.Z
   gh release create vX.Y.Z /tmp/BrrrnBar.app.zip --title "brrrn vX.Y.Z" --notes-file <notes>
   ```
6. **Release notes** carry: highlights, install steps with the unsigned-app
   caveat (right-click → Open), the SHA-256, the privacy list, and a
   migration note for existing users (usually "nothing to migrate").
