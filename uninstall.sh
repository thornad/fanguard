#!/bin/bash
# Removes FanGuard and returns the fans to macOS.  Run: sudo ./uninstall.sh
set -u
[ "$(id -u)" = 0 ] || { echo "run with sudo: sudo ./uninstall.sh"; exit 1; }
PLIST=/Library/LaunchDaemons/local.fanguard.daemon.plist
launchctl bootout system "$PLIST" 2>/dev/null   # daemon resets fans to automatic on SIGTERM
/usr/local/libexec/fanguard/smc fan 0 -m 0 >/dev/null 2>&1; /usr/local/libexec/fanguard/smc fan 1 -m 0 >/dev/null 2>&1
/usr/local/libexec/fanguard/smc reset >/dev/null 2>&1
rm -f "$PLIST"; rm -rf /usr/local/libexec/fanguard
pkill -x FanGuard 2>/dev/null; rm -rf /Applications/FanGuard.app
[ -n "${SUDO_USER:-}" ] && sudo -u "$SUDO_USER" osascript -e 'tell application "System Events" to delete login item "FanGuard"' >/dev/null 2>&1
echo "FanGuard removed; settings left in /Users/Shared/FanGuard"
