# S3 Object Lock Migration — siem-archive + compliance-evidence + siem-logs

**Date authored:** 2026-05-22
**Status:** APPROVED (deferred execution)
**Prerequisite:** Interim deny-delete bucket policies already applied (2026-05-22).

---

## Overview

Object Lock cannot be enabled on existing buckets. This runbook creates v2 buckets with Object Lock in GOVERNANCE mode, replicates data, updates consumers, and retires old buckets.

Buckets in scope:
- `healify-siem-archive` → `healify-siem-archive-v2`
- `healify-compliance-evidence` → `healify-compliance-evidence-v2`
- `healify-siem-logs` → `healify-siem-logs-v2`

Estimated cost: ~$0.25 (S3 Batch Operations minimum) + negligible data (all buckets < 1 MB currently).

---

## Phase 1 — Create locked v2 buckets

```bash
REGION=us-east-1
ACCOUNT=000000000000

for BUCKET in healify-siem-archive-v2 healify-compliance-evidence-v2 healify-siem-logs-v2; do
  aws s3api create-bucket \
    --bucket $BUCKET \
    --region $REGION \
    --object-lock-enabled-for-bucket 2>&1

  # Enable versioning (required for Object Lock)
  aws s3api put-bucket-versioning \
    --bucket $BUCKET \
    --versioning-configuration Status=Enabled

  # Set default Object Lock retention: GOVERNANCE mode, 365 days
  aws s3api put-object-lock-configuration \
    --bucket $BUCKET \
    --object-lock-configuration '{
      "ObjectLockEnabled": "Enabled",
      "Rule": {
        "DefaultRetention": {
          "Mode": "GOVERNANCE",
          "Days": 365
        }
      }
    }'

  echo "$BUCKET: created with Object Lock GOVERNANCE 365d"
done
```

Verify Object Lock is active:
```bash
for BUCKET in healify-siem-archive-v2 healify-compliance-evidence-v2 healify-siem-logs-v2; do
  aws s3api get-object-lock-configuration --bucket $BUCKET
done
```

---

## Phase 2 — Apply bucket policies to v2 buckets

### healify-siem-archive-v2
```bash
aws s3api put-bucket-policy --bucket healify-siem-archive-v2 --policy '{
  "Version": "2012-10-17",
  "Statement": [
    {
      "Sid": "AllowSESPuts",
      "Effect": "Allow",
      "Principal": {"Service": "ses.amazonaws.com"},
      "Action": "s3:PutObject",
      "Resource": "arn:aws:s3:::healify-siem-archive-v2/ses-catchall/*",
      "Condition": {"StringEquals": {"AWS:SourceAccount": "000000000000"}}
    },
    {
      "Sid": "DenyDeleteUnlessMfaRoot",
      "Effect": "Deny",
      "Principal": "*",
      "Action": ["s3:DeleteObject","s3:DeleteObjectVersion","s3:DeleteBucket"],
      "Resource": ["arn:aws:s3:::healify-siem-archive-v2/*","arn:aws:s3:::healify-siem-archive-v2"],
      "Condition": {"Bool": {"aws:MultiFactorAuthPresent": "false"}}
    }
  ]
}'
```

### healify-compliance-evidence-v2
```bash
aws s3api put-bucket-policy --bucket healify-compliance-evidence-v2 --policy '{
  "Version": "2012-10-17",
  "Statement": [
    {
      "Sid": "DenyDeleteUnlessMfaRoot",
      "Effect": "Deny",
      "Principal": "*",
      "Action": ["s3:DeleteObject","s3:DeleteObjectVersion","s3:DeleteBucket"],
      "Resource": ["arn:aws:s3:::healify-compliance-evidence-v2/*","arn:aws:s3:::healify-compliance-evidence-v2"],
      "Condition": {"Bool": {"aws:MultiFactorAuthPresent": "false"}}
    }
  ]
}'
```

