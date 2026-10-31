#!/bin/sh
# Builds dist/Cutline.app with the preview app and the cutline-mcp server inside.
#
# Signs ad-hoc by default, which macOS runs without a Gatekeeper prompt when built on this Mac;
# certificate-signed builds are blocked as unverified until notarized. Set CUTLINE_RELEASE=1 to
# sign with Developer ID and the hardened runtime for scripts/notarize.sh, or
# CUTLINE_SIGNING_IDENTITY to pick an identity.
set -eu

repo_root=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
cd "$repo_root"

version=${CUTLINE_VERSION:-$(cat VERSION)}
build=${CUTLINE_BUILD:-$(date +%Y%m%d%H%M)}
release=${CUTLINE_RELEASE:-0}
identity=${CUTLINE_SIGNING_IDENTITY:-}

if [ -z "$identity" ] && [ "$release" = 1 ]; then
  identity=$(security find-identity -v -p codesigning | sed -n 's/.*"\(Developer ID Application: [^"]*\)".*/\1/p' | head -1)
  [ -n "$identity" ] || { echo "No Developer ID Application certificate found" >&2; exit 1; }
fi
identity=${identity:--}

swift build -c release --arch arm64 --product Cutline
swift build -c release --arch arm64 --product cutline-mcp
bin=$(swift build -c release --arch arm64 --show-bin-path)

app=dist/Cutline.app
rm -rf "$app"
mkdir -p "$app/Contents/MacOS" "$app/Contents/Resources"
cp "$bin/Cutline" "$app/Contents/MacOS/Cutline"
cp "$bin/cutline-mcp" "$app/Contents/MacOS/cutline-mcp"
cp Resources/AppIcon.icns "$app/Contents/Resources/AppIcon.icns"
sed -e "s/__VERSION__/$version/" -e "s/__BUILD__/$build/" Resources/Info.plist > "$app/Contents/Info.plist"

options=""
[ "$release" = 1 ] && options="--options runtime --timestamp"
# shellcheck disable=SC2086
codesign --force $options --sign "$identity" "$app/Contents/MacOS/cutline-mcp"
# shellcheck disable=SC2086
codesign --force $options --entitlements Resources/Cutline.entitlements --sign "$identity" "$app"
codesign --verify --strict "$app"
/usr/libexec/PlistBuddy -c "Print :NSMicrophoneUsageDescription" "$app/Contents/Info.plist" >/dev/null
echo "Built $app ($version, signed: $identity)"
