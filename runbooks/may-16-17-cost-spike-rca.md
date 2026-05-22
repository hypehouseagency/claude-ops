# Cost Spike RCA — May 16-17, 2026

**Authored:** 2026-05-22
**Account:** 000000000000 (us-east-1)
**Linear ticket:** HEA-4266

---

## Summary

Amazon Bedrock AgentCore spiked from a $0.20/day baseline to $10.24 on May 16 and $15.59 on May 17. Total excess cost over the 2-day period: ~$25.43. AgentCore returned toward baseline on May 18 ($1.61).

---

## Daily spend table (AgentCore)

| Date | AgentCore Cost | vs Baseline |
|------|---------------|-------------|
| May 14 | $0.21 | baseline |
| May 15 | $0.19 | baseline |
| May 16 | $10.24 | +51x |
| May 17 | **$15.59** | **+78x** |
| May 18 | $1.61 | normalizing |

---

## Root cause

**AgentCore runtime sessions spawned at unsustainable frequency, billing continuously on `USE1-Runtime:Consumption-based:Memory` and `Runtime:vCPU`.**

Usage-type breakdown for May 16 ($10.24 total):
- `USE1-Runtime:Consumption-based:Memory`: $8.32 (81%)
- `USE1-Runtime:Consumption-based:vCPU`: $1.29 (13%)
- Data transfer + memory storage: remainder

Usage-type breakdown for May 17 ($15.59 total):
- `USE1-Runtime:Consumption-based:Memory`: $12.89 (83%)
- `USE1-Runtime:Consumption-based:vCPU`: $1.96 (13%)

This is not a Bedrock LLM token spend — the `Amazon Bedrock` service line stayed flat at $0.06-0.11/day throughout. This is exclusively AgentCore executor runtime (GB-second + vCPU-second charges from running agent sessions).

**Corroborating signals:**
- CloudWatch `USE1-DataProcessing-Bytes` spiked on May 16 ($1.16) and May 17 ($1.39) — excess log ingestion from high-volume agent execution.
- CloudTrail charges spiked from $0.64 baseline to $1.09-1.19 — elevated API call volume.
- Pattern matches the known `@Cron × ECS multi-leader` leak profile documented in CLAUDE.md (2026-05-18: a `*/30s` cron × ECS multi-leader = $6.9K/mo).

**Probable mechanism:** One or more scheduled tasks in `healify-agentcore` invoked AgentCore runtime sessions on a tight interval. With ECS Fargate running multiple tasks, all tasks acted as leader simultaneously (no correct leader election), multiplying session spawn rate by N tasks.

---

## Prevention checklist

- [ ] **1. Audit crons in `healify-agentcore`** — grep every `@Cron`/`setInterval` that invokes AgentCore runtime sessions. Verify each has ECS Fargate-safe leader election (not `NODE_APP_INSTANCE` — invalid on Fargate). Add a process-global rate-floor: max N concurrent sessions, queue excess with backpressure.

- [ ] **2. Add session concurrency cap** — implement a process-global semaphore or token-bucket limiting total concurrent AgentCore session invocations across the process. Document the chosen max and the per-session expected GB-second cost so the cap is defensible.

- [ ] **3. Budget alarm on AgentCore** — create an AWS Budget alarm: filter `Amazon Bedrock AgentCore`, threshold $2/day, notification to ops Slack channel. The May spike ran 2 full days undetected; a $2/day alarm would have fired within hours of May 16.
  ```bash
  aws budgets create-budget --account-id 000000000000 --budget '{
    "BudgetName": "AgentCore-Daily-2USD",
    "BudgetLimit": {"Amount": "2", "Unit": "USD"},
    "TimeUnit": "DAILY",
    "BudgetType": "COST",
    "CostFilters": {"Service": ["Amazon Bedrock AgentCore"]}
  }' --notifications-with-subscribers '[{
    "Notification": {"NotificationType":"ACTUAL","ComparisonOperator":"GREATER_THAN","Threshold":100,"ThresholdType":"PERCENTAGE"},
    "Subscribers": [{"SubscriptionType":"SNS","Address":"arn:aws:sns:us-east-1:000000000000:ops-alerts"}]
  }]'
  ```

- [ ] **4. Log group retention** — audit all CloudWatch log groups created by AgentCore runtime (prefix `/aws/bedrock-agentcore/` or similar). Apply explicit retention of 30 or 90 days to any group without it. Unretained log groups compound cost during any future runaway.
  ```bash
  aws logs describe-log-groups --log-group-name-prefix "/aws/bedrock" \
    --query "logGroups[?retentionInDays==null].logGroupName"
  # For each result:
  # aws logs put-retention-policy --log-group-name LOG_GROUP --retention-in-days 30
  ```

---

## Detection gap

No Budget alarm existed for AgentCore at per-day granularity. Cost Anomaly Detection (monthly scope) did not fire within the 2-day window. A $2/day alarm (checklist item 3) closes this gap.
