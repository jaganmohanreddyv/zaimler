#!/usr/bin/env bash
# ── Windows Git Bash path fix ─────────────────────────────────────────────────
export MSYS_NO_PATHCONV=1
export MSYS2_ARG_CONV_EXCL="*"
# =============================================================================
# cleanup_watcher.sh
# Deletes ONLY the temporary watcher resources created by main.sh
# (specifically by watcher/deploy_watcher.sh — Step 6 of main.sh)
#
# WHAT IT DELETES — resources named gpu-watcher-* or gpu-capacity-pipeline-*:
#   Step Functions state machine    gpu-capacity-pipeline-pipeline-*
#   DynamoDB table                  gpu-watcher-state-pipeline-*
#   API Gateway REST API            gpu-watcher-approval-pipeline-*
#   Lambda × 4                      gpu-watcher-discovery/notify/approve/cleanup-*
#   Lambda IAM role                 gpu-watcher-lambda-role-pipeline-*
#   EventBridge schedule            gpu-watcher-retry-pipeline-*
#   CloudWatch log groups           /aws/lambda/gpu-watcher-*
#   SSM parameters                  /gpu-capacity-pipeline/pipeline-*
#
# WHAT IT NEVER TOUCHES — created by aws_check_create.sh:
#   Key pair, Subnet, Security group, Placement group
#   IAM instance profile + role, SNS topic, Launch template
#   CloudWatch alarm, IAM managed policy gpu-deployment-permissions
#
# USAGE:
#   bash cleanup_watcher.sh              interactive — lists all runs, you pick
#   bash cleanup_watcher.sh --all        delete ALL pipeline runs found
#   bash cleanup_watcher.sh --dry-run    show what would be deleted, touch nothing
#   bash cleanup_watcher.sh --force      skip confirmation prompt
# =============================================================================

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CONFIG_FILE="${SCRIPT_DIR}/config.env"

# ── Flags ─────────────────────────────────────────────────────────────────────
DRY_RUN=false
FORCE=false
DELETE_ALL=false
for arg in "$@"; do
  [[ "$arg" == "--dry-run"  ]] && DRY_RUN=true
  [[ "$arg" == "--force"    ]] && FORCE=true
  [[ "$arg" == "--all"      ]] && DELETE_ALL=true
done

# ── Colors ────────────────────────────────────────────────────────────────────
RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'
CYAN='\033[0;36m'; BOLD='\033[1m'; NC='\033[0m'

ok()     { echo -e "${GREEN}  ✔  $*${NC}"; }
skip()   { echo -e "  ⬜  $*"; }
warn()   { echo -e "${YELLOW}  ⚠  $*${NC}"; }
fail()   { echo -e "${RED}  ✖  $*${NC}"; }
info()   { echo -e "${CYAN}  ℹ  $*${NC}"; }
step()   { echo -e "\n${BOLD}  [$1]  $2${NC}"; }
dr()     { echo -e "${CYAN}  [DRY-RUN] would delete: $*${NC}"; }

echo ""
echo -e "${BOLD}╔══════════════════════════════════════════════════════════╗${NC}"
echo -e "${BOLD}║   Watcher Cleanup — main.sh resources only               ║${NC}"
echo -e "${BOLD}╚══════════════════════════════════════════════════════════╝${NC}"
echo ""
[[ "$DRY_RUN" == true ]] && echo -e "${CYAN}  [DRY-RUN] Nothing will be deleted${NC}\n"

# ── Load config ───────────────────────────────────────────────────────────────
[[ ! -f "$CONFIG_FILE" ]] && { fail "config.env not found at $CONFIG_FILE"; exit 1; }
CLEAN="/tmp/cw_clean_$$.env"
sed 's/\r//' "$CONFIG_FILE" > "$CLEAN"
set +u; source "$CLEAN"; set -u
rm -f "$CLEAN"

REGION="${AWS_REGION:-us-east-1}"
ACCOUNT="${AWS_ACCOUNT_ID:-}"
PROFILE_FLAG=""
[[ -n "${AWS_PROFILE:-}" ]] && PROFILE_FLAG="--profile ${AWS_PROFILE}"

