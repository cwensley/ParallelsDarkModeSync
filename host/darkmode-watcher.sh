#!/bin/bash
# Fallback host watcher, used only when swiftc is unavailable to build
# darkmode-watcher.swift. Same contract: keep ~/.darkmode-sync/state holding
# either "dark" or "light". Polls instead of listening for notifications.

set -u

STATE_DIR="$HOME/.darkmode-sync"
STATE_FILE="$STATE_DIR/state"
TMP_FILE="$STATE_DIR/.state.tmp"
INTERVAL="${DARKMODE_SYNC_INTERVAL:-2}"

mkdir -p "$STATE_DIR"

last=""
while :; do
    if [ "$(defaults read -g AppleInterfaceStyle 2>/dev/null)" = "Dark" ]; then
        mode="dark"
    else
        mode="light"
    fi

    if [ "$mode" != "$last" ]; then
        printf '%s\n' "$mode" >"$TMP_FILE" && mv -f "$TMP_FILE" "$STATE_FILE"
        last="$mode"
        printf '%s published %s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$mode" >&2
    fi

    sleep "$INTERVAL"
done
