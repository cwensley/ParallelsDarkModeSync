#!/bin/bash
# Installs the macOS -> Parallels Windows dark/light mode sync.
#
#   ./install.sh              install host watcher + agent into running Windows VMs
#   ./install.sh --host-only  install only the host side

set -euo pipefail

SRC_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LABEL="com.mcneel.darkmodesync"
STATE_DIR="$HOME/.darkmode-sync"
BIN_DIR="$STATE_DIR/bin"
GUEST_DIR="$STATE_DIR/guest"
PLIST="$HOME/Library/LaunchAgents/$LABEL.plist"
WATCHER_LOG="$STATE_DIR/watcher.log"

HOST_ONLY=0
[ "${1:-}" = "--host-only" ] && HOST_ONLY=1

bold() { printf '\033[1m%s\033[0m\n' "$*"; }
warn() { printf '\033[33m%s\033[0m\n' "$*" >&2; }
err()  { printf '\033[31m%s\033[0m\n' "$*" >&2; }

bold "Installing host side"

mkdir -p "$BIN_DIR" "$GUEST_DIR" "$HOME/Library/LaunchAgents"

# --- watcher ----------------------------------------------------------------

WATCHER="$BIN_DIR/darkmode-watcher"
if command -v swiftc >/dev/null 2>&1; then
    printf '  building the event-driven watcher... '
    if swiftc -O -o "$WATCHER" "$SRC_DIR/host/darkmode-watcher.swift" 2>"$STATE_DIR/build.log"; then
        printf 'ok\n'
        rm -f "$STATE_DIR/build.log"
    else
        printf 'failed\n'
        warn "  see $STATE_DIR/build.log; falling back to the polling watcher"
        install -m 0755 "$SRC_DIR/host/darkmode-watcher.sh" "$WATCHER"
    fi
else
    warn "  swiftc not found; installing the polling watcher instead"
    install -m 0755 "$SRC_DIR/host/darkmode-watcher.sh" "$WATCHER"
fi

install -m 0755 "$SRC_DIR/bin/dmsync" "$BIN_DIR/dmsync"
install -m 0644 "$SRC_DIR/guest/DarkModeSyncAgent.ps1"     "$GUEST_DIR/"
install -m 0644 "$SRC_DIR/guest/DarkModeSyncLauncher.cs"   "$GUEST_DIR/"
install -m 0644 "$SRC_DIR/guest/Install-GuestAgent.ps1"    "$GUEST_DIR/"
install -m 0644 "$SRC_DIR/guest/Uninstall-GuestAgent.ps1"  "$GUEST_DIR/"
install -m 0644 "$SRC_DIR/guest/Get-AgentLog.ps1"          "$GUEST_DIR/"
printf '  installed to %s\n' "$STATE_DIR"

# --- launch agent -----------------------------------------------------------

cat >"$PLIST" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>Label</key>
    <string>$LABEL</string>
    <key>ProgramArguments</key>
    <array>
        <string>$WATCHER</string>
    </array>
    <key>RunAtLoad</key>
    <true/>
    <key>KeepAlive</key>
    <true/>
    <key>ProcessType</key>
    <string>Background</string>
    <key>StandardOutPath</key>
    <string>$WATCHER_LOG</string>
    <key>StandardErrorPath</key>
    <string>$WATCHER_LOG</string>
</dict>
</plist>
EOF

launchctl bootout "gui/$UID/$LABEL" >/dev/null 2>&1 || true
launchctl bootstrap "gui/$UID" "$PLIST"
launchctl enable "gui/$UID/$LABEL" >/dev/null 2>&1 || true
printf '  launch agent loaded (%s)\n' "$LABEL"

# Give the watcher a moment to publish the current appearance.
for _ in 1 2 3 4 5 6 7 8 9 10; do
    [ -s "$STATE_DIR/state" ] && break
    sleep 0.3
done

if [ -s "$STATE_DIR/state" ]; then
    printf '  current appearance published: %s\n' "$(tr -d '[:space:]' <"$STATE_DIR/state")"
else
    err "  watcher did not publish a state file -- check $WATCHER_LOG"
    exit 1
fi

# --- optional: put dmsync on PATH -------------------------------------------

if [ -d /usr/local/bin ] && [ -w /usr/local/bin ]; then
    ln -sf "$BIN_DIR/dmsync" /usr/local/bin/dmsync
    printf '  linked /usr/local/bin/dmsync\n'
else
    warn "  /usr/local/bin is not writable; run dmsync as $BIN_DIR/dmsync"
    warn "  (or: sudo ln -sf $BIN_DIR/dmsync /usr/local/bin/dmsync)"
fi

# --- guest side -------------------------------------------------------------

if [ "$HOST_ONLY" -eq 1 ]; then
    printf '\n'
    bold "Host side done. Install into a VM with: dmsync install-guest"
    exit 0
fi

printf '\n'
bold "Installing into running Windows VMs"

if ! command -v prlctl >/dev/null 2>&1; then
    err "prlctl not found -- skipping the guest side."
    exit 1
fi

"$BIN_DIR/dmsync" install-guest || true

printf '\n'
bold "Done."
printf 'Toggle appearance on the Mac and Windows will follow within ~2 seconds.\n'
printf 'Check things over with: dmsync status\n'