# ── AWS helpers ───────────────────────────────────────────────────────────────
_sfn()   { aws $PROFILE_FLAG --region "$REGION" --output text stepfunctions "$@" 2>/dev/null || true; }
_lmb()   { aws $PROFILE_FLAG --region "$REGION" --output text lambda "$@" 2>/dev/null || true; }
_ddb()   { aws $PROFILE_FLAG --region "$REGION" --output text dynamodb "$@" 2>/dev/null || true; }
_apigw() { aws $PROFILE_FLAG --region "$REGION" --output text apigateway "$@" 2>/dev/null || true; }
_sched() { aws $PROFILE_FLAG --region "$REGION" --output text scheduler "$@" 2>/dev/null || true; }
_iam()   { aws $PROFILE_FLAG --output text iam "$@" 2>/dev/null || true; }
_logs()  { aws $PROFILE_FLAG --region "$REGION" --output text logs "$@" 2>/dev/null || true; }
_ssm()   { aws $PROFILE_FLAG --region "$REGION" --output text ssm "$@" 2>/dev/null || true; }

# ── Verify credentials ────────────────────────────────────────────────────────
echo "  Verifying AWS credentials..."
ACCOUNT_ID=$(aws $PROFILE_FLAG sts get-caller-identity \
  --query "Account" --output text 2>&1) || {
  fail "Credentials not configured or expired."; exit 1
}
ok "Connected — account: ${ACCOUNT_ID}  region: ${REGION}"

# ── Discover all pipeline run IDs ─────────────────────────────────────────────
echo ""
info "Scanning for gpu-capacity-pipeline state machines..."

# Fetch names and ARNs separately to avoid tab-parsing issues on Windows Git Bash
SM_NAMES=$(aws $PROFILE_FLAG --region "$REGION" --output text \
  stepfunctions list-state-machines \
  --query "stateMachines[?contains(name,'gpu-capacity-pipeline-pipeline')].name" \
  2>/dev/null | tr '\t' '\n' | grep -v "^$" || true)

SM_ARNS_RAW=$(aws $PROFILE_FLAG --region "$REGION" --output text \
  stepfunctions list-state-machines \
  --query "stateMachines[?contains(name,'gpu-capacity-pipeline-pipeline')].stateMachineArn" \
  2>/dev/null | tr '\t' '\n' | grep -v "^$" || true)

if [[ -z "$SM_NAMES" ]]; then
  info "No gpu-capacity-pipeline state machines found in $REGION."
  info "Nothing to delete. Exiting."
  exit 0
fi

# Build arrays from newline-separated output
declare -a RUN_IDS=()
declare -a SM_ARNS=()
while IFS= read -r SM_NAME; do
  [[ -z "$SM_NAME" ]] && continue
  # Extract run ID: gpu-capacity-pipeline-pipeline-20260615-165940 -> pipeline-20260615-165940
  RUN_ID="${SM_NAME#gpu-capacity-pipeline-}"
  RUN_IDS+=("$RUN_ID")
done <<< "$SM_NAMES"
while IFS= read -r SM_ARN; do
  [[ -z "$SM_ARN" ]] && continue
  SM_ARNS+=("$SM_ARN")
done <<< "$SM_ARNS_RAW"

