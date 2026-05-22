#!/usr/bin/env bash
# sam-ip-whitelist.sh — sync current public IP into dev-sandbox SG ingress.
#
# Behavior (idempotent):
#   1. Fetch current public IPv4 via ifconfig.me / icanhazip.com.
#   2. If already present in SG with a sam-laptop-* description: no-op.
#   3. Otherwise revoke all sam-laptop-* rules older than KEEP_RECENT count.
#   4. Authorize the new IP on TCP 22 with description "sam-laptop-YYYYMMDD-HHMM".
#
# Env overrides:
#   SG_ID            (default: sg-0ee18bb7c170d17ae — dev-sandbox)
#   REGION           (default: us-east-1)
#   KEEP_RECENT      (default: 2 — newest N sam-laptop-* rules retained pre-add)
#   IP_OVERRIDE      explicit IP if curl-detect should be skipped
#
# Exit codes:
#   0  success (added or already present)
#   1  could not detect public IP
#   2  AWS CLI / SG mutation failure

set -euo pipefail

SG_ID="${SG_ID:-sg-0ee18bb7c170d17ae}"
REGION="${REGION:-us-east-1}"
KEEP_RECENT="${KEEP_RECENT:-2}"
DESC_PREFIX="sam-laptop"
PORT=22

log() { printf '[ip-whitelist] %s\n' "$*" >&2; }

# --- detect current public IPv4 ---
detect_ip() {
  if [[ -n "${IP_OVERRIDE:-}" ]]; then echo "$IP_OVERRIDE"; return 0; fi
  for url in https://ifconfig.me https://icanhazip.com https://api.ipify.org; do
    ip=$(curl -s4 --max-time 5 "$url" 2>/dev/null | tr -d '[:space:]') || true
    if [[ "$ip" =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}$ ]]; then echo "$ip"; return 0; fi
  done
  return 1
}

IP=$(detect_ip) || { log "could not detect public IP"; exit 1; }
log "current public IP: $IP"

# --- fetch current SG rules (flatten nested IpRanges arrays) ---
RULES_JSON=$(aws ec2 describe-security-groups \
  --region "$REGION" --group-ids "$SG_ID" \
  --query "SecurityGroups[].IpPermissions[?FromPort==\`$PORT\`].IpRanges[]" \
  --output json 2>/dev/null) || { log "aws describe-security-groups failed"; exit 2; }

# AWS returns nested arrays — flatten before filtering
RULES_FLAT=$(echo "$RULES_JSON" | jq '[.[] | .[]?] // []')

# Already present?
if echo "$RULES_FLAT" | jq -e --arg ip "${IP}/32" '.[] | select(.CidrIp == $ip)' >/dev/null 2>&1; then
  log "IP $IP already whitelisted — no-op"
  exit 0
fi

# --- prune stale sam-laptop-* entries (keep KEEP_RECENT newest by timestamp suffix) ---
mapfile -t STALE < <(
  echo "$RULES_FLAT" | jq -r --arg p "$DESC_PREFIX-" --argjson keep "$KEEP_RECENT" '
    [.[] | select(.Description // "" | startswith($p))]
    | sort_by(.Description) | reverse | .[$keep:]
    | .[] | "\(.CidrIp)|\(.Description)"
  '
)

for entry in "${STALE[@]}"; do
  [[ -z "$entry" ]] && continue
  cidr="${entry%%|*}"
  desc="${entry##*|}"
  log "revoking stale $desc ($cidr)"
  aws ec2 revoke-security-group-ingress \
    --region "$REGION" --group-id "$SG_ID" \
    --ip-permissions "IpProtocol=tcp,FromPort=$PORT,ToPort=$PORT,IpRanges=[{CidrIp=$cidr}]" \
    >/dev/null 2>&1 || log "  (revoke failed for $cidr — continuing)"
done

# --- authorize new IP ---
TIMESTAMP=$(date +%Y%m%d-%H%M)
NEW_DESC="${DESC_PREFIX}-${TIMESTAMP}"
log "authorizing $IP/32 as $NEW_DESC"

aws ec2 authorize-security-group-ingress \
  --region "$REGION" --group-id "$SG_ID" \
  --ip-permissions "IpProtocol=tcp,FromPort=$PORT,ToPort=$PORT,IpRanges=[{CidrIp=$IP/32,Description=$NEW_DESC}]" \
  >/dev/null 2>&1 || { log "authorize failed"; exit 2; }

log "✓ $IP whitelisted as $NEW_DESC on $SG_ID"
