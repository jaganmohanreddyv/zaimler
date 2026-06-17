#!/usr/bin/env bash
# -- Windows Git Bash path fix ------------------------------------------------
export MSYS_NO_PATHCONV=1
export MSYS2_ARG_CONV_EXCL="*"
# =============================================================================
# launch.sh — Launch GPU Instances into the Reserved Capacity Block
# Called by Step Functions Lambda after reserve.sh completes
# =============================================================================

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CONFIG_FILE="${SCRIPT_DIR}/config.env"

CLEAN_ENV="/tmp/config_clean_launch_$$.env"
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
aws_safe() { aws_cmd "$@" 2>/dev/null || true; }

# ── Step 1: Read reservation details ─────────────────────────────────────────
header "1 / 5  Reading reservation details"

RESERVATION_ID=$(get_param "reservation-id")
[[ -z "$RESERVATION_ID" ]] && RESERVATION_ID="${CAPACITY_RESERVATION_ID:-}"
[[ -z "$RESERVATION_ID" ]] && { fail "No CAPACITY_RESERVATION_ID found in SSM or config.env"; exit 1; }

ok "Reservation ID: $RESERVATION_ID"
info "Launch region : $LAUNCH_REGION"

# ── Step 2: Wait for reservation to be active ─────────────────────────────────
header "2 / 5  Waiting for reservation to become active"

MAX_WAIT_ACTIVE=120
POLL_INTERVAL=30
WAITED=0

while [[ $WAITED -lt $MAX_WAIT_ACTIVE ]]; do
  RESV_STATE=$(aws_safe ec2 describe-capacity-reservations \
    --capacity-reservation-ids "$RESERVATION_ID" \
    --query "CapacityReservations[0].State" || echo "unknown")

  info "Reservation state: $RESV_STATE (waited ${WAITED}m / ${MAX_WAIT_ACTIVE}m)"

  [[ "$RESV_STATE" == "active" ]] && { ok "Reservation is active. Proceeding to launch."; break; }
  [[ "$RESV_STATE" == "cancelled" || "$RESV_STATE" == "failed" || "$RESV_STATE" == "expired" ]] && {
    fail "Reservation entered unexpected state: $RESV_STATE"
    exit 1
  }

  info "Reservation not yet active — waiting ${POLL_INTERVAL} seconds..."
  sleep $POLL_INTERVAL
  WAITED=$((WAITED + 1))
done

[[ $WAITED -ge $MAX_WAIT_ACTIVE ]] && {
  fail "Reservation did not become active within ${MAX_WAIT_ACTIVE} minutes."
  exit 1
}

# ── Step 3: Launch GPU instances ──────────────────────────────────────────────
header "3 / 5  Launching GPU instances"

LT_ID="${LAUNCH_TEMPLATE_ID:-}"
[[ -z "$LT_ID" ]] && LT_ID=$(aws_safe ec2 describe-launch-templates \
  --launch-template-names "${LAUNCH_TEMPLATE_NAME:-gpu-cb-lt}" \
  --query "LaunchTemplates[0].LaunchTemplateId")

[[ -z "$LT_ID" || "$LT_ID" == "None" ]] && {
  fail "Launch template not found. Check LAUNCH_TEMPLATE_NAME or LAUNCH_TEMPLATE_ID in config.env"
  exit 1
}

info "Using launch template: $LT_ID"

# ── Pick correct subnet for the selected AZ ───────────────────────────────────
# The launch template has one subnet (AZ1). If user chose a different AZ via
# email, we must override the subnet to match the capacity reservation AZ.
# Read AZ list from config.env to find which subnet index to use.
SELECTED_AZ=$(get_param "az")
SELECTED_AZ="${SELECTED_AZ:-}"

