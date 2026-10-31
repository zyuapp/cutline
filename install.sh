#!/bin/sh
# Install the latest Cutline release and connect it to Claude Code.
#
#   curl -fsSL https://raw.githubusercontent.com/zyuapp/cutline/main/install.sh | sh
#
# Puts the notarized app in /Applications (or ~/Applications when that is not writable) and,
# when the claude CLI is installed, registers the cutline MCP server for every project.
set -eu

REPO="zyuapp/cutline"
DOWNLOAD="https://github.com/$REPO/releases/latest/download"

fail() { printf '\nInstall failed: %s\n' "$1" >&2; exit 1; }
say() { printf '%s\n' "$1"; }

[ "$(uname -s)" = Darwin ] || fail "Cutline runs on macOS only."
arch="$(uname -m)"
if [ "$arch" = x86_64 ] && [ "$(sysctl -n hw.optional.arm64 2>/dev/null || true)" = 1 ]; then arch=arm64; fi
[ "$arch" = arm64 ] || fail "Cutline needs a Mac with Apple silicon, and this Mac is $arch."
major="$(sw_vers -productVersion | cut -d. -f1)"
[ "$major" -ge 26 ] || fail "Cutline needs macOS 26 or later, and this Mac has $(sw_vers -productVersion)."
command -v curl >/dev/null 2>&1 || fail "curl is required."

applications=/Applications
[ -w "$applications" ] || applications="$HOME/Applications"
mkdir -p "$applications"

# Stage inside the destination so the final move is a rename on the same filesystem.
staging="$applications/.cutline-install.$$"
rm -rf "$staging"
mkdir "$staging"
trap 'rm -rf "$staging"' EXIT INT TERM

say "Downloading Cutline."
curl -fL --retry 3 --progress-bar -o "$staging/Cutline.zip" "$DOWNLOAD/Cutline.zip" \
  || fail "The download did not finish."
expected="$(curl -fsSL "$DOWNLOAD/Cutline.zip.sha256" | cut -d' ' -f1)" \
  || fail "Could not read the checksum of the latest release."
[ "$(shasum -a 256 "$staging/Cutline.zip" | cut -d' ' -f1)" = "$expected" ] \
  || fail "The download did not match its checksum. Try again."

if pgrep -f "/Cutline.app/Contents/MacOS/Cutline" >/dev/null 2>&1; then
  fail "Cutline is running. Quit it, then run this again."
fi
/usr/bin/ditto -x -k "$staging/Cutline.zip" "$staging/unpacked" || fail "The download could not be unpacked."
[ -d "$staging/unpacked/Cutline.app" ] || fail "The download contained no app."
target="$applications/Cutline.app"
rm -rf "$target"
mv "$staging/unpacked/Cutline.app" "$target"
version="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$target/Contents/Info.plist" 2>/dev/null || echo latest)"
say "Installed Cutline $version in $target"

server="$target/Contents/MacOS/cutline-mcp"
if command -v claude >/dev/null 2>&1; then
  if claude mcp get cutline >/dev/null 2>&1; then
    say "Claude Code already has a cutline server. To point it at this copy, run:"
    say "  claude mcp remove cutline -s user && claude mcp add -s user cutline -- \"$server\""
  elif claude mcp add -s user cutline -- "$server" >/dev/null; then
    say "Connected Cutline to Claude Code. Ask Claude for a video in any project."
  else
    say "Could not add the MCP server. Run: claude mcp add -s user cutline -- \"$server\""
  fi
else
  say "Install Claude Code, then run: claude mcp add -s user cutline -- \"$server\""
fi

open -a "$target"
