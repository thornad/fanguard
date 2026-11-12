#!/bin/bash
# Builds FanGuard.app (menu bar app) and fanguardd (root daemon) into ./dist
set -euo pipefail
cd "$(dirname "$0")"
swift build -c release
rm -rf dist && mkdir -p dist/FanGuard.app/Contents/MacOS
cp .build/release/FanGuard dist/FanGuard.app/Contents/MacOS/FanGuard
cp .build/release/fanguardd dist/fanguardd
cat > dist/FanGuard.app/Contents/Info.plist <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleName</key><string>FanGuard</string>
  <key>CFBundleIdentifier</key><string>local.fanguard.app</string>
  <key>CFBundleExecutable</key><string>FanGuard</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>1.0</string>
  <key>CFBundleVersion</key><string>1</string>
  <key>LSMinimumSystemVersion</key><string>14.0</string>
  <key>LSUIElement</key><true/>
</dict>
</plist>
PLIST
codesign --force --sign - dist/FanGuard.app
codesign --force --sign - dist/fanguardd
echo "built: dist/FanGuard.app dist/fanguardd"
