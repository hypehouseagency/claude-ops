#!/usr/bin/env bash
# ssh-auto-whitelist.sh — SSH wrapper that self-heals on connection failure.
#
# Usage:
#   ssh-auto-whitelist.sh dev-sandbox [-- ssh args...]
#   ssh-auto-whitelist.sh dev-sandbox "remote command"
#
# Flow:
#   1. Try SSH normally (5s timeout).
#   2. On timeout/refused: run sam-ip-whitelist.sh to add current IP to SG.
#   3. Retry SSH (10s timeout). One retry only.
#
# Exit code = exit code of the final SSH invocation.

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
WHITELIST_SCRIPT="${SCRIPT_DIR}/sam-ip-whitelist.sh"

HOST="${1:-}"
[[ -z "$HOST" ]] && { echo "usage: $0 <ssh-host-alias> [ssh-args...|command]" >&2; exit 2; }
shift

log() { printf '[ssh-auto] %s\n' "$*" >&2; }

try_ssh() {
  local timeout=$1; shift
  ssh -o ConnectTimeout="$timeout" -o BatchMode=no "$HOST" "$@"
}

# First attempt
if try_ssh 5 "$@"; then
  exit 0
fi

rc=$?
# 255 = ssh-level failure (timeout, refused, unreachable). Anything else is the remote command's exit code.
if [[ $rc -ne 255 ]]; then exit $rc; fi

log "SSH failed (likely IP blocked) — refreshing SG whitelist…"
if ! bash "$WHITELIST_SCRIPT"; then
  log "whitelist refresh failed — aborting"
  exit $rc
fi

# Brief settle so SG mutation propagates
sleep 2

log "retrying SSH…"
try_ssh 10 "$@"
