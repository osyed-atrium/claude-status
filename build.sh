#!/bin/sh
# Builds "Claude Status.app". No Xcode needed -- Command Line Tools are enough.
set -e
DEST="${1:-$HOME/Applications}"
APP="$DEST/Claude Status.app"
SRC="$(cd "$(dirname "$0")" && pwd)/ClaudeStatus.swift"

mkdir -p "$APP/Contents/MacOS"
cat > "$APP/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleName</key><string>Claude Status</string>
  <key>CFBundleIdentifier</key><string>local.claudestatus</string>
  <key>CFBundleExecutable</key><string>ClaudeStatus</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>1.0</string>
  <key>LSUIElement</key><true/>
  <key>LSMinimumSystemVersion</key><string>13.0</string>
</dict>
PLIST
echo '</plist>' >> "$APP/Contents/Info.plist"

swiftc -O "$SRC" -o "$APP/Contents/MacOS/ClaudeStatus"
echo "Built: $APP"
