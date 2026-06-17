#!/usr/bin/env bash
# =============================================================================
# cleanup_infra.sh
# Deletes ONLY the resources created by aws_check_create.sh — nothing else.
#
# WHAT IT READS — config.env keys written by aws_check_create.sh:
#   KEY_PAIR_NAME         → EC2 key pair
#   SUBNET_ID             → EC2 subnet
#   SECURITY_GROUP_IDS    → EC2 security group(s)
#   PLACEMENT_GROUP_NAME  → EC2 cluster placement group
#   IAM_INSTANCE_PROFILE  → IAM instance profile  + role (name: <profile>-role)
#   SNS_TOPIC_NAME        → SNS topic + all subscriptions
#   LAUNCH_TEMPLATE_NAME  → EC2 launch template (ALL versions including those
#   LAUNCH_TEMPLATE_ID      added by reserve.sh — the template itself belongs
#                           to aws_check_create.sh)
#   (hardcoded)           → CloudWatch alarm: gpu-capacity-block-expiry-reminder
#   (hardcoded)           → IAM managed policy: gpu-deployment-permissions
#                           (detach from user + delete all versions + delete policy)
#                           Also removes old inline policy remnant if present.
#
# WHAT IT NEVER TOUCHES — created by other scripts:
#   reserve.sh        → Capacity Block reservation, SSM parameters
#   launch.sh         → EC2 instances, SSM parameters
#   monitor.sh        → Tags on resources (no new resources created)
#   deploy_watcher.sh → Lambda, DynamoDB, API GW, Step Functions, EventBridge,
#                       IAM watcher roles (all named gpu-watcher-*)
#
# USAGE:
#   bash cleanup_infra.sh             interactive — type DELETE to confirm
#   bash cleanup_infra.sh --dry-run   show what would be deleted, touch nothing
#   bash cleanup_infra.sh --force     skip confirmation (CI / automated testing)
# =============================================================================

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CONFIG_FILE="${SCRIPT_DIR}/config.env"

# ── Flags ─────────────────────────────────────────────────────────────────────
DRY_RUN=false
FORCE=false
for arg in "$@"; do
  [[ "$arg" == "--dry-run" ]] && DRY_RUN=true
  [[ "$arg" == "--force"   ]] && FORCE=true
done

# ── Colors ────────────────────────────────────────────────────────────────────
RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'
CYAN='\033[0;36m'; BOLD='\033[1m'; NC='\033[0m'

ok()     { echo -e "${GREEN}    ✔  $*${NC}"; }
skip()   { echo -e "    ⬜  $*"; }
warn()   { echo -e "${YELLOW}    ⚠  $*${NC}"; }
fail()   { echo -e "${RED}    ✖  $*${NC}"; }
step()   { echo -e "\n${BOLD}  [$1/9]  $2${NC}"; }
dr()     { echo -e "${CYAN}    [DRY-RUN] would delete: $*${NC}"; }

echo ""
echo -e "${BOLD}╔══════════════════════════════════════════════════════════╗${NC}"
echo -e "${BOLD}║   Infrastructure Cleanup — aws_check_create.sh resources  ║${NC}"
echo -e "${BOLD}╚══════════════════════════════════════════════════════════╝${NC}"
echo ""
[[ "$DRY_RUN" == true ]] && \
  echo -e "${CYAN}  [DRY-RUN] Nothing will be deleted${NC}\n"

# ── Load config.env ───────────────────────────────────────────────────────────
[[ ! -f "$CONFIG_FILE" ]] && {
  echo -e "${RED}  ✖  config.env not found at $CONFIG_FILE${NC}"; exit 1
}
CLEAN="/tmp/tc_$$.env"
sed 's/\r//' "$CONFIG_FILE" > "$CLEAN"
set +u; source "$CLEAN"; set -u
rm -f "$CLEAN"

REGION="${AWS_REGION:-us-east-1}"
PROFILE_FLAG=""
[[ -n "${AWS_PROFILE:-}" ]] && PROFILE_FLAG="--profile ${AWS_PROFILE}"

