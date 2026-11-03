#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
output="${DIST_DIR:-dist}"
version=$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' Support/Info.plist)
build=$(/usr/libexec/PlistBuddy -c 'Print :CFBundleVersion' Support/Info.plist)
[[ "$version" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ && "$build" == "$version" ]] || { echo 'Expected matching stable SemVer bundle versions' >&2; exit 1; }
[[ -n "${SPARKLE_PUBLIC_ED_KEY:-}" ]] || { echo 'Set SPARKLE_PUBLIC_ED_KEY before packaging a distributable update' >&2; exit 1; }
CONFIGURATION=release sh build.sh
"$output/harnessmd.app/Contents/MacOS/HarnessApp" --validate-update-configuration
"$output/harnessmd.app/Contents/MacOS/HarnessApp" --self-test
arch=$(uname -m)
[[ "$arch" == arm64 || "$arch" == x86_64 ]]
name="harnessmd-$version-macos-$arch"
ditto -c -k --keepParent "$output/harnessmd.app" "$output/$name.zip"
stage=$(mktemp -d "${TMPDIR:-/tmp}/harnessmd-dmg.XXXXXX")
ditto "$output/harnessmd.app" "$stage/harnessmd.app"
ln -s /Applications "$stage/Applications"
hdiutil create -quiet -volname harnessmd -srcfolder "$stage" -fs HFS+ -format UDZO -ov "$output/$name.dmg"
hdiutil verify -quiet "$output/$name.dmg"
printf 'Built %s/%s.zip and .dmg (ad-hoc signed, not notarized)\n' "$output" "$name"
