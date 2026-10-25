#!/bin/sh
# Build monitor-switch and install it as a LaunchAgent that starts at login.
set -e
cd "$(dirname "$0")"
DIR="$(pwd)"
LABEL=com.monitor-switch
PLIST="$HOME/Library/LaunchAgents/$LABEL.plist"

swiftc -O main.swift -o monitor-switch

cat > "$PLIST" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>Label</key><string>$LABEL</string>
  <key>ProgramArguments</key><array><string>$DIR/monitor-switch</string></array>
  <key>RunAtLoad</key><true/>
  <key>KeepAlive</key><true/>
  <key>ProcessType</key><string>Interactive</string>
  <key>StandardOutPath</key><string>/tmp/monitor-switch.log</string>
  <key>StandardErrorPath</key><string>/tmp/monitor-switch.log</string>
</dict>
</plist>
PLIST

launchctl bootout "gui/$(id -u)/$LABEL" 2>/dev/null || true
launchctl bootstrap "gui/$(id -u)" "$PLIST"
echo "Installed. Cmd+PageUp -> HDMI 2, Cmd+PageDown -> DisplayPort 1"
