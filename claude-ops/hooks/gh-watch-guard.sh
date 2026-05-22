#!/bin/bash
# PreToolUse Bash hook — blocks rate-limit-burning gh patterns.
#
# Reads Claude Code hook stdin, exits 0 (allow) or 2 (block + stderr).
# Pairs with the persistent gh-orphan-killer.sh watchdog.
#
# Source of truth: ~/Projects/claude-ops/claude-ops/hooks/gh-watch-guard.sh
# Plugin cache copy (auto-installed via plugin update) is read-only.

stdin=$(cat)
CMD=$(echo "$stdin" | jq -r '.tool_input.command // empty' 2>/dev/null)

# Fast path: not a gh command, exit immediately
case "$CMD" in
    *gh\ *|*gh-*) ;;
    *) exit 0 ;;
esac

# Allowlist: searching for / killing offending processes is NOT calling them.
# `pkill -f "gh pr checks.*--watch"`, `pgrep -af "gh ..."`, `ps | grep "gh ..."`,
# `kill <pid>` etc. should always pass through.
if echo "$CMD" | grep -qE '\b(pkill|pgrep|killall|kill\s+-[0-9])\b' ; then
    exit 0
fi
# `grep "gh ..."`, `awk '/gh /'`, file reads referencing the string by name
if echo "$CMD" | grep -qE '\b(grep|awk|sed|rg|ag|find|locate|file|ls|cat|head|tail|less|more|wc|sort|uniq|jq)\b' \
   && ! echo "$CMD" | grep -qE 'gh\s+(pr|run|api|repo|issue|release|workflow|auth|search|browse|gist|secret|variable|cache|attestation|extension|label|status|version|alias|config|completion)'; then
    # Common Unix tools that may quote the string but aren't running it
    exit 0
fi

# --- Pattern 1: --watch flag on gh pr checks / gh run watch ---
# `gh pr checks <PR> --watch` and `gh run watch` poll every 2-5s.
# 5000 REST/hr ÷ 2s = exhausted in ~3 hours of one process. Sam saw this in production.
if echo "$CMD" | grep -qE 'gh\s+pr\s+checks\s+[^|]*--watch|gh\s+run\s+watch'; then
    cat >&2 <<'EOF'
BLOCKED: `gh ... --watch` polls every 2-5s and exhausts the 5000/hr REST quota.

Use the Monitor tool with an `until` poll loop at ≥25s instead:

  prev=""
  while true; do
    s=$(gh pr view <PR> --repo <REPO> --json mergeStateStatus,statusCheckRollup)
    state=$(echo "$s" | jq -r .mergeStateStatus)
    [ "$state" = "CLEAN" ] || [ "$state" = "UNSTABLE" ] && { echo READY; break; }
    sleep 30
  done

For multi-PR watching prefer GraphQL (separate 5000/hr bucket) — single query, multiple PRs.

Source: ~/Projects/claude-ops/claude-ops/hooks/gh-watch-guard.sh
EOF
    exit 2
fi

# --- Pattern 2: tight gh loops (sleep < 25s) ---
# Catches: `while true; do gh ...; sleep 5; done` style polls,
# including bash heredocs (`bash << EOF ... done EOF`).
# Multi-line aware: drop newlines before regexing.
CMD_FLAT=$(echo "$CMD" | tr '\n' ' ')
if echo "$CMD_FLAT" | grep -qE '(while|until|for|do).*gh\s+(api|pr|run|issue)' && \
   echo "$CMD_FLAT" | grep -qE 'sleep\s+([0-9]|1[0-9]|2[0-4])(\s|;|$|\\)'; then
    cat >&2 <<'EOF'
BLOCKED: tight gh polling loop (sleep < 25s) detected.

The 5000/hr REST quota is shared across this session, background daemons, the overnight
sync cron, and any other gh process. A loop at sleep 5 burns 720 calls/hr — easy to exhaust.

Options:
  - Bump to `sleep 30` (or higher)
  - Use the Monitor tool — handles ≥25s naturally and emits on state-change
  - Use GraphQL (separate 5000/hr bucket) for multi-PR checks

Heredoc loops (`bash << EOF`) ARE caught by this rule.
EOF
    exit 2
fi

# --- Pattern 3: gh ... --watch already covered above, but also catch in subshells/eval ---
if echo "$CMD_FLAT" | grep -qE 'gh\s+(pr|run)\s+(checks|view|status)?\s*\S*\s*--watch\b'; then
    cat >&2 'BLOCKED: gh ... --watch hidden in subshell/eval. Use Monitor with ≥25s poll instead.'
    exit 2
fi

exit 0
