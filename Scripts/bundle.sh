#!/bin/zsh
# Builds Plinth and wraps the executable in a runnable Plinth.app.
# Usage: Scripts/bundle.sh [debug|release]   (default: debug)
set -euo pipefail
cd "$(dirname "$0")/.."
export DEVELOPER_DIR="${DEVELOPER_DIR:-/Applications/Xcode.app/Contents/Developer}"
CONFIG="${1:-debug}"

swift build -c "$CONFIG" --product Plinth
BIN="$(swift build -c "$CONFIG" --show-bin-path)"
APP="build/Plinth.app"

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN/Plinth" "$APP/Contents/MacOS/Plinth"
# SwiftPM resource bundles (the content-blocking rules).
for bundle in "$BIN"/*.bundle(N); do cp -R "$bundle" "$APP/Contents/Resources/"; done
cp Scripts/Info.plist "$APP/Contents/Info.plist"
[[ -f Scripts/Plinth.icns ]] && cp Scripts/Plinth.icns "$APP/Contents/Resources/Plinth.icns"
codesign --force --sign - "$APP" >/dev/null
echo "$APP"
