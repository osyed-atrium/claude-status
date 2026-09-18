#!/bin/sh
LABEL="local.claudestatus"
launchctl bootout "gui/$(id -u)/$LABEL" 2>/dev/null || true
rm -f "$HOME/Library/LaunchAgents/$LABEL.plist"
rm -rf "$HOME/Applications/Claude Status.app"
defaults delete "$LABEL" 2>/dev/null || true
echo "Removed."
