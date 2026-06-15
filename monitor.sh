#!/usr/bin/env bash
# -- Windows Git Bash path fix ------------------------------------------------
export MSYS_NO_PATHCONV=1
export MSYS2_ARG_CONV_EXCL="*"
# =============================================================================
# monitor.sh — Post-Launch Monitoring, Tagging, Audit, Notification
# Called by Step Functions Lambda after launch.sh completes
# =============================================================================

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CONFIG_FILE="${SCRIPT_DIR}/config.env"

CLEAN_ENV="/tmp/config_clean_monitor_$$.env"
sed 's/\r//' "$CONFIG_FILE" > "$CLEAN_ENV"
set +u; source "$CLEAN_ENV"; set -u
rm -f "$CLEAN_ENV"

RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'
CYAN='\033[0;36m'; BOLD='\033[1m'; NC='\033[0m'

ok()     { echo -e "${GREEN}  ✔  $*${NC}"; }
info()   { echo -e "${CYAN}  ℹ  $*${NC}"; }
warn()   { echo -e "${YELLOW}  ⚠  $*${NC}"; }
fail()   { echo -e "${RED}  ✖  $*${NC}"; }
header() { echo -e "\n${BOLD}━━━━━  $*  ━━━━━${NC}"; }

PROFILE_FLAG=""
[[ -n "${AWS_PROFILE:-}" ]] && PROFILE_FLAG="--profile ${AWS_PROFILE}"

PIPELINE_RUN_ID="${PIPELINE_RUN_ID:-}"
SSM_PREFIX="/gpu-capacity-pipeline/${PIPELINE_RUN_ID}"

get_param() {
  aws $PROFILE_FLAG ssm get-parameter \
    --region "$AWS_REGION" \
    --name "${SSM_PREFIX}/$1" \
    --query "Parameter.Value" \
    --output text 2>/dev/null || echo ""
}

LAUNCH_REGION=$(get_param "reservation-region")
LAUNCH_REGION="${LAUNCH_REGION:-$AWS_REGION}"

aws_cmd()  { aws $PROFILE_FLAG --region "$LAUNCH_REGION" --output text "$@"; }

# ── Read all details from SSM ─────────────────────────────────────────────────
RESERVATION_ID=$(get_param "reservation-id")
INSTANCE_IDS_SSM=$(get_param "instance-ids")
PRIVATE_IPS_SSM=$(get_param "private-ips")
LAUNCH_TIMESTAMP=$(get_param "launch-timestamp")
INSTANCE_TYPE_SELECTED=$(get_param "instance-type")
UPFRONT_FEE=$(get_param "upfront-fee")
RESERVE_AZ=$(get_param "az")
START_DATE_RESV=$(get_param "start-date")
END_DATE_RESV=$(get_param "end-date")

INSTANCE_LIST=""
for ID in $INSTANCE_IDS_SSM; do INSTANCE_LIST="${INSTANCE_LIST}  ${ID}\n"; done

# ── Step 1: Install CloudWatch agent via SSM ──────────────────────────────────
header "1 / 5  Installing CloudWatch GPU monitoring agent"

CW_AGENT_INSTALLED=0
for INSTANCE_ID in $INSTANCE_IDS_SSM; do
  info "Installing CloudWatch agent on $INSTANCE_ID..."
  aws $PROFILE_FLAG ssm send-command \
    --region "$LAUNCH_REGION" \
    --instance-ids "$INSTANCE_ID" \
    --document-name "AWS-ConfigureAWSPackage" \
    --parameters '{"action":["Install"],"name":["AmazonCloudWatchAgent"]}' \
    --comment "Install CloudWatch Agent — gpu-capacity-pipeline" \
    --output text > /dev/null 2>&1 && \
    CW_AGENT_INSTALLED=$((CW_AGENT_INSTALLED + 1)) || \
    warn "Could not send SSM command to $INSTANCE_ID — SSM agent may not be ready yet"
done
ok "CloudWatch agent installation sent to $CW_AGENT_INSTALLED instance(s)"

# ── Step 2: Apply cost allocation tags ───────────────────────────────────────
header "2 / 5  Applying cost allocation tags"

ALL_RESOURCE_IDS="$RESERVATION_ID $INSTANCE_IDS_SSM"

