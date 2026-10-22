#!/bin/bash
set -euo pipefail

ROOT="$(cd "$(dirname "$0")" && pwd)"
APP="$ROOT/build/FinderOpenInIterm.app"
ARCH="$(uname -m)"

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"

cp "$ROOT/Resources/Info.plist" "$APP/Contents/Info.plist"

swiftc -O -swift-version 5 \
  -target "${ARCH}-apple-macos13.0" \
  -o "$APP/Contents/MacOS/FinderOpenInIterm" \
  "$ROOT/Sources/main.swift" \
  -framework Cocoa -framework ApplicationServices

codesign --force --sign - "$APP"
echo "built: $APP"
