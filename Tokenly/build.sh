#!/usr/bin/env bash
# Builds Tokenly.app next to this script's parent folder.
set -euo pipefail
cd "$(dirname "$0")/.."
app=Tokenly.app
rm -rf "$app"; mkdir -p "$app/Contents/MacOS" "$app/Contents/Resources"
cp Tokenly/icon/AppIcon.icns "$app/Contents/Resources/"
swiftc -O Tokenly/main.swift -o "$app/Contents/MacOS/Tokenly"
cat > "$app/Contents/Info.plist" <<'EOF'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>CFBundleName</key><string>Tokenly</string>
  <key>CFBundleIconFile</key><string>AppIcon</string>
  <key>CFBundleExecutable</key><string>Tokenly</string>
  <key>CFBundleIdentifier</key><string>local.tokenly</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>LSUIElement</key><true/>
</dict></plist>
EOF
codesign --force --sign - "$app" >/dev/null 2>&1 || true  # ad-hoc sign so macOS will launch it
echo "built $app"
