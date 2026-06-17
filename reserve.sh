#!/usr/bin/env bash
# -- Windows Git Bash path fix ------------------------------------------------
export MSYS_NO_PATHCONV=1
export MSYS2_ARG_CONV_EXCL="*"
# =============================================================================
# reserve.sh — Purchase the AWS Capacity Block
# Called by Step Functions Lambda after user clicks CONFIRM in email
# Parameters passed as environment variables from Step Functions
# =============================================================================

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CONFIG_FILE="${SCRIPT_DIR}/config.env"

CLEAN_ENV="/tmp/config_clean_reserve_$$.env"
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

aws_cmd()  { aws $PROFILE_FLAG --region "${RESERVE_REGION:-$AWS_REGION}" --output text "$@"; }
aws_safe() { aws_cmd "$@" 2>/dev/null || true; }

# ── Read approved offering details from SSM Parameter Store ───────────────────
header "1 / 6  Reading approved offering from SSM"

PIPELINE_RUN_ID="${PIPELINE_RUN_ID:-}"
SSM_PREFIX="/gpu-capacity-pipeline/${PIPELINE_RUN_ID}"

get_param() {
  aws $PROFILE_FLAG ssm get-parameter \
    --region "$AWS_REGION" \
    --name "${SSM_PREFIX}/$1" \
    --query "Parameter.Value" \
    --output text 2>/dev/null || echo ""
}

OFFERING_ID=$(get_param "offering-id")
RESERVE_REGION=$(get_param "region")
RESERVE_AZ=$(get_param "az")
INSTANCE_TYPE_SELECTED=$(get_param "instance-type")
RESERVE_COUNT=$(get_param "instance-count")
UPFRONT_FEE=$(get_param "upfront-fee")
RESERVE_START=$(get_param "start-date")
RESERVE_END=$(get_param "end-date")

[[ -z "$OFFERING_ID" ]] && { fail "No offering ID found in SSM at ${SSM_PREFIX}/offering-id"; exit 1; }

ok "Offering ID : $OFFERING_ID"
info "Region      : $RESERVE_REGION"
info "AZ          : $RESERVE_AZ"
info "Type        : $INSTANCE_TYPE_SELECTED"
info "Count       : $RESERVE_COUNT"
info "Fee         : $UPFRONT_FEE"
info "Start       : $RESERVE_START"
info "End         : $RESERVE_END"

# ── Purchase the Capacity Block ───────────────────────────────────────────────
header "2 / 6  Purchasing Capacity Block"

RESERVATION_ID=$(aws $PROFILE_FLAG ec2 purchase-capacity-block \
  --region "$RESERVE_REGION" \
  --capacity-block-offering-id "$OFFERING_ID" \
  --instance-platform "Linux/UNIX" \
  --tag-specifications \
    "ResourceType=capacity-reservation,Tags=[\
{Key=Name,Value=gpu-capacity-block},\
{Key=Project,Value=${TAG_PROJECT:-gpu}},\
{Key=Team,Value=${TAG_TEAM:-team}},\
{Key=CostCenter,Value=${TAG_COST_CENTER:-0000}},\
{Key=Environment,Value=${TAG_ENVIRONMENT:-production}},\
{Key=PipelineRunId,Value=${PIPELINE_RUN_ID:-unknown}},\
{Key=CreatedBy,Value=gpu-capacity-pipeline}\
]" \
  --query "CapacityReservation.CapacityReservationId" \
  --output text 2>&1) || {
  fail "Failed to purchase Capacity Block: $RESERVATION_ID"
  # Notify via SNS
  SNS_ARN=$(get_param "sns-topic-arn")
  [[ -n "$SNS_ARN" ]] && aws $PROFILE_FLAG sns publish \
    --region "$AWS_REGION" \
    --topic-arn "$SNS_ARN" \
    --subject "[FAILED] AWS Capacity Block Purchase Failed" \
    --message "Pipeline ${PIPELINE_RUN_ID} failed to purchase Capacity Block $OFFERING_ID. Error: $RESERVATION_ID" \
    > /dev/null 2>&1 || true
  exit 1
}

ok "Reservation ID: $RESERVATION_ID"

# ── Verify reservation state ──────────────────────────────────────────────────
header "3 / 6  Verifying reservation"

MAX_VERIFY=10
for i in $(seq 1 $MAX_VERIFY); do
  RESV_STATE=$(aws_safe ec2 describe-capacity-reservations \
    --capacity-reservation-ids "$RESERVATION_ID" \
    --query "CapacityReservations[0].State" || echo "unknown")
  info "Reservation state: $RESV_STATE (check $i/$MAX_VERIFY)"
  [[ "$RESV_STATE" == "active" || "$RESV_STATE" == "scheduled" ]] && break
  [[ "$RESV_STATE" == "cancelled" || "$RESV_STATE" == "failed" ]] && {
    fail "Reservation entered $RESV_STATE state immediately after purchase"
    exit 1
  }
  sleep 5