# ── Scoped AWS helpers ────────────────────────────────────────────────────────
# These helpers only call the services that aws_check_create.sh used.
# No Lambda, DynamoDB, Step Functions, EventBridge, API Gateway calls here.
_ec2() { aws $PROFILE_FLAG --region "$REGION" --output text ec2 "$@" 2>/dev/null || true; }
_iam() { aws $PROFILE_FLAG --output text iam "$@" 2>/dev/null || true; }
_sns() { aws $PROFILE_FLAG --region "$REGION" --output text sns "$@" 2>/dev/null || true; }
_cw()  { aws $PROFILE_FLAG --region "$REGION" --output text cloudwatch "$@" 2>/dev/null || true; }

# ── Tracking ──────────────────────────────────────────────────────────────────
DELETED=(); SKIPPED=(); ERRORS=()
did_delete() { DELETED+=("$1"); ok "Deleted  :  $1"; }
did_skip()   { SKIPPED+=("$1"); skip "Not found — skipped: $1"; }
did_error()  { ERRORS+=("$1");  fail "Could not delete: $1"; }

# ── Wipe a key in config.env safely ──────────────────────────────────────────
wipe() {
  local key="$1"
  # Only wipes keys that aws_check_create.sh owns — hardcoded list below
  local OWNED_KEYS=(
    KEY_PAIR_NAME
    SUBNET_ID
    AVAILABILITY_ZONE
    SECURITY_GROUP_IDS
    PLACEMENT_GROUP_NAME
    IAM_INSTANCE_PROFILE
    SNS_TOPIC_NAME
    SNS_TOPIC_ARN
    LAUNCH_TEMPLATE_NAME
    LAUNCH_TEMPLATE_ID
  )
  local allowed=false
  for k in "${OWNED_KEYS[@]}"; do
    [[ "$k" == "$key" ]] && allowed=true && break
  done
  if [[ "$allowed" == false ]]; then
    warn "wipe() blocked attempt to clear '$key' — not owned by aws_check_create.sh"
    return
  fi
  grep -q "^${key}=" "$CONFIG_FILE" 2>/dev/null && \
    sed -i "s|^${key}=.*|${key}=\"\"|" "$CONFIG_FILE" || true
}

# ── Trap for temp files ───────────────────────────────────────────────────────
CLEANUP_FILES=()
trap 'rm -f "${CLEANUP_FILES[@]}" 2>/dev/null || true' EXIT

# ── Credentials ───────────────────────────────────────────────────────────────
echo "  Verifying AWS credentials..."
ACCOUNT_ID=$(aws $PROFILE_FLAG sts get-caller-identity \
  --query "Account" --output text 2>&1) || {
  fail "Credentials not configured or expired."; exit 1
}
CALLER_ARN=$(aws $PROFILE_FLAG sts get-caller-identity \
  --query "Arn" --output text 2>/dev/null || echo "")
CALLER_USER=""
[[ "$CALLER_ARN" == *":user/"* ]] && CALLER_USER="${CALLER_ARN##*/}"

echo -e "  Account  : ${CYAN}${ACCOUNT_ID}${NC}"
echo -e "  Region   : ${CYAN}${REGION}${NC}"
echo ""

# ── Read the 9 keys aws_check_create.sh owns ─────────────────────────────────
# These are the ONLY config.env keys this script reads.
# It does not read CAPACITY_RESERVATION_ID, INSTANCE_IDS, WATCHER_* or any
# key written by reserve.sh, launch.sh, monitor.sh, or deploy_watcher.sh.

CK_KEY_PAIR="${KEY_PAIR_NAME:-}"
CK_SUBNET="${SUBNET_ID:-}"
CK_SG="${SECURITY_GROUP_IDS:-}"
CK_PG="${PLACEMENT_GROUP_NAME:-}"
CK_PROFILE_ARN="${IAM_INSTANCE_PROFILE:-}"
CK_PROFILE_NAME="$(basename "$CK_PROFILE_ARN" 2>/dev/null || echo "")"
CK_ROLE_NAME="${CK_PROFILE_NAME}-role"
CK_SNS="${SNS_TOPIC_NAME:-}"
CK_LT_NAME="${LAUNCH_TEMPLATE_NAME:-}"
CK_LT_ID="${LAUNCH_TEMPLATE_ID:-}"
# These two are hardcoded in aws_check_create.sh — not stored in config.env
CK_CW_ALARM="gpu-capacity-block-expiry-reminder"
CK_IAM_POLICY="gpu-deployment-permissions"

