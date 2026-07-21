#!/bin/zsh
# uninstall.sh — stop and remove the LaunchAgents (keeps your binary, scripts, and recordings).
LABEL="com.ikhoon.macrec"
WD_LABEL="com.ikhoon.macrec.watchdog"
DOMAIN="gui/$(id -u)"
# Bootout the watchdog FIRST — else it would relaunch the recorder we're about to remove (#36b).
launchctl bootout "$DOMAIN/$WD_LABEL" 2>/dev/null || true
launchctl bootout "$DOMAIN/$LABEL" 2>/dev/null || true
rm -f "$HOME/Library/LaunchAgents/$LABEL.plist" "$HOME/Library/LaunchAgents/$WD_LABEL.plist"
echo "🗑  agents removed (recorder + watchdog). Recordings in meetings/ are untouched."
echo "   To also revoke permissions: System Settings → Privacy & Security → remove 'macrec'."
