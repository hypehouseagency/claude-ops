# AWS Infrastructure Runbook

Account: 000000000000 | Region: us-east-1

---

## healify-bastion (i-024bf965e1bb18970)

**DO NOT TERMINATE.**

Tags: `Role=grafana-pdc-host`, `DoNotTerminate=true`

### Role

This instance is the sole host for the **Grafana Private Datasource Connect (PDC) agent** (`/opt/grafana-pdc-agent/pdc`). It maintains a persistent SSH tunnel to Grafana Cloud cluster `prod-us-east-0` (Grafana Cloud ID `1497743`), which is the only path for Grafana to reach private VPC datasources (Aurora PostgreSQL, any internal endpoints).

Terminating this instance without migrating the PDC agent will **immediately blind Grafana to all private datasources**.

### What runs on it

- PDC agent: `/opt/grafana-pdc-agent/pdc -cluster prod-us-east-0 -gcloud-hosted-grafana-id 1497743`
- SSH tunnel to `private-datasource-connect-prod-us-east-0.grafana.net:22`
- Provisioned by: `.github/workflows/grafana-pdc-setup.yml` via SSM

### Access pattern

```bash
# SSM (preferred — no key needed)
ssh bastion           # uses ~/.ssh/config Host bastion → SSM ProxyCommand

# Aurora tunnel via bastion
ssh -fNL 5433:${AURORA_HOST}:5432 bastion
```

### Before any termination

1. Migrate PDC agent to a Fargate sidecar task or a replacement EC2.
2. Confirm Grafana Cloud datasources are healthy (green in Grafana UI) on the new host.
3. Update `.github/workflows/grafana-pdc-setup.yml` target instance.
4. Remove `DoNotTerminate` tag only after step 2 is confirmed.

---

## Aurora SSL enforcement — pending prod reboot

`rds.force_ssl=1` is set on both `healify-aurora-prod-params` and `healify-aurora-staging-params` with `ApplyMethod=pending-reboot`.

**Staging:** rebooted 2026-05-22. Both instances returned to `available`. SSL enforcement active.

**Prod:** scheduled for **Sunday 02:00 UTC**. Procedure:

1. Reboot writer: `aws rds reboot-db-instance --region us-east-1 --db-instance-identifier healify-aurora-prod-writer`
2. Wait for Aurora to promote reader (~30–60 s failover). Writer returns to `available`.
3. Reboot reader: `aws rds reboot-db-instance --region us-east-1 --db-instance-identifier healify-aurora-prod-reader`
4. Verify: `aws rds describe-db-cluster-parameters --db-cluster-parameter-group-name healify-aurora-prod-params --query "Parameters[?ParameterName=='rds.force_ssl']"` — confirm `ApplyMethod` is no longer `pending-reboot`.
5. Smoke-test: `GET /health` on healify-api prod returns 200.

**Rollback:** set `rds.force_ssl=0` on the param group, reboot again. No data loss.

All clients confirmed `sslmode=require` in Doppler before the staging reboot.

---

## WAF — ScannerBotProtectionACL-Prod (COUNT mode)

Applied 2026-05-22. ACL associated to:

- `xpod-api-production` ALB (`arn:.../app/xpod-api-production/ea79fe7305e6632e`)
- `example-prod` ALB (`arn:.../app/example-prod/dcbfcef6f1dcef45`)

Rule `BlockKnownScannerUserAgents`: matches `user-agent` header containing `sqlmap` (LOWERCASE transform). **Action: Count** (not Block) — no requests are blocked.

Logs: `aws-waf-logs-ScannerBotProtectionACL-Prod` (30-day retention, us-east-1).

### Flip to BLOCK

After 24h monitoring with no false positives:

```bash
# Get current lock token
LOCK=$(aws wafv2 get-web-acl --region us-east-1 --scope REGIONAL \
  --name ScannerBotProtectionACL-Prod \
  --id 8748587f-998f-4b14-bd58-120041d08046 \
  --query "LockToken" --output text)

# Update rule Action back to Block
python3 - << EOF
import boto3
client = boto3.client('wafv2', region_name='us-east-1')
response = client.update_web_acl(
    Name='ScannerBotProtectionACL-Prod',
    Scope='REGIONAL',
    Id='8748587f-998f-4b14-bd58-120041d08046',
    LockToken='${LOCK}',
    DefaultAction={'Allow': {}},
    Rules=[{
        'Name': 'BlockKnownScannerUserAgents',
        'Priority': 1,
        'Statement': {
            'ByteMatchStatement': {
                'SearchString': b'sqlmap',
                'FieldToMatch': {'SingleHeader': {'Name': 'user-agent'}},
                'TextTransformations': [{'Priority': 0, 'Type': 'LOWERCASE'}],
                'PositionalConstraint': 'CONTAINS'
            }
        },
        'Action': {'Block': {}},
        'VisibilityConfig': {
            'SampledRequestsEnabled': True,
            'CloudWatchMetricsEnabled': True,
            'MetricName': 'BlockKnownScannerUserAgents'
        }
    }],
    VisibilityConfig={
        'SampledRequestsEnabled': True,
        'CloudWatchMetricsEnabled': True,
        'MetricName': 'ScannerBotProtectionACL-Prod'
    }
)
print('BLOCK_MODE_ACTIVE, NextLockToken:', response['NextLockToken'])
EOF
```

### Rollback (disassociate WAF)

```bash
aws wafv2 disassociate-web-acl --region us-east-1 \
  --resource-arn "arn:aws:elasticloadbalancing:us-east-1:000000000000:loadbalancer/app/xpod-api-production/ea79fe7305e6632e"

aws wafv2 disassociate-web-acl --region us-east-1 \
  --resource-arn "arn:aws:elasticloadbalancing:us-east-1:000000000000:loadbalancer/app/example-prod/dcbfcef6f1dcef45"
```