# ── Pre-flight: show exactly what will be deleted ────────────────────────────
echo -e "  ${BOLD}Resources owned by aws_check_create.sh:${NC}"
echo ""
pr() {
  local label="$1" val="$2"
  [[ -n "$val" ]] && \
    echo -e "    ${RED}✖${NC}  ${BOLD}${label}${NC}  ${CYAN}${val}${NC}" || \
    echo -e "    ⬜  ${label}  (not set — will skip)"
}
pr "CloudWatch alarm     " "$CK_CW_ALARM"
pr "Launch template      " "${CK_LT_NAME}  ${CK_LT_ID:+(ID: $CK_LT_ID)}"
pr "IAM managed policy   " "${CK_IAM_POLICY}${CALLER_USER:+  (detach + delete, user: $CALLER_USER)}"
pr "SNS topic            " "$CK_SNS"
pr "IAM instance profile " "$CK_PROFILE_NAME"
pr "IAM role             " "$CK_ROLE_NAME"
pr "Placement group      " "$CK_PG"
pr "Security group(s)    " "$CK_SG"
pr "Subnet               " "$CK_SUBNET"
pr "Key pair             " "${CK_KEY_PAIR}  (.pem file removed too)"
echo ""
echo -e "  ${GREEN}${BOLD}Intentionally not touched by this script:${NC}"
echo -e "    ✅  Capacity Block reservation  (created by reserve.sh)"
echo -e "    ✅  EC2 instances               (created by launch.sh)"
echo -e "    ✅  SSM parameters              (created by reserve.sh / launch.sh)"
echo -e "    ✅  Watcher services            (Lambda / DynamoDB / Step Functions / EventBridge / API GW)"
echo -e "    ✅  VPC / IGW / route tables"
echo -e "    ✅  S3 audit bucket"
echo -e "    ✅  Default subnets"
echo ""

# ── Confirmation ──────────────────────────────────────────────────────────────
if [[ "$DRY_RUN" == false && "$FORCE" == false ]]; then
  echo -e "${RED}${BOLD}  ⚠  This will permanently delete the 9 resources above.${NC}"
  read -rp "  Type DELETE to confirm: " CONFIRM
  echo ""
  [[ "$CONFIRM" != "DELETE" ]] && {
    echo -e "${CYAN}  Aborted. Nothing deleted.${NC}"; exit 0
  }
  TS=$(date +%Y%m%d_%H%M%S)
  cp "$CONFIG_FILE" "${CONFIG_FILE}.pre-cleanup.${TS}"
  ok "config.env backed up → .pre-cleanup.${TS}"
fi

# =============================================================================
# STEP 1 — CloudWatch alarm
# Created by: aws_check_create.sh section 8/8
# Hardcoded name in that script: gpu-capacity-block-expiry-reminder
# =============================================================================
step 1 "CloudWatch alarm"

CW_EXISTS=$(_cw describe-alarms \
  --alarm-names "$CK_CW_ALARM" \
  --query "MetricAlarms[0].AlarmName")

if [[ -n "$CW_EXISTS" && "$CW_EXISTS" != "None" ]]; then
  [[ "$DRY_RUN" == true ]] && dr "cloudwatch delete-alarms $CK_CW_ALARM" || {
    _cw delete-alarms --alarm-names "$CK_CW_ALARM" && \
      did_delete "CloudWatch alarm: $CK_CW_ALARM" || \
      did_error  "CloudWatch alarm: $CK_CW_ALARM"
  }
else
  did_skip "CloudWatch alarm: $CK_CW_ALARM"
fi

# =============================================================================
# STEP 2 — Launch template  (the template — all versions)
# Created by: aws_check_create.sh section 7/8
# Config keys: LAUNCH_TEMPLATE_NAME, LAUNCH_TEMPLATE_ID
# Note: reserve.sh adds VERSIONS to this template but did NOT create the
#       template itself. Deleting the template removes all versions.
# =============================================================================
step 2 "Launch template (all versions)"

