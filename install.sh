#!/bin/bash
# btresumed one-shot installer
# Usage: sudo ./install.sh
#
# Builds, installs, and loads the LaunchAgent. Safe to re-run (idempotent).

set -euo pipefail

SELF_DIR="$(cd "$(dirname "$0")" && pwd)"
cd "$SELF_DIR"

if [ "$(id -u)" -ne 0 ]; then
    echo "Please run with sudo: sudo ./install.sh" >&2
    exit 1
fi

# Resolve the invoking (non-root) user so we load the agent into their GUI session
INSTALL_USER="${SUDO_USER:-$USER}"
if [ -z "$INSTALL_USER" ] || [ "$INSTALL_USER" = "root" ]; then
    echo "Cannot determine a non-root user. Run with sudo from your normal account." >&2
    exit 1
fi
INSTALL_UID=$(id -u "$INSTALL_USER")

echo "Building btresumed for $(uname -m)..."
if ! command -v clang >/dev/null 2>&1; then
    echo "clang not found. Install Xcode Command Line Tools: xcode-select --install" >&2
    exit 1
fi
clang -arch "$(uname -m)" -fobjc-arc -O2 -Wall -Wno-deprecated-declarations \
    -o btresumed btresumed.m \
    -framework Foundation -framework IOBluetooth -framework CoreBluetooth

# Restore build artifact ownership to the invoking user so the repo isn't
# littered with root-owned files (makes later `make clean` or git status clean).
chown "$INSTALL_USER" btresumed

echo "Installing binary and LaunchAgent plist..."
mkdir -p /usr/local/bin
install -m 755 btresumed /usr/local/bin/btresumed
install -m 644 com.user.btresumed.plist /Library/LaunchAgents/com.user.btresumed.plist

echo "Loading LaunchAgent into gui/$INSTALL_UID..."
launchctl bootout "gui/$INSTALL_UID/com.user.btresumed" 2>/dev/null || true
if ! launchctl bootstrap "gui/$INSTALL_UID" /Library/LaunchAgents/com.user.btresumed.plist; then
    echo "launchctl bootstrap failed. Check: plutil -lint /Library/LaunchAgents/com.user.btresumed.plist" >&2
    exit 1
fi

# Verify the service is actually registered
if ! launchctl print "gui/$INSTALL_UID/com.user.btresumed" >/dev/null 2>&1; then
    echo "Service bootstrap succeeded but print check failed. Inspect manually." >&2
    exit 1
fi

echo
echo "Installed. macOS will prompt '$INSTALL_USER' to allow Bluetooth access — click Allow."
echo "Logs: /tmp/btresumed.log"
echo "Verify with: launchctl print gui/$INSTALL_UID/com.user.btresumed"