LAUNCH_SUBNET_OVERRIDE=""
if [[ -n "$SELECTED_AZ" ]]; then
  # Build AZ → subnet map from config.env
  IFS=',' read -ra _AZ_LIST   <<< "${AVAILABILITY_ZONES:-}"
  # Subnet list: first entry = SUBNET_ID, subsequent = SUBNET_ID_AZ2, SUBNET_ID_AZ3 ...
  _SUBNET_LIST=("${SUBNET_ID:-}")
  [[ -n "${SUBNET_ID_AZ2:-}" ]] && _SUBNET_LIST+=("${SUBNET_ID_AZ2}")
  [[ -n "${SUBNET_ID_AZ3:-}" ]] && _SUBNET_LIST+=("${SUBNET_ID_AZ3}")

  for _i in "${!_AZ_LIST[@]}"; do
    _AZ_ENTRY=$(echo "${_AZ_LIST[$_i]}" | tr -d ' ')
    if [[ "$_AZ_ENTRY" == "$SELECTED_AZ" ]]; then
      LAUNCH_SUBNET_OVERRIDE="${_SUBNET_LIST[$_i]:-}"
      break
    fi
  done
fi

if [[ -n "$LAUNCH_SUBNET_OVERRIDE" ]]; then
  info "Subnet override for AZ $SELECTED_AZ : $LAUNCH_SUBNET_OVERRIDE"
else
  info "No subnet override — using launch template default subnet"
fi

# Build the run-instances command
# If we have a subnet override, pass it via --network-interfaces to replace
# the subnet baked into the launch template
SUBNET_ARGS=""
if [[ -n "$LAUNCH_SUBNET_OVERRIDE" ]]; then
  SUBNET_ARGS="--network-interfaces DeviceIndex=0,SubnetId=${LAUNCH_SUBNET_OVERRIDE},Groups=${SECURITY_GROUP_IDS:-},InterfaceType=efa,DeleteOnTermination=true"
fi

INSTANCE_IDS_JSON=$(aws $PROFILE_FLAG ec2 run-instances \
  --region "$LAUNCH_REGION" \
  --launch-template "LaunchTemplateId=${LT_ID},Version=\$Latest" \
  --count "${INSTANCE_COUNT:-1}" \
  ${SUBNET_ARGS} \
  --tag-specifications \
    "ResourceType=instance,Tags=[\
{Key=Name,Value=gpu-capacity-block-instance},\
{Key=Project,Value=${TAG_PROJECT:-gpu}},\
{Key=Team,Value=${TAG_TEAM:-team}},\
{Key=CostCenter,Value=${TAG_COST_CENTER:-0000}},\
{Key=Environment,Value=${TAG_ENVIRONMENT:-production}},\
{Key=ReservationId,Value=${RESERVATION_ID}},\
{Key=PipelineRunId,Value=${PIPELINE_RUN_ID:-unknown}},\
{Key=CreatedBy,Value=gpu-capacity-pipeline}\
]" \
  --query "Instances[*].InstanceId" \
  --output json 2>&1) || {
  fail "ec2 run-instances failed: $INSTANCE_IDS_JSON"
  exit 1
}

INSTANCE_IDS=$(echo "$INSTANCE_IDS_JSON" | python3 -c "import sys,json; print(' '.join(json.load(sys.stdin)))")
INSTANCE_COUNT_LAUNCHED=$(echo "$INSTANCE_IDS" | wc -w | tr -d ' ')

ok "$INSTANCE_COUNT_LAUNCHED instances launched"
for ID in $INSTANCE_IDS; do info "  Instance: $ID"; done

# ── Step 4: Wait for 2/2 health checks ───────────────────────────────────────
header "4 / 5  Waiting for health checks (2/2) on all instances"

MAX_HEALTH_RETRIES=40
HEALTH_INTERVAL=15
RETRY=0
ALL_HEALTHY=false

while [[ $RETRY -lt $MAX_HEALTH_RETRIES ]]; do
  HEALTHY_COUNT=0
  for INSTANCE_ID in $INSTANCE_IDS; do
    STATUS=$(aws_safe ec2 describe-instance-status \
      --instance-ids "$INSTANCE_ID" \
      --query "InstanceStatuses[0].[InstanceStatus.Status,SystemStatus.Status]" || echo "unknown unknown")
    INST_STATUS=$(echo "$STATUS" | awk '{print $1}')
    SYS_STATUS=$(echo "$STATUS"  | awk '{print $2}')
    [[ "$INST_STATUS" == "ok" && "$SYS_STATUS" == "ok" ]] && HEALTHY_COUNT=$((HEALTHY_COUNT + 1))
  done

  info "Health checks: $HEALTHY_COUNT / $INSTANCE_COUNT_LAUNCHED passed (retry $RETRY/$MAX_HEALTH_RETRIES)"

  [[ $HEALTHY_COUNT -eq $INSTANCE_COUNT_LAUNCHED ]] && { ALL_HEALTHY=true; break; }
  sleep $HEALTH_INTERVAL
  RETRY=$((RETRY + 1))