if [[ -n "$CK_LT_ID" || -n "$CK_LT_NAME" ]]; then
  LT_ARGS=()
  [[ -n "$CK_LT_ID" ]] && \
    LT_ARGS=(--launch-template-ids "$CK_LT_ID") || \
    LT_ARGS=(--launch-template-names "$CK_LT_NAME")

  LT_FOUND=$(_ec2 describe-launch-templates "${LT_ARGS[@]}" \
    --query "LaunchTemplates[0].LaunchTemplateId")

  if [[ -n "$LT_FOUND" && "$LT_FOUND" != "None" ]]; then
    # Confirm this template was created by aws_check_create.sh
    # by checking the LaunchedBy tag
    LT_TAG=$(_ec2 describe-launch-templates "${LT_ARGS[@]}" \
      --query "LaunchTemplates[0].Tags[?Key=='LaunchedBy'].Value" \
      | tr '\t' '\n' | head -1)

    if [[ "$LT_TAG" == "aws_check_create.sh" || -z "$LT_TAG" || "$LT_TAG" == "None" ]]; then
      # Tag matches, tag not present, or AWS returned None — safe to delete
      [[ "$DRY_RUN" == true ]] && \
        dr "ec2 delete-launch-template --launch-template-id $LT_FOUND (all versions)" || {
        _ec2 delete-launch-template \
          --launch-template-id "$LT_FOUND" && {
          did_delete "Launch template: ${CK_LT_NAME:-$CK_LT_ID} ($LT_FOUND) — all versions"
          wipe "LAUNCH_TEMPLATE_NAME"
          wipe "LAUNCH_TEMPLATE_ID"
        } || did_error "Launch template: $LT_FOUND"
      }
    else
      warn "Launch template $LT_FOUND has tag LaunchedBy=$LT_TAG — not from aws_check_create.sh"
      warn "Skipping to avoid deleting a template created by another process"
      did_skip "Launch template: $LT_FOUND (wrong LaunchedBy tag: $LT_TAG)"
    fi
  else
    did_skip "Launch template: ${CK_LT_NAME:-$CK_LT_ID} (not found in AWS)"
    wipe "LAUNCH_TEMPLATE_NAME"
    wipe "LAUNCH_TEMPLATE_ID"
  fi
else
  did_skip "Launch template: LAUNCH_TEMPLATE_NAME and LAUNCH_TEMPLATE_ID not set"
fi

# =============================================================================
# STEP 3 — IAM managed policy on caller user
# Created by: aws_check_create.sh section 6/8
# Hardcoded policy name: gpu-deployment-permissions
#
# aws_check_create.sh switched from inline user policy (put-user-policy) to a
# customer-managed policy (create-policy + attach-user-policy) because inline
# policies are capped at 2048 bytes — too small for all needed actions.
#
# Cleanup order:
#   A. Detach the managed policy from the user  (attach-user-policy is reversible)
#   B. Delete all non-default versions of the policy
#   C. Delete the managed policy itself
#   D. Backward-compat: also delete any lingering inline policy of the same name
# =============================================================================
step 3 "IAM managed policy: $CK_IAM_POLICY"

MANAGED_POLICY_ARN="arn:aws:iam::${ACCOUNT_ID}:policy/${CK_IAM_POLICY}"

