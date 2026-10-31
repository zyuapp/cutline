#!/bin/sh
# Notarizes and staples dist/Cutline.app, then writes the release assets to dist/:
# Cutline.zip and Cutline.dmg, each with a .sha256 file.
#
# Needs an App Store Connect API key: APPLE_API_KEY (path to the .p8), APPLE_API_KEY_ID and
# APPLE_API_ISSUER. The app must already be signed with Developer ID (CUTLINE_RELEASE=1).
set -eu

repo_root=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
cd "$repo_root"

app=dist/Cutline.app
[ -d "$app" ] || { echo "Missing $app; run scripts/build-app.sh first" >&2; exit 1; }
: "${APPLE_API_KEY:?}" "${APPLE_API_KEY_ID:?}" "${APPLE_API_ISSUER:?}"

submit() {
  xcrun notarytool submit "$1" --key "$APPLE_API_KEY" --key-id "$APPLE_API_KEY_ID" --issuer "$APPLE_API_ISSUER" --wait --timeout 30m
}

# Notarization takes a zip; the stapled app is zipped again for download.
rm -f dist/Cutline.zip
ditto -c -k --keepParent "$app" dist/Cutline.zip
submit dist/Cutline.zip
xcrun stapler staple "$app"
rm dist/Cutline.zip
ditto -c -k --keepParent "$app" dist/Cutline.zip

identity=$(codesign -dvv "$app" 2>&1 | sed -n 's/^Authority=\(Developer ID Application: .*\)$/\1/p' | head -1)
scripts/create-dmg.sh "$app" dist/Cutline.dmg
codesign --force --timestamp --sign "$identity" dist/Cutline.dmg
submit dist/Cutline.dmg
xcrun stapler staple dist/Cutline.dmg

spctl --assess --type execute "$app"
for f in Cutline.zip Cutline.dmg; do
  (cd dist && shasum -a 256 "$f" > "$f.sha256")
done
echo "Notarized dist/Cutline.zip and dist/Cutline.dmg"