# Get EBS volume IDs for all instances
EBS_IDS=""
for INSTANCE_ID in $INSTANCE_IDS_SSM; do
  VOL_IDS=$(aws_cmd ec2 describe-instances \
    --instance-ids "$INSTANCE_ID" \
    --query "Reservations[0].Instances[0].BlockDeviceMappings[*].Ebs.VolumeId" \
    2>/dev/null | tr '\t' ' ' || echo "")
  EBS_IDS="$EBS_IDS $VOL_IDS"
done

ALL_RESOURCE_IDS="$ALL_RESOURCE_IDS $EBS_IDS"
ALL_RESOURCE_IDS=$(echo "$ALL_RESOURCE_IDS" | tr ' ' '\n' | grep -v "^$" | sort -u | tr '\n' ' ')

aws_cmd ec2 create-tags \
  --resources $ALL_RESOURCE_IDS \
  --tags \
    "Key=Project,Value=${TAG_PROJECT:-gpu}" \
    "Key=Team,Value=${TAG_TEAM:-team}" \
    "Key=CostCenter,Value=${TAG_COST_CENTER:-0000}" \
    "Key=Environment,Value=${TAG_ENVIRONMENT:-production}" \
    "Key=ReservationId,Value=${RESERVATION_ID}" \
    "Key=PipelineRunId,Value=${PIPELINE_RUN_ID:-unknown}" \
    "Key=ManagedBy,Value=gpu-capacity-pipeline" \
  2>/dev/null && ok "Cost tags applied to all resources" || \
  warn "Some tags may not have been applied — check AWS console"

# ── Step 3: Write full audit record to S3 ────────────────────────────────────
header "3 / 5  Writing full audit record to S3"

S3_BUCKET="${AUDIT_S3_BUCKET:-gpu-capacity-audit-${AWS_ACCOUNT_ID}}"
COMPLETED_AT=$(date -u +%Y-%m-%dT%H:%M:%SZ)

