#!/bin/bash
# Installs the FanGuard root daemon and the menu bar app.  Run: sudo ./install.sh
set -euo pipefail
cd "$(dirname "$0")"
[ "$(id -u)" = 0 ] || { echo "run with sudo: sudo ./install.sh"; exit 1; }
USER_NAME=${SUDO_USER:?run via sudo from your own account}
LIB=/usr/local/libexec/fanguard
PLIST=/Library/LaunchDaemons/local.fanguard.daemon.plist
MACMON=$(readlink -f "$(sudo -u "$USER_NAME" bash -lc 'command -v macmon')" 2>/dev/null || true)
SMC=/Applications/Stats.app/Contents/Resources/smc
[ -x dist/fanguardd ] || { echo "run ./build.sh first"; exit 1; }
[ -n "$MACMON" ] && [ -x "$MACMON" ] || { echo "macmon not found (brew install macmon)"; exit 1; }
[ -x "$SMC" ] || { echo "Stats.app smc tool not found at $SMC"; exit 1; }

launchctl bootout system "$PLIST" 2>/dev/null || true
# Root runs only root-owned copies, so nothing user-writable executes as root.
mkdir -p "$LIB"
install -o root -g wheel -m 755 dist/fanguardd "$LIB/fanguardd"
install -o root -g wheel -m 755 "$MACMON" "$LIB/macmon"
install -o root -g wheel -m 755 "$SMC" "$LIB/smc"
cat > "$PLIST" <<PL
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>Label</key><string>local.fanguard.daemon</string>
  <key>ProgramArguments</key><array><string>$LIB/fanguardd</string><string>$LIB</string></array>
  <key>RunAtLoad</key><true/>
  <key>KeepAlive</key><true/>
  <key>ThrottleInterval</key><integer>10</integer>
  <key>StandardErrorPath</key><string>/var/log/fanguard.log</string>
  <key>StandardOutPath</key><string>/var/log/fanguard.log</string>
</dict>
</plist>
PL
chown root:wheel "$PLIST"; chmod 644 "$PLIST"
launchctl bootstrap system "$PLIST"
echo "daemon installed and started (log: /var/log/fanguard.log)"

pkill -x FanGuard 2>/dev/null || true; sleep 1
rm -rf /Applications/FanGuard.app
cp -R dist/FanGuard.app /Applications/FanGuard.app
chown -R "$USER_NAME":staff /Applications/FanGuard.app
sudo -u "$USER_NAME" osascript -e 'tell application "System Events" to if not (exists login item "FanGuard") then make login item at end with properties {path:"/Applications/FanGuard.app", hidden:true}' >/dev/null 2>&1 \
  && echo "added FanGuard to login items" || echo "could not add login item; add /Applications/FanGuard.app in System Settings > General > Login Items"
sudo -u "$USER_NAME" open /Applications/FanGuard.app
echo "done"
