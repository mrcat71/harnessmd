#!/bin/sh
set -eu
cd "$(dirname "$0")"
configuration="${CONFIGURATION:-release}"
swift build -c "$configuration" --product HarnessApp --disable-automatic-resolution
bin="$(swift build -c "$configuration" --show-bin-path)"
app="${DIST_DIR:-dist}/harnessmd.app"
mkdir -p "$app/Contents/MacOS" "$app/Contents/Resources" "$app/Contents/Frameworks"
cp "$bin/HarnessApp" "$app/Contents/MacOS/HarnessApp"
cp Support/Info.plist "$app/Contents/Info.plist"
if [ -n "${SPARKLE_PUBLIC_ED_KEY:-}" ]; then
    printf '%s\n' "$SPARKLE_PUBLIC_ED_KEY" | grep -Eq '^[A-Za-z0-9+/]{43}=$' || { printf 'SPARKLE_PUBLIC_ED_KEY must be a base64-encoded 32-byte Ed25519 key\n' >&2; exit 1; }
    /usr/libexec/PlistBuddy -c "Add :SUPublicEDKey string $SPARKLE_PUBLIC_ED_KEY" "$app/Contents/Info.plist"
fi
# Sparkle is dynamic even though HarnessKit and GRDB are linked statically.
framework=".build/artifacts/sparkle/Sparkle/Sparkle.xcframework/macos-arm64_x86_64/Sparkle.framework"
test -d "$framework"
ditto "$framework" "$app/Contents/Frameworks/Sparkle.framework"
install_name_tool -add_rpath '@executable_path/../Frameworks' "$app/Contents/MacOS/HarnessApp"
# Remove build-machine search paths so a packaged launch proves it is portable.
otool -l "$app/Contents/MacOS/HarnessApp" | awk '/LC_RPATH/{r=1; next} r && /path /{print $2; r=0}' | while IFS= read -r path; do
    case "$path" in
        /usr/lib/swift|@*) ;;
        *) install_name_tool -delete_rpath "$path" "$app/Contents/MacOS/HarnessApp" ;;
    esac
done
# SwiftPM dependencies can supply resource bundles beside the executable.
for bundle in "$bin/"*.bundle; do
    if [ -d "$bundle" ]; then
        ditto "$bundle" "$app/Contents/Resources/$(basename "$bundle")"
    fi
done
codesign --force --deep --sign - "$app"
codesign --verify --deep --strict "$app"
printf 'Built %s\n' "$app"