if [[ ${#RUN_IDS[@]} -eq 0 ]]; then
  info "No pipeline runs found. Exiting."
  exit 0
fi

# ── Show what was found ───────────────────────────────────────────────────────
echo ""
echo -e "${BOLD}  Found ${#RUN_IDS[@]} pipeline run(s):${NC}"
echo ""
for i in "${!RUN_IDS[@]}"; do
  STATUS=$(aws $PROFILE_FLAG --region "$REGION" --output text \
    stepfunctions list-executions \
    --state-machine-arn "${SM_ARNS[$i]}" \
    --max-results 1 \
    --query "executions[0].status" 2>/dev/null || echo "UNKNOWN")
  printf "  ${CYAN}[%d]${NC}  %-45s  Status: %s\n" \
    "$((i+1))" "${RUN_IDS[$i]}" "${STATUS:-UNKNOWN}"
done
echo ""

# ── Select which run(s) to delete ────────────────────────────────────────────
declare -a SELECTED_IDS=()
declare -a SELECTED_ARNS=()

if [[ "$DELETE_ALL" == true ]]; then
  SELECTED_IDS=("${RUN_IDS[@]}")
  SELECTED_ARNS=("${SM_ARNS[@]}")
  info "Deleting all ${#RUN_IDS[@]} pipeline run(s)."
elif [[ ${#RUN_IDS[@]} -eq 1 ]]; then
  SELECTED_IDS=("${RUN_IDS[0]}")
  SELECTED_ARNS=("${SM_ARNS[0]}")
  info "Only one pipeline run found — selecting automatically."
else
  echo -e "  ${CYAN}[a]${NC}  Delete ALL runs listed above"
  echo ""
  while true; do
    read -rp "  Choose run to delete [1-${#RUN_IDS[@]}] or a for all: " CHOICE
    CHOICE=$(echo "$CHOICE" | tr -d ' ')
    if [[ "$CHOICE" == "a" || "$CHOICE" == "A" ]]; then
      SELECTED_IDS=("${RUN_IDS[@]}")
      SELECTED_ARNS=("${SM_ARNS[@]}")
      break
    fi
    if [[ "$CHOICE" =~ ^[0-9]+$ ]] && \
       [[ "$CHOICE" -ge 1 ]] && \
       [[ "$CHOICE" -le "${#RUN_IDS[@]}" ]]; then
      IDX=$((CHOICE - 1))
      SELECTED_IDS=("${RUN_IDS[$IDX]}")
      SELECTED_ARNS=("${SM_ARNS[$IDX]}")
      break
    fi
    fail "Invalid choice. Enter a number between 1 and ${#RUN_IDS[@]}, or a."
  done
fi

# ── Confirmation ──────────────────────────────────────────────────────────────
echo ""
echo -e "${BOLD}  Will delete temporary watcher resources for:${NC}"
for i in "${!SELECTED_IDS[@]}"; do
  echo -e "  ${RED}✖${NC}  ${SELECTED_IDS[$i]}  (${SELECTED_ARNS[$i]##*:stateMachine:})"
done
echo ""
echo -e "  ${GREEN}${BOLD}Will NOT touch (aws_check_create.sh resources):${NC}"
echo -e "  ✅  Key pair · Subnet · Security group · Placement group"
echo -e "  ✅  IAM instance profile · SNS topic · Launch template"
echo -e "  ✅  CloudWatch alarm · IAM managed policy"
echo ""

if [[ "$DRY_RUN" == false && "$FORCE" == false ]]; then
  read -rp "  Type DELETE to confirm: " CONFIRM
  echo ""
  [[ "$CONFIRM" != "DELETE" ]] && {
    echo -e "${CYAN}  Aborted. Nothing deleted.${NC}"; exit 0
  }
fi

# ── Tracking ──────────────────────────────────────────────────────────────────
DELETED=(); SKIPPED=(); ERRORS=()
did_delete() { DELETED+=("$1"); ok "Deleted  :  $1"; }
did_skip()   { SKIPPED+=("$1"); skip "Not found — skipped: $1"; }
did_error()  { ERRORS+=("$1");  fail "Could not delete: $1"; }

# =============================================================================
# DELETE LOOP — one pass per selected pipeline run
# =============================================================================
for idx in "${!SELECTED_IDS[@]}"; do
  RUN_ID="${SELECTED_IDS[$idx]}"
  SM_ARN="${SELECTED_ARNS[$idx]}"
  SSM_PREFIX="/gpu-capacity-pipeline/${RUN_ID}"

  echo ""
  echo -e "${BOLD}━━━━━  Cleaning: ${RUN_ID}  ━━━━━${NC}"

  # ── 1. Stop running executions and delete Step Functions ───────────────────
  step "1/8" "Step Functions state machine"

  RUNNING_EXECS=$(_sfn list-executions \
    --state-machine-arn "$SM_ARN" \
    --status-filter RUNNING \
    --query "executions[*].executionArn" 2>/dev/null | tr '\t' '\n' | grep "arn:" || true)

  for EXEC_ARN in $RUNNING_EXECS; do
    if [[ "$DRY_RUN" == true ]]; then
      dr "sfn stop-execution $EXEC_ARN"
    else
      _sfn stop-execution --execution-arn "$EXEC_ARN" --cause "cleanup_watcher.sh" > /dev/null 2>&1 || true
      ok "Stopped execution: ${EXEC_ARN##*:}"
    fi
  done

  SM_EXISTS=$(_sfn describe-state-machine \
    --state-machine-arn "$SM_ARN" \
    --query "name" 2>/dev/null || echo "")
  if [[ -n "$SM_EXISTS" && "$SM_EXISTS" != "None" ]]; then
    [[ "$DRY_RUN" == true ]] && dr "sfn delete-state-machine $SM_ARN" || {
      sleep 2
      aws $PROFILE_FLAG --region "$REGION" stepfunctions delete-state-machine \
        --state-machine-arn "$SM_ARN" > /dev/null 2>&1 && \
        did_delete "Step Functions: $SM_ARN" || did_error "Step Functions: $SM_ARN"
    }
  else
    did_skip "Step Functions: $SM_ARN"
  fi

  # ── 2. Delete EventBridge schedule ────────────────────────────────────────
  step "2/8" "EventBridge schedule"

  SCHED_NAME="gpu-watcher-retry-${RUN_ID}"
  SCHED_EXISTS=$(_sched get-schedule \
    --name "$SCHED_NAME" \
    --query "Name" 2>/dev/null || echo "")
  if [[ -n "$SCHED_EXISTS" && "$SCHED_EXISTS" != "None" ]]; then
    [[ "$DRY_RUN" == true ]] && dr "scheduler delete-schedule $SCHED_NAME" || {
      aws $PROFILE_FLAG --region "$REGION" scheduler delete-schedule \
        --name "$SCHED_NAME" > /dev/null 2>&1 && \
        did_delete "EventBridge schedule: $SCHED_NAME" || did_skip "EventBridge schedule: $SCHED_NAME"
    }
  else
    did_skip "EventBridge schedule: $SCHED_NAME"
  fi

  # ── 3. Delete API Gateway ──────────────────────────────────────────────────
  step "3/8" "API Gateway"

  APIGW_NAME="gpu-watcher-approval-${RUN_ID}"
  APIGW_ID=$(_apigw get-rest-apis \
    --query "items[?name=='${APIGW_NAME}'].id" 2>/dev/null | head -1 || echo "")
  if [[ -n "$APIGW_ID" && "$APIGW_ID" != "None" ]]; then
    [[ "$DRY_RUN" == true ]] && dr "apigateway delete-rest-api $APIGW_ID ($APIGW_NAME)" || {
      aws $PROFILE_FLAG --region "$REGION" apigateway delete-rest-api \
        --rest-api-id "$APIGW_ID" > /dev/null 2>&1 && \
        did_delete "API Gateway: $APIGW_NAME ($APIGW_ID)" || did_error "API Gateway: $APIGW_NAME"
    }
  else
    did_skip "API Gateway: $APIGW_NAME"
  fi

  # ── 4. Delete DynamoDB table ───────────────────────────────────────────────
  step "4/8" "DynamoDB table"

  TABLE_NAME="gpu-watcher-state-${RUN_ID}"
  TABLE_EXISTS=$(_ddb describe-table \
    --table-name "$TABLE_NAME" \
    --query "Table.TableName" 2>/dev/null || echo "")
  if [[ -n "$TABLE_EXISTS" && "$TABLE_EXISTS" != "None" ]]; then
    [[ "$DRY_RUN" == true ]] && dr "dynamodb delete-table $TABLE_NAME" || {
      aws $PROFILE_FLAG --region "$REGION" dynamodb delete-table \
        --table-name "$TABLE_NAME" > /dev/null 2>&1 && \
        did_delete "DynamoDB table: $TABLE_NAME" || did_error "DynamoDB table: $TABLE_NAME"
    }
  else
    did_skip "DynamoDB table: $TABLE_NAME"
  fi

  # ── 5. Delete Lambda functions ─────────────────────────────────────────────
  step "5/8" "Lambda functions"

  for FUNC_SUFFIX in discovery notify approve cleanup; do
    FUNC_NAME="gpu-watcher-${FUNC_SUFFIX}-${RUN_ID}"
    FUNC_EXISTS=$(_lmb get-function \
      --function-name "$FUNC_NAME" \
      --query "Configuration.FunctionName" 2>/dev/null || echo "")
    if [[ -n "$FUNC_EXISTS" && "$FUNC_EXISTS" != "None" ]]; then
      [[ "$DRY_RUN" == true ]] && dr "lambda delete-function $FUNC_NAME" || {
        aws $PROFILE_FLAG --region "$REGION" lambda delete-function \
          --function-name "$FUNC_NAME" > /dev/null 2>&1 && \
          did_delete "Lambda: $FUNC_NAME" || did_error "Lambda: $FUNC_NAME"
      }
    else
      did_skip "Lambda: $FUNC_NAME"
    fi
  done

  # ── 6. Delete Lambda IAM role ──────────────────────────────────────────────
  step "6/8" "Lambda IAM role"

  ROLE_NAME="gpu-watcher-lambda-role-${RUN_ID}"
  ROLE_EXISTS=$(_iam get-role \
    --role-name "$ROLE_NAME" \
    --query "Role.RoleName" 2>/dev/null || echo "")
  if [[ -n "$ROLE_EXISTS" && "$ROLE_EXISTS" != "None" ]]; then
    [[ "$DRY_RUN" == true ]] && dr "iam delete-role $ROLE_NAME (+ detach policies)" || {
      # Detach managed policies
      ATTACHED=$(_iam list-attached-role-policies \
        --role-name "$ROLE_NAME" \
        --query "AttachedPolicies[*].PolicyArn" 2>/dev/null | tr '\t' '\n' | grep "arn:" || true)
      for PARN in $ATTACHED; do
        _iam detach-role-policy --role-name "$ROLE_NAME" --policy-arn "$PARN" > /dev/null 2>&1 || true
      done
      # Delete inline policies
      INLINE=$(_iam list-role-policies \
        --role-name "$ROLE_NAME" \
        --query "PolicyNames" 2>/dev/null | tr '\t' '\n' | grep -v "^$" || true)
      for POL in $INLINE; do
        _iam delete-role-policy --role-name "$ROLE_NAME" --policy-name "$POL" > /dev/null 2>&1 || true
      done
      aws $PROFILE_FLAG iam delete-role \
        --role-name "$ROLE_NAME" > /dev/null 2>&1 && \
        did_delete "IAM role: $ROLE_NAME" || did_error "IAM role: $ROLE_NAME"
    }
  else
    did_skip "IAM role: $ROLE_NAME"
  fi

  # Also delete Step Functions role if it exists
  SF_ROLE="gpu-watcher-sf-role-${RUN_ID}"
  SF_ROLE_EXISTS=$(_iam get-role \
    --role-name "$SF_ROLE" \
    --query "Role.RoleName" 2>/dev/null || echo "")
  if [[ -n "$SF_ROLE_EXISTS" && "$SF_ROLE_EXISTS" != "None" ]]; then
    [[ "$DRY_RUN" == true ]] && dr "iam delete-role $SF_ROLE" || {
      INLINE=$(_iam list-role-policies \
        --role-name "$SF_ROLE" \
        --query "PolicyNames" 2>/dev/null | tr '\t' '\n' | grep -v "^$" || true)
      for POL in $INLINE; do
        _iam delete-role-policy --role-name "$SF_ROLE" --policy-name "$POL" > /dev/null 2>&1 || true
      done
      aws $PROFILE_FLAG iam delete-role \
        --role-name "$SF_ROLE" > /dev/null 2>&1 && \
        did_delete "IAM role: $SF_ROLE" || did_skip "IAM role: $SF_ROLE"
    }
  fi

  # ── 7. Delete CloudWatch log groups ───────────────────────────────────────
  step "7/8" "CloudWatch log groups"

  for FUNC_SUFFIX in discovery notify approve cleanup; do
    LOG_GROUP="/aws/lambda/gpu-watcher-${FUNC_SUFFIX}-${RUN_ID}"
    LOG_EXISTS=$(aws $PROFILE_FLAG --region "$REGION" logs describe-log-groups \
      --log-group-name-prefix "$LOG_GROUP" \
      --query "logGroups[0].logGroupName" \
      --output text 2>/dev/null || echo "")
    if [[ -n "$LOG_EXISTS" && "$LOG_EXISTS" != "None" ]]; then
      [[ "$DRY_RUN" == true ]] && dr "logs delete-log-group $LOG_GROUP" || {
        aws $PROFILE_FLAG --region "$REGION" logs delete-log-group \
          --log-group-name "$LOG_GROUP" > /dev/null 2>&1 && \
          did_delete "CloudWatch log group: $LOG_GROUP" || did_skip "CloudWatch log group: $LOG_GROUP"
      }
    else
      did_skip "CloudWatch log group: $LOG_GROUP"
    fi
  done

  # ── 8. Delete SSM parameters ───────────────────────────────────────────────
  step "8/8" "SSM parameters"

  if [[ "$DRY_RUN" == true ]]; then
    dr "ssm delete-parameters-by-path $SSM_PREFIX/*"
  else
    SSM_PARAMS=$(aws $PROFILE_FLAG --region "$REGION" ssm get-parameters-by-path \
      --path "$SSM_PREFIX" \
      --recursive \
      --query "Parameters[*].Name" \
      --output text 2>/dev/null | tr '\t' '\n' | grep -v "^$" || true)

    PARAM_COUNT=0
    BATCH=()
    while IFS= read -r PNAME; do
      [[ -z "$PNAME" ]] && continue
      BATCH+=("$PNAME")
      if [[ ${#BATCH[@]} -eq 10 ]]; then
        aws $PROFILE_FLAG --region "$REGION" ssm delete-parameters \
          --names "${BATCH[@]}" > /dev/null 2>&1 && \
          PARAM_COUNT=$((PARAM_COUNT + ${#BATCH[@]})) || true
        BATCH=()
      fi
    done <<< "$SSM_PARAMS"

    # Flush remaining
    if [[ ${#BATCH[@]} -gt 0 ]]; then
      aws $PROFILE_FLAG --region "$REGION" ssm delete-parameters \
        --names "${BATCH[@]}" > /dev/null 2>&1 && \
        PARAM_COUNT=$((PARAM_COUNT + ${#BATCH[@]})) || true
    fi

    if [[ $PARAM_COUNT -gt 0 ]]; then
      did_delete "SSM parameters: $PARAM_COUNT parameter(s) under $SSM_PREFIX"
    else
      did_skip "SSM parameters: none found under $SSM_PREFIX"
    fi
  fi

  # ── Clear watcher keys from config.env ────────────────────────────────────
  if [[ "$DRY_RUN" == false ]]; then
    TS=$(date +%Y%m%d_%H%M%S)
    cp "$CONFIG_FILE" "${CONFIG_FILE}.bak.${TS}"
    sed -i 's|^WATCHER_STATE_MACHINE_ARN=.*|WATCHER_STATE_MACHINE_ARN=""|' "$CONFIG_FILE"
    sed -i 's|^WATCHER_DYNAMODB_TABLE=.*|WATCHER_DYNAMODB_TABLE=""|'       "$CONFIG_FILE"
    sed -i 's|^WATCHER_API_GATEWAY_URL=.*|WATCHER_API_GATEWAY_URL=""|'     "$CONFIG_FILE"
    sed -i 's|^WATCHER_LAMBDA_ROLE_ARN=.*|WATCHER_LAMBDA_ROLE_ARN=""|'     "$CONFIG_FILE"
    ok "config.env watcher fields cleared (backup: .bak.${TS})"
  fi

done

# =============================================================================
# SUMMARY
# =============================================================================
echo ""
echo -e "${BOLD}╔══════════════════════════════════════════════════════════╗${NC}"
[[ "$DRY_RUN" == true ]] && \
  echo -e "${BOLD}║       DRY-RUN COMPLETE — NOTHING DELETED                 ║${NC}" || \
  echo -e "${BOLD}║       WATCHER CLEANUP COMPLETE                           ║${NC}"
echo -e "${BOLD}╚══════════════════════════════════════════════════════════╝${NC}"
echo ""

if [[ ${#DELETED[@]} -gt 0 ]]; then
  echo -e "${GREEN}${BOLD}  Deleted (${#DELETED[@]}):${NC}"
  for i in "${DELETED[@]}"; do echo -e "  ${GREEN}✔${NC}  $i"; done
  echo ""
fi

if [[ ${#SKIPPED[@]} -gt 0 ]]; then
  echo -e "${CYAN}${BOLD}  Not found / already gone (${#SKIPPED[@]}):${NC}"
  for i in "${SKIPPED[@]}"; do echo -e "  ⬜  $i"; done
  echo ""
fi

if [[ ${#ERRORS[@]} -gt 0 ]]; then
  echo -e "${RED}${BOLD}  Could not delete (${#ERRORS[@]}):${NC}"
  for i in "${ERRORS[@]}"; do echo -e "  ${RED}✖${NC}  $i"; done
  echo ""
fi

echo -e "  ${GREEN}${BOLD}Permanent infrastructure (aws_check_create.sh) untouched:${NC}"
echo -e "  ✅  Key pair · Subnet · Security group · Placement group"
echo -e "  ✅  IAM instance profile · SNS topic · Launch template"
echo -e "  ✅  CloudWatch alarm · IAM managed policy"
echo ""

if [[ "$DRY_RUN" == false && ${#DELETED[@]} -gt 0 ]]; then
  echo -e "  ${CYAN}Run  bash main.sh  to start a fresh pipeline run.${NC}"
  echo ""
fi