if [[ -n "$CALLER_USER" ]]; then

  # ── A. Detach managed policy from user ──────────────────────────────────────
  ATTACHED=$(_iam list-attached-user-policies \
    --user-name "$CALLER_USER" \
    --query "AttachedPolicies[?PolicyName=='${CK_IAM_POLICY}'].PolicyArn" \
    | tr '\t' '\n' | grep "arn:" || echo "")

  if [[ -n "$ATTACHED" ]]; then
    [[ "$DRY_RUN" == true ]] && \
      dr "iam detach-user-policy --user-name $CALLER_USER --policy-arn $MANAGED_POLICY_ARN" || {
      _iam detach-user-policy \
        --user-name "$CALLER_USER" \
        --policy-arn "$MANAGED_POLICY_ARN" && \
        ok "    Detached $CK_IAM_POLICY from user $CALLER_USER" || \
        warn "    Could not detach — may already be detached"
    }
  else
    ok "    Policy not attached to $CALLER_USER — skipping detach"
  fi

  # ── B+C. Delete the managed policy (all versions then the policy itself) ────
  POLICY_EXISTS=$(_iam get-policy \
    --policy-arn "$MANAGED_POLICY_ARN" \
    --query "Policy.Arn" || echo "")

  if [[ -n "$POLICY_EXISTS" && "$POLICY_EXISTS" != "None" ]]; then
    [[ "$DRY_RUN" == true ]] && \
      dr "iam delete-policy (all versions) → $MANAGED_POLICY_ARN" || {

      # Delete all non-default versions first (AWS requires this before delete-policy)
      NON_DEFAULT_VERSIONS=$(_iam list-policy-versions \
        --policy-arn "$MANAGED_POLICY_ARN" \
        --query "Versions[?!IsDefaultVersion].VersionId" \
        | tr '\t' '\n' | grep -v "^$" || echo "")
      for VID in $NON_DEFAULT_VERSIONS; do
        _iam delete-policy-version \
          --policy-arn "$MANAGED_POLICY_ARN" \
          --version-id "$VID" 2>/dev/null || true
        ok "    Deleted policy version $VID"
      done

      _iam delete-policy --policy-arn "$MANAGED_POLICY_ARN" && \
        did_delete "IAM managed policy: $CK_IAM_POLICY ($MANAGED_POLICY_ARN)" || \
        did_error  "IAM managed policy: $CK_IAM_POLICY"
    }
  else
    did_skip "IAM managed policy: $CK_IAM_POLICY (not found in AWS)"
  fi

  # ── D. Backward-compat: also remove old inline policy if it still exists ────
  # Earlier runs of aws_check_create.sh used put-user-policy (inline).
  # If the inline version is still present alongside the managed one, remove it.
  OLD_INLINE=$(_iam list-user-policies \
    --user-name "$CALLER_USER" \
    --query "PolicyNames" \
    | tr '\t' '\n' | grep -x "$CK_IAM_POLICY" || echo "")

  if [[ -n "$OLD_INLINE" ]]; then
    [[ "$DRY_RUN" == true ]] && \
      dr "iam delete-user-policy (old inline remnant) $CK_IAM_POLICY on $CALLER_USER" || {
      _iam delete-user-policy \
        --user-name "$CALLER_USER" \
        --policy-name "$CK_IAM_POLICY" && \
        did_delete "IAM inline policy remnant: $CK_IAM_POLICY on $CALLER_USER (old version)" || \
        warn "Could not delete inline remnant — may need manual cleanup"
    }
  fi

else
  warn "Caller is not an IAM user ($CALLER_ARN)"
  warn "Manually detach and delete $CK_IAM_POLICY from your role or permission set"
  warn "  aws iam detach-user-policy --user-name <name> --policy-arn $MANAGED_POLICY_ARN"
  warn "  aws iam delete-policy --policy-arn $MANAGED_POLICY_ARN"
  SKIPPED+=("IAM managed policy: caller not an IAM user — manual action needed")
fi

# =============================================================================
# STEP 4 — SNS topic + all subscriptions
# Created by: aws_check_create.sh section 5/8
# Config key: SNS_TOPIC_NAME
# =============================================================================
step 4 "SNS topic and subscriptions"

if [[ -n "$CK_SNS" ]]; then
  SNS_ARN=$(_sns list-topics \
    --query "Topics[].TopicArn" \
    | tr '\t' '\n' | grep ":${CK_SNS}$" || echo "")

  if [[ -n "$SNS_ARN" ]]; then
    [[ "$DRY_RUN" == true ]] && \
      dr "sns delete-topic $CK_SNS (+ all subscriptions)" || {

      # Unsubscribe all confirmed subscriptions first
      SUB_COUNT=0
      SUBS=$(_sns list-subscriptions-by-topic \
        --topic-arn "$SNS_ARN" \
        --query "Subscriptions[*].SubscriptionArn" \
        | tr '\t' '\n' | grep "arn:" || echo "")
      for S in $SUBS; do
        _sns unsubscribe --subscription-arn "$S" 2>/dev/null || true
        SUB_COUNT=$((SUB_COUNT + 1))
      done
      [[ $SUB_COUNT -gt 0 ]] && ok "    Removed $SUB_COUNT subscription(s)"

      _sns delete-topic --topic-arn "$SNS_ARN" && {
        did_delete "SNS topic: $CK_SNS"
        wipe "SNS_TOPIC_NAME"
        wipe "SNS_TOPIC_ARN"
      } || did_error "SNS topic: $CK_SNS"
    }
  else
    did_skip "SNS topic: $CK_SNS (not found in AWS)"
    wipe "SNS_TOPIC_NAME"
    wipe "SNS_TOPIC_ARN"
  fi
else
  did_skip "SNS topic: SNS_TOPIC_NAME not set in config.env"
fi