### healify-siem-logs-v2
```bash
aws s3api put-bucket-policy --bucket healify-siem-logs-v2 --policy '{
  "Version": "2012-10-17",
  "Statement": [
    {
      "Sid": "AWSCloudTrailAclCheck",
      "Effect": "Allow",
      "Principal": {"Service": "cloudtrail.amazonaws.com"},
      "Action": "s3:GetBucketAcl",
      "Resource": "arn:aws:s3:::healify-siem-logs-v2"
    },
    {
      "Sid": "AWSCloudTrailWrite",
      "Effect": "Allow",
      "Principal": {"Service": "cloudtrail.amazonaws.com"},
      "Action": "s3:PutObject",
      "Resource": "arn:aws:s3:::healify-siem-logs-v2/cloudtrail/*",
      "Condition": {"StringEquals": {"s3:x-amz-acl": "bucket-owner-full-control"}}
    },
    {
      "Sid": "AWSConfigBucketPermissionsCheck",
      "Effect": "Allow",
      "Principal": {"Service": "config.amazonaws.com"},
      "Action": "s3:GetBucketAcl",
      "Resource": "arn:aws:s3:::healify-siem-logs-v2"
    },
    {
      "Sid": "AWSConfigBucketExistenceCheck",
      "Effect": "Allow",
      "Principal": {"Service": "config.amazonaws.com"},
      "Action": "s3:ListBucket",
      "Resource": "arn:aws:s3:::healify-siem-logs-v2"
    },
    {
      "Sid": "AWSConfigWrite",
      "Effect": "Allow",
      "Principal": {"Service": "config.amazonaws.com"},
      "Action": "s3:PutObject",
      "Resource": "arn:aws:s3:::healify-siem-logs-v2/config/*",
      "Condition": {"StringEquals": {"s3:x-amz-acl": "bucket-owner-full-control"}}
    },
    {
      "Sid": "DenyDeleteUnlessMfaRoot",
      "Effect": "Deny",
      "Principal": "*",
      "Action": ["s3:DeleteObject","s3:DeleteObjectVersion","s3:DeleteBucket"],
      "Resource": ["arn:aws:s3:::healify-siem-logs-v2/*","arn:aws:s3:::healify-siem-logs-v2"],
      "Condition": {"Bool": {"aws:MultiFactorAuthPresent": "false"}}
    }
  ]
}'
```

---

## Phase 3 — Replicate data via S3 Batch Operations

For each source bucket, create a manifest and submit a Batch copy job.
Note: Batch Operations requires a replication IAM role.

### Create replication IAM role (one-time)
```bash
aws iam create-role --role-name s3-batch-replication-role --assume-role-policy-document '{
  "Version": "2012-10-17",
  "Statement": [{
    "Effect": "Allow",
    "Principal": {"Service": "batchoperations.s3.amazonaws.com"},
    "Action": "sts:AssumeRole"
  }]
}'

aws iam put-role-policy --role-name s3-batch-replication-role --policy-name s3-batch-copy --policy-document '{
  "Version": "2012-10-17",
  "Statement": [
    {
      "Effect": "Allow",
      "Action": ["s3:GetObject","s3:GetObjectVersion","s3:GetBucketVersioning","s3:ListBucket","s3:ListBucketVersions"],
      "Resource": [
        "arn:aws:s3:::healify-siem-archive","arn:aws:s3:::healify-siem-archive/*",
        "arn:aws:s3:::healify-compliance-evidence","arn:aws:s3:::healify-compliance-evidence/*",
        "arn:aws:s3:::healify-siem-logs","arn:aws:s3:::healify-siem-logs/*"
      ]
    },
    {
      "Effect": "Allow",
      "Action": ["s3:PutObject","s3:PutObjectRetention"],
      "Resource": [
        "arn:aws:s3:::healify-siem-archive-v2/*",
        "arn:aws:s3:::healify-compliance-evidence-v2/*",
        "arn:aws:s3:::healify-siem-logs-v2/*"
      ]
    }
  ]
}'
```