done

[[ "$ALL_HEALTHY" == false ]] && {
  warn "Not all instances passed health checks within timeout."
  warn "Proceeding — check AWS console for instance status."
}

ok "All $INSTANCE_COUNT_LAUNCHED instances passed 2/2 health checks."

# ── Step 5: Collect IPs and save everything ───────────────────────────────────
header "5 / 5  Saving instance details"

LAUNCH_TIMESTAMP=$(date -u +%Y-%m-%dT%H:%M:%SZ)
PRIVATE_IPS=""

for INSTANCE_ID in $INSTANCE_IDS; do
  PRIVATE_IP=$(aws_safe ec2 describe-instances \
    --instance-ids "$INSTANCE_ID" \
    --query "Reservations[0].Instances[0].PrivateIpAddress")
  PRIVATE_IPS="${PRIVATE_IPS} ${PRIVATE_IP}"
  info "  $INSTANCE_ID → $PRIVATE_IP"
done

PRIVATE_IPS=$(echo "$PRIVATE_IPS" | xargs)

# Save to SSM
aws $PROFILE_FLAG ssm put-parameter --region "$AWS_REGION" \
  --name "${SSM_PREFIX}/instance-ids" --value "$INSTANCE_IDS" \
  --type "String" --overwrite > /dev/null

aws $PROFILE_FLAG ssm put-parameter --region "$AWS_REGION" \
  --name "${SSM_PREFIX}/private-ips" --value "$PRIVATE_IPS" \
  --type "String" --overwrite > /dev/null

aws $PROFILE_FLAG ssm put-parameter --region "$AWS_REGION" \
  --name "${SSM_PREFIX}/launch-timestamp" --value "$LAUNCH_TIMESTAMP" \
  --type "String" --overwrite > /dev/null

# Patch config.env
TS=$(date +%Y%m%d_%H%M%S)
cp "$CONFIG_FILE" "${CONFIG_FILE}.bak.${TS}"
IDS_COMMA=$(echo "$INSTANCE_IDS" | tr ' ' ',')
sed -i "s|^INSTANCE_IDS=.*|INSTANCE_IDS=\"${IDS_COMMA}\"|" "$CONFIG_FILE"
sed -i "s|^LAUNCH_TIMESTAMP=.*|LAUNCH_TIMESTAMP=\"${LAUNCH_TIMESTAMP}\"|" "$CONFIG_FILE"

# Write S3 audit record
S3_BUCKET="${AUDIT_S3_BUCKET:-gpu-capacity-audit-${AWS_ACCOUNT_ID}}"
INSTANCES_JSON=$(python3 -c "
import json
ids='${INSTANCE_IDS}'.split()
ips='${PRIVATE_IPS}'.split()
print(json.dumps([{'instanceId': i, 'privateIp': p} for i,p in zip(ids,ips)]))
")

AUDIT_PAYLOAD=$(python3 -c "
import json
print(json.dumps({
  'event': 'instances_launched',
  'pipelineRunId': '${PIPELINE_RUN_ID:-unknown}',
  'reservationId': '${RESERVATION_ID}',
  'instanceCount': ${INSTANCE_COUNT_LAUNCHED},
  'instances': ${INSTANCES_JSON},
  'launchTimestamp': '${LAUNCH_TIMESTAMP}',
  'region': '${LAUNCH_REGION}'
}))
")

aws $PROFILE_FLAG s3 cp - \
  "s3://${S3_BUCKET}/launches/${RESERVATION_ID}/launch.json" \
  --region "$AWS_REGION" \
  <<< "$AUDIT_PAYLOAD" 2>/dev/null && \
  ok "Audit record saved to S3" || \
  warn "Could not write to S3 audit bucket"

echo ""
ok "launch.sh complete"
ok "Instances running: $INSTANCE_IDS"
ok "Private IPs: $PRIVATE_IPS"
echo "$INSTANCE_IDS"