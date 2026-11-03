#!/bin/bash
# Local integration test only. Keys and artifacts stay in a fresh temporary directory.
set -euo pipefail
cd "$(dirname "$0")/.."
fixture=$(mktemp -d "${TMPDIR:-/tmp}/harnessmd-release-test.XXXXXX")
export DIST_DIR="$fixture/artifacts"
swift - "$fixture" <<'SWIFT'
import CryptoKit
import Foundation
let directory = URL(fileURLWithPath: CommandLine.arguments[1])
let key = Curve25519.Signing.PrivateKey()
for (name, data) in [("private", key.rawRepresentation), ("public", key.publicKey.rawRepresentation),
                     ("wrong", Curve25519.Signing.PrivateKey().rawRepresentation)] {
    let file = directory.appendingPathComponent(name)
    try Data(data.base64EncodedString().utf8).write(to: file)
    try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path)
}
SWIFT
export SPARKLE_PUBLIC_ED_KEY
SPARKLE_PUBLIC_ED_KEY=$(cat "$fixture/public")
bash scripts/package-app.sh
export SPARKLE_ED_PRIVATE_KEY
SPARKLE_ED_PRIVATE_KEY=$(cat "$fixture/wrong")
if bash scripts/make-appcast.sh > "$fixture/mismatch.log" 2>&1; then
    echo 'A mismatched signing key was accepted' >&2; exit 1
fi
SPARKLE_ED_PRIVATE_KEY=$(cat "$fixture/private")
bash scripts/make-appcast.sh
grep -q '### Added' "$DIST_DIR/RELEASE_NOTES.md"
grep -q 'not Developer ID signed or notarized' "$DIST_DIR/RELEASE_NOTES.md"
(cd "$DIST_DIR" && shasum -a 256 -c SHA256SUMS)
zip=$(printf '%s\n' "$DIST_DIR"/harnessmd-*.zip)
ditto -x -k "$zip" "$fixture/unpacked"
codesign --verify --deep --strict "$fixture/unpacked/harnessmd.app"
"$fixture/unpacked/harnessmd.app/Contents/MacOS/HarnessApp" --validate-update-configuration
"$fixture/unpacked/harnessmd.app/Contents/MacOS/HarnessApp" --self-test
dmg=$(printf '%s\n' "$DIST_DIR"/harnessmd-*.dmg)
mkdir "$fixture/mount"
hdiutil attach -quiet -readonly -nobrowse -mountpoint "$fixture/mount" "$dmg"
trap 'hdiutil detach -quiet "$fixture/mount"' EXIT
test "$(readlink "$fixture/mount/Applications")" = /Applications
codesign --verify --deep --strict "$fixture/mount/harnessmd.app"
printf 'Release integration passed with disposable test keys: %s\n' "$fixture"
