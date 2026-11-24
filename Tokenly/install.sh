#!/usr/bin/env bash
# Install Tokenly to ~/Applications and start it at every login (LaunchAgent). Re-run to update.
set -euo pipefail
cd "$(dirname "$0")/.."
bash Tokenly/build.sh
dest="$HOME/Applications/Tokenly.app"; plist="$HOME/Library/LaunchAgents/local.tokenly.plist"
mkdir -p "$HOME/Applications" "$HOME/Library/LaunchAgents"
launchctl bootout "gui/$(id -u)/local.tokenly" 2>/dev/null || true
pkill -f "Tokenly.app/Contents/MacOS/Tokenly" 2>/dev/null || true
rm -rf "$dest"; cp -R Tokenly.app "$dest"
cat > "$plist" <<PL
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>Label</key><string>local.tokenly</string>
  <key>ProgramArguments</key><array><string>$dest/Contents/MacOS/Tokenly</string></array>
  <key>RunAtLoad</key><true/>
</dict></plist>
PL
launchctl bootstrap "gui/$(id -u)" "$plist"
echo "installed: $dest (starts at login; remove with: launchctl bootout gui/$(id -u)/local.tokenly && rm $plist)"
