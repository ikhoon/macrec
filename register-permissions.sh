#!/bin/zsh
# register-permissions.sh — restart the watcher so its startup capture (run by launchd)
# re-registers macrec under Screen Recording + Microphone in System Settings.
source "${0:A:h}/config.sh"
LABEL="com.ikhoon.macrec"
DOMAIN="gui/$(id -u)"
launchctl kickstart -k "$DOMAIN/$LABEL" 2>/dev/null \
  && echo "↻ watcher restarted. Now open System Settings → Privacy & Security and enable" \
  && echo "  'macrec' under both Screen & System Audio Recording and Microphone." \
  || echo "agent not loaded — run ./install.sh first."
