#!/bin/zsh
# uninstall.sh — stop and remove the LaunchAgent (keeps your binary, scripts, and recordings).
LABEL="com.ikhoon.meeting-recorder"
PLIST="$HOME/Library/LaunchAgents/$LABEL.plist"
DOMAIN="gui/$(id -u)"
launchctl bootout "$DOMAIN/$LABEL" 2>/dev/null || true
rm -f "$PLIST"
echo "🗑  agent removed. Recordings in meetings/ are untouched."
echo "   To also revoke permissions: System Settings → Privacy & Security → remove 'meeting-capture'."