### Submit Batch copy jobs (one per source bucket)
```bash
ROLE_ARN="arn:aws:iam::000000000000:role/s3-batch-replication-role"
REGION=us-east-1
ACCOUNT=000000000000

# For each pair, use S3 Batch Operations with COPY operation
# Replace SOURCE and DEST per bucket:

# siem-archive
aws s3control create-job \
  --account-id $ACCOUNT \
  --region $REGION \
  --operation '{"S3CopyObject":{"TargetResource":"arn:aws:s3:::healify-siem-archive-v2","TargetKeyPrefix":"","MetadataDirective":"COPY"}}' \
  --manifest '{"Spec":{"Format":"S3BatchOperations_CSV_20180820","Fields":["Bucket","Key"]},"Location":{"ObjectArn":"arn:aws:s3:::healify-siem-archive-v2/manifest.csv","ETag":"REPLACE_WITH_ETAG"}}' \
  --report '{"Bucket":"arn:aws:s3:::healify-siem-archive-v2","Prefix":"batch-reports","Format":"Report_CSV_20180820","Enabled":true,"ReportScope":"AllTasks"}' \
  --role-arn $ROLE_ARN \
  --priority 10 \
  --no-confirmation-required

# NOTE: For small buckets (<1MB), direct aws s3 sync is simpler and sufficient:
# aws s3 sync s3://healify-siem-archive s3://healify-siem-archive-v2 --source-region us-east-1
# aws s3 sync s3://healify-compliance-evidence s3://healify-compliance-evidence-v2 --source-region us-east-1
# aws s3 sync s3://healify-siem-logs s3://healify-siem-logs-v2 --source-region us-east-1
# RECOMMENDED: use sync for these buckets given the tiny data size.
```

**Preferred for these small buckets:**
```bash
aws s3 sync s3://healify-siem-archive s3://healify-siem-archive-v2
aws s3 sync s3://healify-compliance-evidence s3://healify-compliance-evidence-v2
aws s3 sync s3://healify-siem-logs s3://healify-siem-logs-v2
```

Verify object counts match:
```bash
for SRC in healify-siem-archive healify-compliance-evidence healify-siem-logs; do
  DST="${SRC}-v2"
  SRC_COUNT=$(aws s3api list-objects-v2 --bucket $SRC --query "KeyCount" --output text)
  DST_COUNT=$(aws s3api list-objects-v2 --bucket $DST --query "KeyCount" --output text)
  echo "$SRC: $SRC_COUNT objects -> $DST: $DST_COUNT objects"
done
```

---

## Phase 4 — Update consumers to v2 buckets

### CloudTrail
```bash
# Find existing trail pointing to healify-siem-logs
aws cloudtrail describe-trails --query "trailList[?S3BucketName=='healify-siem-logs'].{Name:Name,Bucket:S3BucketName}"

# Update trail to v2 bucket (replace TRAIL_NAME)
aws cloudtrail update-trail --name TRAIL_NAME --s3-bucket-name healify-siem-logs-v2

# Verify
aws cloudtrail describe-trails --query "trailList[?Name=='TRAIL_NAME'].S3BucketName"
```

### AWS Config
```bash
# Find Config delivery channel pointing to healify-siem-logs
aws configservice describe-delivery-channels

# Update delivery channel (replace CHANNEL_NAME)
aws configservice put-delivery-channel --delivery-channel '{
  "name": "CHANNEL_NAME",
  "s3BucketName": "healify-siem-logs-v2"
}'
```

### SES (catch-all receipts → siem-archive)
```bash
# Find SES receipt rules writing to healify-siem-archive
aws ses describe-active-receipt-rule-set

# Update any S3Action bucket references from healify-siem-archive to healify-siem-archive-v2
# (manual update via console or aws ses update-receipt-rule depending on rule structure)
```

---

## Phase 5 — Sunset old buckets (30-day hold)

After confirming all consumers write to v2 and no reads/writes hit old buckets for 30 days:

```bash
# First: verify zero recent activity (check S3 access logs or CloudTrail for GetObject/PutObject on old buckets)
aws cloudtrail lookup-events \
  --lookup-attributes AttributeKey=ResourceName,AttributeValue=healify-siem-archive \
  --start-time $(date -v-7d +%Y-%m-%dT%H:%M:%S) \
  --query "Events[].{Time:EventTime,Name:EventName,User:Username}"

# If clean, suspend writes to old buckets by removing allow statements from policies
# Then delete (requires MFA + root or break-glass role):
# aws s3 rm s3://healify-siem-archive --recursive
# aws s3api delete-bucket --bucket healify-siem-archive
```

---

## Rollback

At any phase before consumer cutover: old buckets remain untouched.
After consumer cutover but before old bucket deletion: revert consumer configs to old bucket names (Phase 4 in reverse).
Old buckets have the interim deny-delete policy — data is safe throughout.

---

## Cost estimate

| Item | Cost |
|------|------|
| s3 sync (<1MB total) | $0.00 |
| New bucket storage (same data) | ~$0.00/mo at current size |
| S3 Batch Operations (if used) | $0.25 minimum |
| **Total one-time** | **~$0.25** |
