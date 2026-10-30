#!/bin/sh
# Builds dist/Cutline.app with the preview app and the cutline-mcp server inside.
#
# Signs with the first "Apple Development" identity, or CUTLINE_SIGNING_IDENTITY, falling
# back to ad-hoc. Set CUTLINE_RELEASE=1 to sign with Developer ID and the hardened runtime.
set -eu

repo_root=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
cd "$repo_root"

version=${CUTLINE_VERSION:-0.1.0}
build=${CUTLINE_BUILD:-$(date +%Y%m%d%H%M)}
release=${CUTLINE_RELEASE:-0}
identity=${CUTLINE_SIGNING_IDENTITY:-}

if [ -z "$identity" ]; then
  kind="Apple Development"
  [ "$release" = 1 ] && kind="Developer ID Application"
  identity=$(security find-identity -v -p codesigning | sed -n "s/.*\"\($kind: [^\"]*\)\".*/\1/p" | head -1)
fi
if [ -z "$identity" ]; then
  [ "$release" = 1 ] && { echo "No Developer ID Application certificate found" >&2; exit 1; }
  identity="-"
fi

swift build -c release --arch arm64 --product Cutline
swift build -c release --arch arm64 --product cutline-mcp
bin=$(swift build -c release --arch arm64 --show-bin-path)

app=dist/Cutline.app
rm -rf "$app"
mkdir -p "$app/Contents/MacOS" "$app/Contents/Resources"
cp "$bin/Cutline" "$app/Contents/MacOS/Cutline"
cp "$bin/cutline-mcp" "$app/Contents/MacOS/cutline-mcp"
cp Resources/AppIcon.icns "$app/Contents/Resources/AppIcon.icns"
cp -R Sources/Cutline/Fonts "$app/Contents/Resources/Fonts"
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
