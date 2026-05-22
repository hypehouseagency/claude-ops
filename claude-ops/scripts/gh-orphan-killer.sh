#!/bin/bash
# Kills orphan `gh ... --watch` and tight-poll-loop processes older than 5 min.
# Runs every 60s while it's active. Idempotent. Safe to run in parallel.
#
# Triggered by: SessionStart hook (foreground guarded by pidfile to avoid duplicates).
#
# Source of truth: ~/Projects/claude-ops/claude-ops/scripts/gh-orphan-killer.sh

set -uo pipefail
# NOT using -e: kill/ps on dead pids return non-zero; we want to keep looping.

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
  # Catch:
  # 1. `gh ... --watch` (always bad)
  # 2. `gh run watch` (always bad)
  # 3. Shells running tight gh-poll loops: the wrapping zsh whose command line
  #    contains both `gh pr view|checks|api` AND `sleep [1-9]` or `sleep 1[0-9]`
  pids=$( {
    pgrep -f "gh pr checks .*--watch" 2>/dev/null
    pgrep -f "gh run watch" 2>/dev/null
    # Find zsh/bash poll-loop wrappers (sleep <20s + gh OR curl-to-github in same cmdline)
    ps -eo pid,command 2>/dev/null | awk '
      /\/opt\/homebrew\/bin\/zsh|\/bin\/bash/ &&
      ( /gh pr (view|checks|api|status)/ || /curl[^|]*api\.github\.com/ ) &&
      /sleep [1-9](\s|;|\\|\))|sleep 1[0-9](\s|;|\\|\))/ &&
      !/gh-orphan-killer|gh-watch-guard|github-api-watcher/ { print $1 }
    '
    # Also catch the actual curl-to-github children (not just wrappers)
    pgrep -f "curl.*api\.github\.com" 2>/dev/null | while read p; do
      # only kill curl if its parent is a known-bad poll wrapper
      ppid=$(ps -o ppid= -p "$p" 2>/dev/null | tr -d ' ')
      [ -n "$ppid" ] && pcmd=$(ps -o command= -p "$ppid" 2>/dev/null) || pcmd=""
      if echo "$pcmd" | grep -qE 'until|while.*sleep [1-9](\s|;|\)|\\)|sleep 1[0-9](\s|;|\)|\\)'; then
        echo "$p"
      fi
    done
  } | sort -u )
  for pid in $pids; do
    [ -z "$pid" ] && continue
    # capture parent BEFORE killing child
    ppid=$(ps -o ppid= -p "$pid" 2>/dev/null | tr -d ' ' || echo "")
    cmd=$(ps -o command= -p "$pid" 2>/dev/null | head -c 120 || echo "")
    pcmd=""
    if [ -n "$ppid" ] && [ "$ppid" != "1" ]; then
      pcmd=$(ps -o command= -p "$ppid" 2>/dev/null | head -c 200 || echo "")
    fi
    echo "$(date -u +%Y-%m-%dT%H:%M:%SZ) kill orphan pid=$pid: $cmd" >> "$LOG"
    kill -9 "$pid" 2>/dev/null
    # Kill the wrapping shell too if it explicitly ran the watch
    if [ -n "$pcmd" ] && echo "$pcmd" | grep -q "gh pr checks.*--watch\|gh run watch"; then
      echo "$(date -u +%Y-%m-%dT%H:%M:%SZ)   + parent pid=$ppid: $pcmd" >> "$LOG"
      kill -9 "$ppid" 2>/dev/null
    fi
    killed=$((killed + 1))
  done

  [ "$killed" -gt 0 ] && echo "$(date -u +%Y-%m-%dT%H:%M:%SZ) killed $killed orphan(s)" >> "$LOG"

  sleep 3
done