# =============================================================================
# STEP 5 — IAM instance profile + IAM role
# Created by: aws_check_create.sh section 4/8
# Config key: IAM_INSTANCE_PROFILE (full ARN)
# Profile name: basename of ARN
# Role name: <profile-name>-role  (hardcoded convention in aws_check_create.sh)
# Attached policies (created by aws_check_create.sh):
#   AmazonSSMManagedInstanceCore
#   CloudWatchAgentServerPolicy
#   AmazonEC2ContainerRegistryReadOnly
# =============================================================================
step 5 "IAM instance profile and role"

if [[ -n "$CK_PROFILE_NAME" ]]; then
  PROFILE_EXISTS=$(_iam get-instance-profile \
    --instance-profile-name "$CK_PROFILE_NAME" \
    --query "InstanceProfile.InstanceProfileName")

  if [[ -n "$PROFILE_EXISTS" && "$PROFILE_EXISTS" != "None" ]]; then
    [[ "$DRY_RUN" == true ]] && {
      dr "iam remove-role-from-instance-profile $CK_PROFILE_NAME"
      dr "iam delete-instance-profile $CK_PROFILE_NAME"
      dr "iam detach-role-policy (3 managed policies)"
      dr "iam delete-role $CK_ROLE_NAME"
    } || {
      # Remove role from profile
      _iam remove-role-from-instance-profile \
        --instance-profile-name "$CK_PROFILE_NAME" \
        --role-name "$CK_ROLE_NAME" 2>/dev/null || true

      # Delete instance profile
      _iam delete-instance-profile \
        --instance-profile-name "$CK_PROFILE_NAME" && \
        did_delete "IAM instance profile: $CK_PROFILE_NAME" || \
        did_error  "IAM instance profile: $CK_PROFILE_NAME"

      # Detach all managed policies from the role
      ATTACHED=$(_iam list-attached-role-policies \
        --role-name "$CK_ROLE_NAME" \
        --query "AttachedPolicies[*].PolicyArn" \
        | tr '\t' '\n' | grep "arn:" || echo "")
      for PARN in $ATTACHED; do
        _iam detach-role-policy \
          --role-name "$CK_ROLE_NAME" \
          --policy-arn "$PARN" 2>/dev/null || true
        ok "    Detached: $(echo "$PARN" | awk -F/ '{print $NF}')"
      done

      # Delete any inline policies on the role
      INLINE=$(_iam list-role-policies \
        --role-name "$CK_ROLE_NAME" \
        --query "PolicyNames" \
        | tr '\t' '\n' | grep -v "^$" || echo "")
      for POL in $INLINE; do
        _iam delete-role-policy \
          --role-name "$CK_ROLE_NAME" \
          --policy-name "$POL" 2>/dev/null || true
      done

      # Delete the role
      _iam delete-role --role-name "$CK_ROLE_NAME" && \
        did_delete "IAM role: $CK_ROLE_NAME" || \
        did_error  "IAM role: $CK_ROLE_NAME"

      wipe "IAM_INSTANCE_PROFILE"
    }
  else
    did_skip "IAM instance profile: $CK_PROFILE_NAME (not found)"
    wipe "IAM_INSTANCE_PROFILE"
  fi
else
  did_skip "IAM instance profile: IAM_INSTANCE_PROFILE not set in config.env"
fi

# =============================================================================
# STEP 6 — Cluster placement group
# Created by: aws_check_create.sh section 3.5/8
# Config key: PLACEMENT_GROUP_NAME
# =============================================================================
step 6 "Cluster placement group"

if [[ -n "$CK_PG" ]]; then
  PG_STATE=$(_ec2 describe-placement-groups \
    --group-names "$CK_PG" \
    --query "PlacementGroups[0].State")

  case "${PG_STATE:-none}" in
    available)
      [[ "$DRY_RUN" == true ]] && dr "ec2 delete-placement-group $CK_PG" || {
        _ec2 delete-placement-group --group-name "$CK_PG" && {
          did_delete "Placement group: $CK_PG"
          wipe "PLACEMENT_GROUP_NAME"
        } || did_error "Placement group: $CK_PG"
      }
      ;;
    ""|None|none)
      did_skip "Placement group: $CK_PG (not found in AWS)"
      wipe "PLACEMENT_GROUP_NAME"
      ;;
    *)
      fail "Placement group $CK_PG is in state '$PG_STATE'"
      warn "Terminate the instances inside it first, then re-run"
      did_error "Placement group: $CK_PG (state: $PG_STATE — has instances)"
      ;;
  esac
