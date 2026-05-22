#!/usr/bin/env bash
# install-ip-whitelist-agent.sh — install launchd agent for auto IP whitelisting on network change.
# Idempotent: unloads existing agent before reinstalling.

set -euo pipefail

LABEL="com.<user>.ip-whitelist"
PLIST_SRC="$(cd "$(dirname "$0")/../launchd" && pwd)/${LABEL}.plist"
PLIST_DEST="$HOME/Library/LaunchAgents/${LABEL}.plist"
GUI_DOMAIN="gui/$(id -u)"

log() { printf '[install-ip-whitelist] %s\n' "$*"; }

# --- unload existing agent if present ---
if launchctl print "${GUI_DOMAIN}/${LABEL}" &>/dev/null; then
  log "unloading existing agent..."
  launchctl bootout "${GUI_DOMAIN}/${PLIST_DEST}" 2>/dev/null \
    || launchctl bootout "${GUI_DOMAIN}" "${PLIST_DEST}" 2>/dev/null \
    || launchctl remove "${LABEL}" 2>/dev/null \
    || true
  sleep 1
fi

# --- copy plist ---
log "installing plist to ${PLIST_DEST}"
cp "${PLIST_SRC}" "${PLIST_DEST}"

# --- bootstrap ---
log "bootstrapping ${GUI_DOMAIN}/${LABEL}"
launchctl bootstrap "${GUI_DOMAIN}" "${PLIST_DEST}"

# --- print status ---
log "agent loaded. status:"
launchctl print "${GUI_DOMAIN}/${LABEL}"