done
ok "Reservation confirmed — state: $RESV_STATE"

# ── Update launch template with reservation ID ────────────────────────────────
header "4 / 6  Updating launch template"

LT_ID="${LAUNCH_TEMPLATE_ID:-}"
[[ -z "$LT_ID" ]] && LT_ID=$(aws_safe ec2 describe-launch-templates \
  --launch-template-names "${LAUNCH_TEMPLATE_NAME:-gpu-cb-lt}" \
  --query "LaunchTemplates[0].LaunchTemplateId" || echo "")

[[ -z "$LT_ID" || "$LT_ID" == "None" ]] && {
  warn "Launch template not found — skipping update. Set LAUNCH_TEMPLATE_ID in config.env"
} || {
  # FIXED: avoid file:///tmp/ path — MSYS path conversion mangles it on Windows Git Bash
  # Use Python zipfile-style inline JSON via --cli-input-json instead
  LT_UPDATE_JSON=$(python3 -c "
import json
print(json.dumps({
  'LaunchTemplateId': '${LT_ID}',
  'SourceVersion': '\$Latest',
  'VersionDescription': 'Targeting Capacity Block ${RESERVATION_ID}',
  'LaunchTemplateData': {
    'CapacityReservationSpecification': {
      'CapacityReservationPreference': 'none',
      'CapacityReservationTarget': {
        'CapacityReservationId': '${RESERVATION_ID}'
      }
    }
  }
}))
")

  NEW_LT_VERSION=$(aws $PROFILE_FLAG ec2 create-launch-template-version \
    --region "$RESERVE_REGION" \
    --cli-input-json "$LT_UPDATE_JSON" \
    --query "LaunchTemplateVersion.VersionNumber" \
    --output text)

  # Default version NOT updated — pipeline always uses $Latest
  ok "Launch template $LT_ID updated — new \$Latest v${NEW_LT_VERSION} targets ${RESERVATION_ID}"
}

# ── Write reservation ID to SSM and config.env ────────────────────────────────
header "5 / 6  Persisting reservation details"

aws $PROFILE_FLAG ssm put-parameter \
  --region "$AWS_REGION" \
  --name "${SSM_PREFIX}/reservation-id" \
  --value "$RESERVATION_ID" \
  --type "String" \
  --overwrite > /dev/null

aws $PROFILE_FLAG ssm put-parameter \
  --region "$AWS_REGION" \
  --name "${SSM_PREFIX}/reservation-region" \
  --value "$RESERVE_REGION" \
  --type "String" \
  --overwrite > /dev/null

# Patch config.env
TS=$(date +%Y%m%d_%H%M%S)
cp "$CONFIG_FILE" "${CONFIG_FILE}.bak.${TS}"
sed -i "s|^CAPACITY_RESERVATION_ID=.*|CAPACITY_RESERVATION_ID=\"${RESERVATION_ID}\"|" "$CONFIG_FILE"
ok "Reservation ID written to config.env and SSM"

# ── Write S3 audit record ─────────────────────────────────────────────────────
header "6 / 6  Writing audit record to S3"

AUDIT_PAYLOAD=$(python3 -c "
import json, sys
print(json.dumps({
  'event': 'capacity_block_purchased',
  'pipelineRunId': '${PIPELINE_RUN_ID:-unknown}',
  'reservationId': '${RESERVATION_ID}',
  'offeringId': '${OFFERING_ID}',
  'instanceType': '${INSTANCE_TYPE_SELECTED}',
  'instanceCount': '${RESERVE_COUNT}',
  'region': '${RESERVE_REGION}',
  'availabilityZone': '${RESERVE_AZ}',
  'startDate': '${RESERVE_START}',
  'endDate': '${RESERVE_END}',
  'upfrontFee': '${UPFRONT_FEE}',
  'purchasedAt': '$(date -u +%Y-%m-%dT%H:%M:%SZ)',
  'tags': {
    'project': '${TAG_PROJECT:-gpu}',
    'team': '${TAG_TEAM:-team}',
    'costCenter': '${TAG_COST_CENTER:-0000}',
    'environment': '${TAG_ENVIRONMENT:-production}'
  }
}))
")

S3_BUCKET="${AUDIT_S3_BUCKET:-gpu-capacity-audit-${AWS_ACCOUNT_ID}}"
S3_KEY="reservations/${RESERVATION_ID}/purchase.json"

aws $PROFILE_FLAG s3 cp - "s3://${S3_BUCKET}/${S3_KEY}" \
  --region "$AWS_REGION" \
  <<< "$AUDIT_PAYLOAD" 2>/dev/null && \
  ok "Audit record → s3://${S3_BUCKET}/${S3_KEY}" || \
  warn "Could not write to S3 audit bucket — check bucket exists"

echo ""
ok "reserve.sh complete — Reservation ID: $RESERVATION_ID"
echo "$RESERVATION_ID"