else
  did_skip "Placement group: PLACEMENT_GROUP_NAME not set in config.env"
fi

# =============================================================================
# STEP 7 — Security group(s)
# Created by: aws_check_create.sh section 3/8
# Config key: SECURITY_GROUP_IDS (may be comma-separated)
# =============================================================================
step 7 "Security group(s)"

if [[ -n "$CK_SG" ]]; then
  SG_LIST=$(echo "$CK_SG" | tr ',' '\n' | tr -d ' ' | grep -v "^$")

  for SG_ID in $SG_LIST; do
    SG_NAME=$(_ec2 describe-security-groups \
      --group-ids "$SG_ID" \
      --query "SecurityGroups[0].GroupName")

    if [[ -n "$SG_NAME" && "$SG_NAME" != "None" ]]; then

      # Guard: never delete the default security group
      if [[ "$SG_NAME" == "default" ]]; then
        warn "Security group $SG_ID is the default SG — protected, will not delete"
        did_skip "Security group: $SG_ID (default SG — protected)"
        continue
      fi

      # Guard: check no instances are still using this SG
      # Use wc -l instead of grep -c to avoid Windows Git Bash returning
      # multi-line output (e.g. '0\n0') that breaks arithmetic comparison
      IN_USE_RAW=$(_ec2 describe-instances \
        --filters \
          "Name=network-interface.group-id,Values=$SG_ID" \
          "Name=instance-state-name,Values=running,pending,stopping,stopped" \
        --query "Reservations[*].Instances[*].InstanceId" \
        | tr '\t' '\n' | grep "i-" | wc -l | tr -d ' \t\r\n' || echo "0")
      IN_USE="${IN_USE_RAW//[^0-9]/}"
      IN_USE="${IN_USE:-0}"

      if [[ "$IN_USE" -gt 0 && "$DRY_RUN" == false ]]; then
        fail "Security group $SG_ID is still attached to $IN_USE instance(s)"
        warn "Terminate those instances first, then re-run test_cleanup.sh"
        did_error "Security group: $SG_ID (in use by $IN_USE instances)"
        continue
      fi

      [[ "$DRY_RUN" == true ]] && dr "ec2 delete-security-group $SG_ID ($SG_NAME)" || {
        _ec2 delete-security-group --group-id "$SG_ID" && {
          did_delete "Security group: $SG_ID ($SG_NAME)"
        } || did_error "Security group: $SG_ID"
      }
    else
      did_skip "Security group: $SG_ID (not found in AWS)"
    fi
  done

  [[ "$DRY_RUN" == false && ${#ERRORS[@]} -eq 0 ]] && wipe "SECURITY_GROUP_IDS"
else
  did_skip "Security group: SECURITY_GROUP_IDS not set in config.env"
fi

# =============================================================================
# STEP 8 — Subnet
# Created by: aws_check_create.sh section 2/8
# Config key: SUBNET_ID
# Guard: never delete a default subnet
# =============================================================================
step 8 "Subnet"

if [[ -n "$CK_SUBNET" ]]; then
  SUBNET_INFO=$(_ec2 describe-subnets \
    --subnet-ids "$CK_SUBNET" \
    --query "Subnets[0].[SubnetId,DefaultForAz,CidrBlock]")

  if [[ -n "$SUBNET_INFO" && "$SUBNET_INFO" != "None" ]]; then
    IS_DEFAULT=$(echo "$SUBNET_INFO" | awk '{print $2}')
    SUBNET_CIDR=$(echo "$SUBNET_INFO" | awk '{print $3}')

    if [[ "$IS_DEFAULT" == "True" ]]; then
      warn "Subnet $CK_SUBNET is a DEFAULT subnet — protected, will not delete"
      did_skip "Subnet: $CK_SUBNET (default subnet — protected)"
    else
      [[ "$DRY_RUN" == true ]] && \
        dr "ec2 delete-subnet $CK_SUBNET (CIDR: $SUBNET_CIDR)" || {
        _ec2 delete-subnet --subnet-id "$CK_SUBNET" && {
          did_delete "Subnet: $CK_SUBNET (CIDR: $SUBNET_CIDR)"
          wipe "SUBNET_ID"
          wipe "AVAILABILITY_ZONE"
        } || did_error "Subnet: $CK_SUBNET"
      }
    fi
  else
    did_skip "Subnet: $CK_SUBNET (not found in AWS)"
    wipe "SUBNET_ID"
    wipe "AVAILABILITY_ZONE"
  fi
else
  did_skip "Subnet: SUBNET_ID not set in config.env"
fi

# =============================================================================
# STEP 9 — Key pair + local .pem file
# Created by: aws_check_create.sh section 1/8
# Config key: KEY_PAIR_NAME
# =============================================================================
step 9 "Key pair and local .pem file"

if [[ -n "$CK_KEY_PAIR" ]]; then
  KP_EXISTS=$(_ec2 describe-key-pairs \
    --key-names "$CK_KEY_PAIR" \
    --query "KeyPairs[0].KeyName")

  if [[ -n "$KP_EXISTS" && "$KP_EXISTS" != "None" ]]; then
    [[ "$DRY_RUN" == true ]] && \
      dr "ec2 delete-key-pair $CK_KEY_PAIR  +  rm ${CK_KEY_PAIR}.pem" || {

      _ec2 delete-key-pair --key-name "$CK_KEY_PAIR" && {
        did_delete "Key pair: $CK_KEY_PAIR (deleted from AWS)"
        wipe "KEY_PAIR_NAME"
      } || did_error "Key pair: $CK_KEY_PAIR"

      # Remove local .pem file — search common locations
      PEM_DELETED=false
      for PEM_PATH in \
        "${SCRIPT_DIR}/${CK_KEY_PAIR}.pem" \
        "${HOME}/${CK_KEY_PAIR}.pem" \
        "./${CK_KEY_PAIR}.pem"; do
        if [[ -f "$PEM_PATH" ]]; then
          rm -f "$PEM_PATH"
          did_delete "Local .pem file: $PEM_PATH"
          PEM_DELETED=true
          break
        fi
      done
      [[ "$PEM_DELETED" == false ]] && \
        warn ".pem file not found locally — already deleted or moved"
    }
  else
    did_skip "Key pair: $CK_KEY_PAIR (not found in AWS)"
    wipe "KEY_PAIR_NAME"
  fi
else
  did_skip "Key pair: KEY_PAIR_NAME not set in config.env"
fi

# =============================================================================
# SUMMARY
# =============================================================================
echo ""
echo -e "${BOLD}╔══════════════════════════════════════════════════════════╗${NC}"
[[ "$DRY_RUN" == true ]] && \
  echo -e "${BOLD}║       DRY-RUN COMPLETE — NOTHING DELETED                 ║${NC}" || \
  echo -e "${BOLD}║       INFRASTRUCTURE CLEANUP COMPLETE                    ║${NC}"
echo -e "${BOLD}╚══════════════════════════════════════════════════════════╝${NC}"
echo ""

if [[ ${#DELETED[@]} -gt 0 ]]; then
  echo -e "${GREEN}${BOLD}  Deleted (${#DELETED[@]}):${NC}"
  for i in "${DELETED[@]}"; do echo -e "  ${GREEN}✔${NC}  $i"; done
  echo ""
fi

if [[ ${#SKIPPED[@]} -gt 0 ]]; then
  echo -e "${CYAN}${BOLD}  Skipped / not found (${#SKIPPED[@]}):${NC}"
  for i in "${SKIPPED[@]}"; do echo -e "  ⬜  $i"; done
  echo ""
fi

if [[ ${#ERRORS[@]} -gt 0 ]]; then
  echo -e "${RED}${BOLD}  Could not delete — fix required (${#ERRORS[@]}):${NC}"
  for i in "${ERRORS[@]}"; do echo -e "  ${RED}✖${NC}  $i"; done
  echo ""
  echo -e "${YELLOW}  Tip: Terminate any running EC2 instances first, then re-run${NC}"
  echo -e "${YELLOW}       bash cleanup_infra.sh${NC}"
  echo ""
  exit 1
fi

if [[ "$DRY_RUN" == false && ${#DELETED[@]} -gt 0 ]]; then
  echo -e "${GREEN}${BOLD}  config.env is now a clean slate.${NC}"
  echo -e "  ${CYAN}Run  bash main.sh  to start a fresh test cycle.${NC}"
  echo ""
fi