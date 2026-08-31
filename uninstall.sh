#!/bin/bash
# Removes the macOS -> Parallels Windows dark/light mode sync.
#
#   ./uninstall.sh              remove the guest agent from running VMs, then the host side
#   ./uninstall.sh --host-only  remove only the host side

set -uo pipefail

LABEL="com.mcneel.darkmodesync"
STATE_DIR="$HOME/.darkmode-sync"
PLIST="$HOME/Library/LaunchAgents/$LABEL.plist"

HOST_ONLY=0
[ "${1:-}" = "--host-only" ] && HOST_ONLY=1

bold() { printf '\033[1m%s\033[0m\n' "$*"; }
warn() { printf '\033[33m%s\033[0m\n' "$*" >&2; }

if [ "$HOST_ONLY" -eq 0 ] && [ -x "$STATE_DIR/bin/dmsync" ] && command -v prlctl >/dev/null 2>&1; then
    bold "Removing the agent from running Windows VMs"
    "$STATE_DIR/bin/dmsync" uninstall-guest || warn "  (some VMs could not be reached)"
    printf '\n'
fi

bold "Removing host side"

launchctl bootout "gui/$UID/$LABEL" >/dev/null 2>&1 && printf '  launch agent unloaded\n' \
    || printf '  launch agent was not loaded\n'

rm -f "$PLIST" && printf '  removed %s\n' "$PLIST"

if [ -L /usr/local/bin/dmsync ]; then
    rm -f /usr/local/bin/dmsync 2>/dev/null \
        && printf '  removed /usr/local/bin/dmsync\n' \
        || warn "  could not remove /usr/local/bin/dmsync (try sudo)"
fi

rm -rf "$STATE_DIR" && printf '  removed %s\n' "$STATE_DIR"

printf '\n'
bold "Done."
printf 'Appearance settings on the Mac and in Windows were left unchanged.\n'
