#!/bin/bash
# Kills orphan `gh ... --watch` and tight-poll-loop processes older than 5 min.
# Runs every 60s while it's active. Idempotent. Safe to run in parallel.
#
# Triggered by: SessionStart hook (foreground guarded by pidfile to avoid duplicates).
#
# Source of truth: ~/Projects/claude-ops/claude-ops/scripts/gh-orphan-killer.sh

set -euo pipefail

PIDFILE="${TMPDIR:-/tmp}/gh-orphan-killer.pid"
LOG="${HOME}/.claude/logs/gh-orphan-killer.log"
mkdir -p "$(dirname "$LOG")"

# Singleton: if another instance is running with a fresh pidfile, exit
if [ -f "$PIDFILE" ]; then
  prev_pid=$(cat "$PIDFILE" 2>/dev/null || echo "")
  if [ -n "$prev_pid" ] && kill -0 "$prev_pid" 2>/dev/null; then
    exit 0
  fi
fi
echo $$ > "$PIDFILE"
trap 'rm -f "$PIDFILE"' EXIT

while true; do
  # `gh ... --watch` is never legitimate — kill on sight, no age check.
  # Sibling Claude sessions repeatedly spawn it; tight loop minimises burn.
  killed=0
  for pid in $(pgrep -f "gh pr checks .*--watch" 2>/dev/null; pgrep -f "gh run watch" 2>/dev/null); do
    [ -z "$pid" ] && continue
    cmd=$(ps -o command= -p "$pid" 2>/dev/null | head -c 120)
    echo "$(date -u +%Y-%m-%dT%H:%M:%SZ) kill orphan pid=$pid: $cmd" >> "$LOG"
    kill -9 "$pid" 2>/dev/null || true
    # also nuke parent shell if it's the wrapper that spawned the watch
    ppid=$(ps -o ppid= -p "$pid" 2>/dev/null | tr -d ' ')
    if [ -n "$ppid" ] && [ "$ppid" != "1" ]; then
      pcmd=$(ps -o command= -p "$ppid" 2>/dev/null | head -c 100)
      if echo "$pcmd" | grep -q "gh pr checks.*--watch\|gh run watch"; then
        echo "$(date -u +%Y-%m-%dT%H:%M:%SZ)   + parent pid=$ppid: $pcmd" >> "$LOG"
        kill -9 "$ppid" 2>/dev/null || true
      fi
    fi
    killed=$((killed + 1))
  done

  [ "$killed" -gt 0 ] && echo "$(date -u +%Y-%m-%dT%H:%M:%SZ) killed $killed orphan(s)" >> "$LOG"

  sleep 3
done
