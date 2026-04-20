#!/bin/bash
# btresumed uninstaller
# Usage: sudo ./uninstall.sh

set -euo pipefail

if [ "$(id -u)" -ne 0 ]; then
    echo "Please run with sudo: sudo ./uninstall.sh" >&2
    exit 1
fi

INSTALL_USER="${SUDO_USER:-$USER}"
INSTALL_UID=$(id -u "$INSTALL_USER")

launchctl bootout "gui/$INSTALL_UID/com.user.btresumed" 2>/dev/null || true
rm -f /Library/LaunchAgents/com.user.btresumed.plist
rm -f /usr/local/bin/btresumed
echo "Uninstalled."
echo "Note: the Bluetooth TCC permission entry can be removed manually in:"
echo "  System Settings → Privacy & Security → Bluetooth"
