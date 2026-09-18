#!/bin/sh
# Build, install, and start at login.
set -e
HERE="$(cd "$(dirname "$0")" && pwd)"
LABEL="local.claudestatus"
PLIST="$HOME/Library/LaunchAgents/$LABEL.plist"
BIN="$HOME/Applications/Claude Status.app/Contents/MacOS/ClaudeStatus"

sh "$HERE/build.sh"
mkdir -p "$HOME/Library/LaunchAgents"
cat > "$PLIST" <<PL
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>Label</key><string>$LABEL</string>
  <key>ProgramArguments</key><array><string>$BIN</string></array>
  <key>RunAtLoad</key><true/>
  <key>KeepAlive</key><dict><key>SuccessfulExit</key><false/></dict>
  <key>ProcessType</key><string>Interactive</string>
</dict>
</plist>
PL

launchctl bootout "gui/$(id -u)/$LABEL" 2>/dev/null || true
launchctl bootstrap "gui/$(id -u)" "$PLIST"
echo "Installed and running. Look for the asterisk in your menu bar."
echo "Desktop panel: click the menu bar icon -> Show Desktop Panel."
