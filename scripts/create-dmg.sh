#!/bin/sh
# Packages an app bundle into a drag-to-Applications DMG.
set -eu

app_path=${1:-dist/Cutline.app}
dmg_path=${2:-dist/Cutline.dmg}
staging_dir=$(mktemp -d)

cleanup() {
  rm -r "$staging_dir"
}
trap cleanup EXIT

ditto "$app_path" "$staging_dir/Cutline.app"
ln -s /Applications "$staging_dir/Applications"
mkdir -p "$(dirname "$dmg_path")"
hdiutil create \
  -quiet \
  -volname "Cutline" \
  -srcfolder "$staging_dir" \
  -format UDZO \
  -ov \
  "$dmg_path"
echo "Created $dmg_path"
