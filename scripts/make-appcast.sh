#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
output="${DIST_DIR:-dist}"
version=$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' Support/Info.plist)
zip="harnessmd-$version-macos-$(uname -m).zip"
tools=.build/artifacts/sparkle/Sparkle/bin
[[ -n "${SPARKLE_ED_PRIVATE_KEY:-}" ]] || { echo 'SPARKLE_ED_PRIVATE_KEY is required; never store it in the repository' >&2; exit 1; }
test -f "$output/$zip"
stage=$(mktemp -d "${TMPDIR:-/tmp}/harnessmd-appcast.XXXXXX")
cp "$output/$zip" "$stage/"
awk -v version="$version" '
    $0 == "## [" version "]" { found=1; next }
    found && /^## / { exit }
    found { print }
' CHANGELOG.md > "$stage/${zip%.zip}.md"
grep -q '[^[:space:]]' "$stage/${zip%.zip}.md" || { echo "Missing CHANGELOG.md notes for $version" >&2; exit 1; }
cp "$stage/${zip%.zip}.md" "$output/RELEASE_NOTES.md"
printf '%s' "$SPARKLE_ED_PRIVATE_KEY" | "$tools/generate_appcast" --ed-key-file - \
    --download-url-prefix "https://github.com/mrcat71/harnessmd/releases/download/v$version/" \
    --embed-release-notes --link https://github.com/mrcat71/harnessmd \
    -o "$stage/appcast.xml" "$stage"
signature=$(xmllint --xpath 'string(/rss/channel/item/enclosure/@*[local-name()="edSignature"])' "$stage/appcast.xml")
offered=$(xmllint --xpath 'string(/rss/channel/item/*[local-name()="version"])' "$stage/appcast.xml")
[[ -n "$signature" && "$offered" == "$version" ]] || { echo 'Unsigned update, mismatched key, or incorrect appcast version' >&2; exit 1; }
printf '%s' "$SPARKLE_ED_PRIVATE_KEY" | "$tools/sign_update" --verify --ed-key-file - "$output/$zip" "$signature"
printf '%s' "$SPARKLE_ED_PRIVATE_KEY" | "$tools/sign_update" --verify --ed-key-file - "$stage/appcast.xml"
cp "$stage/appcast.xml" "$output/appcast.xml"
(cd "$output" && shasum -a 256 "$zip" "${zip%.zip}.dmg" appcast.xml > SHA256SUMS)