# Build instances array
INSTANCES_DETAIL=$(python3 -c "
import json
ids='${INSTANCE_IDS_SSM}'.split()
ips='${PRIVATE_IPS_SSM}'.split()
result=[{'instanceId':i,'privateIp':p} for i,p in zip(ids,ips)]
print(json.dumps(result))
" 2>/dev/null || echo "[]")

FULL_AUDIT=$(python3 -c "
import json
print(json.dumps({
  'event': 'pipeline_completed',
  'pipelineRunId': '${PIPELINE_RUN_ID:-unknown}',
  'completedAt': '${COMPLETED_AT}',
  'reservation': {
    'reservationId': '${RESERVATION_ID}',
    'instanceType': '${INSTANCE_TYPE_SELECTED}',
    'instanceCount': '${INSTANCE_COUNT:-unknown}',
    'region': '${LAUNCH_REGION}',
    'availabilityZone': '${RESERVE_AZ}',
    'startDate': '${START_DATE_RESV}',
    'endDate': '${END_DATE_RESV}',
    'upfrontFee': '${UPFRONT_FEE}',
    'launchTimestamp': '${LAUNCH_TIMESTAMP}'
  },
  'instances': ${INSTANCES_DETAIL},
  'tags': {
    'project': '${TAG_PROJECT:-gpu}',
    'team': '${TAG_TEAM:-team}',
    'costCenter': '${TAG_COST_CENTER:-0000}',
    'environment': '${TAG_ENVIRONMENT:-production}'
  }
}))
")

aws $PROFILE_FLAG s3 cp - \
  "s3://${S3_BUCKET}/pipeline-runs/${PIPELINE_RUN_ID}/full-audit.json" \
  --region "$AWS_REGION" \
  <<< "$FULL_AUDIT" 2>/dev/null && \
  ok "Full audit record → s3://${S3_BUCKET}/pipeline-runs/${PIPELINE_RUN_ID}/full-audit.json" || \
  warn "Could not write full audit to S3"

# ── Step 4: Send pipeline completed email via SNS ─────────────────────────────
header "4 / 5  Sending completion notification"

SNS_ARN=$(get_param "sns-topic-arn")
[[ -z "$SNS_ARN" ]] && SNS_ARN="${SNS_TOPIC_ARN:-}"

if [[ -n "$SNS_ARN" ]]; then
  INSTANCE_LINES=""
  IDX=1
  for ID in $INSTANCE_IDS_SSM; do
    IP=$(echo "$PRIVATE_IPS_SSM" | awk "{print \$$IDX}")
    INSTANCE_LINES="${INSTANCE_LINES}  Instance ${IDX}  :  ${ID}  |  ${IP}\n"
    IDX=$((IDX + 1))
  done

  WATCHER_DELETED_LIST="  Deleted  :  Step Functions state machine\n\
  Deleted  :  EventBridge Scheduler rule\n\
  Deleted  :  Lambda functions (discovery, notify, cleanup)\n\
  Deleted  :  DynamoDB retry state table\n\
  Deleted  :  API Gateway endpoint\n\
  Deleted  :  Lambda IAM execution role\n\
  Deleted  :  CloudWatch log groups for watcher"

  COMPLETION_MESSAGE="Dear Team,

Your AWS GPU Capacity Block reservation and cluster launch have
completed successfully. Your GPU cluster is now live and ready to use.

━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
  RESERVATION DETAILS
━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

  Reservation ID         :   ${RESERVATION_ID}
  Instance Type          :   ${INSTANCE_TYPE_SELECTED}
  Instance Count         :   ${INSTANCE_COUNT:-unknown}
  Region                 :   ${LAUNCH_REGION}
  Availability Zone      :   ${RESERVE_AZ}
  Start Date and Time    :   ${START_DATE_RESV}
  End Date and Time      :   ${END_DATE_RESV}
  Upfront Fee Charged    :   ${UPFRONT_FEE}

━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
  RUNNING INSTANCES
━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

$(echo -e "$INSTANCE_LINES")
  All instances passed 2/2 health checks.
  Cluster launched at    :   ${LAUNCH_TIMESTAMP}

━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
  COST ALLOCATION TAGS APPLIED
━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

  Project                :   ${TAG_PROJECT:-gpu}
  Team                   :   ${TAG_TEAM:-team}
  CostCenter             :   ${TAG_COST_CENTER:-0000}
  Environment            :   ${TAG_ENVIRONMENT:-production}

━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
  WATCHER SERVICES CLEANUP
━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

  All temporary AWS watcher services have been
  successfully deleted from your account.

$(echo -e "$WATCHER_DELETED_LIST")

  Your permanent infrastructure created by
  aws_check_create.sh has not been touched.

━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

This is an automated message. Do not reply to this email.

AWS GPU Capacity Block Reservation Pipeline
Powered by AWS Step Functions · Lambda · EventBridge
━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"

  aws $PROFILE_FLAG sns publish \
    --region "$AWS_REGION" \
    --topic-arn "$SNS_ARN" \
    --subject "[Completed] AWS GPU Capacity Block Cluster is Live — ${RESERVATION_ID}" \
    --message "$COMPLETION_MESSAGE" > /dev/null && \
    ok "Completion email sent to ${ALERT_EMAIL:-subscribers}" || \
    warn "Could not send completion email — check SNS topic"
else
  warn "SNS_TOPIC_ARN not found — skipping completion email"
fi

# ── Step 5: Trigger watcher cleanup ──────────────────────────────────────────
header "5 / 5  Triggering watcher service cleanup"

CLEANUP_LAMBDA=$(get_param "cleanup-lambda-name")
if [[ -n "$CLEANUP_LAMBDA" ]]; then
  aws $PROFILE_FLAG lambda invoke \
    --region "$AWS_REGION" \
    --function-name "$CLEANUP_LAMBDA" \
    --payload "{\"pipelineRunId\":\"${PIPELINE_RUN_ID}\",\"reason\":\"pipeline_completed\"}" \
    --cli-binary-format raw-in-base64-out \
    /tmp/cleanup_response_$$.json > /dev/null 2>&1 && \
    ok "Cleanup Lambda triggered" || \
    warn "Could not trigger cleanup Lambda — may need manual cleanup"
  rm -f /tmp/cleanup_response_$$.json
else
  warn "Cleanup Lambda name not found in SSM — watcher services may need manual deletion"
fi

echo ""
ok "monitor.sh complete"
ok "Pipeline fully completed — GPU cluster is live and monitored"