#!/usr/bin/env bash
# ── Windows Git Bash path fix ─────────────────────────────────────────────────
export MSYS_NO_PATHCONV=1
export MSYS2_ARG_CONV_EXCL="*"
# =============================================================================
# watcher/deploy_watcher.sh — Deploy all temporary 48-hour watcher services
#
# CHANGES FROM ORIGINAL:
#   - Step Functions definition simplified:
#       Removed: SendAZEmails, WaitForApproval, RouteApproval, SendReminder
#       Added:   SendCapacityFoundEmail, WaitForProceed, CheckProceedResult,
#                WaitForConfirm, CheckConfirmResult
#   - New flow:
#       RunDiscovery → found → SendCapacityFoundEmail → WaitForProceed (4h)
#                   → CheckProceedResult → proceed → PipelineApproved
#                                        → cancelled → CleanupAndExit
#                                        → pending → WaitForNextRetry (scan continues)
#       RunDiscovery → not found → WaitForNextRetry (15 min) → RunDiscovery
#       RunDiscovery → timeout → Send48HourEmail → WaitForRetryOrQuit (4h)
#                   → retry → ResetAndRetry → RunDiscovery
#                   → quit  → CleanupAndExit
# =============================================================================

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(dirname "$SCRIPT_DIR")"
CONFIG_FILE="${ROOT_DIR}/config.env"

# ── Parse arguments ───────────────────────────────────────────────────────────
DRY_RUN=false
COMBINATIONS=""
INSTANCE_COUNT="1"
DURATION_DAYS="14"
START_DATE=""
ALERT_EMAIL=""
RETRY_MINS="15"
MAX_HOURS="48"

while [[ $# -gt 0 ]]; do
  case "$1" in
    --dry-run)           DRY_RUN=true ;;
    --combinations)      COMBINATIONS="$2"; shift ;;
    --instance-count)    INSTANCE_COUNT="$2"; shift ;;
    --duration-days)     DURATION_DAYS="$2"; shift ;;
    --start-date)        START_DATE="$2"; shift ;;
    --alert-email)       ALERT_EMAIL="$2"; shift ;;
    --retry-mins)        RETRY_MINS="$2"; shift ;;
    --max-hours)         MAX_HOURS="$2"; shift ;;
  esac
  shift
done

CLEAN_ENV="/tmp/config_clean_watcher_$$.env"
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
dryrun() { echo -e "${CYAN}  [DRY-RUN] $*${NC}"; }

PROFILE_FLAG=""
[[ -n "${AWS_PROFILE:-}" ]] && PROFILE_FLAG="--profile ${AWS_PROFILE}"

PIPELINE_RUN_ID="pipeline-$(date +%Y%m%d-%H%M%S)"
SSM_PREFIX="/gpu-capacity-pipeline/${PIPELINE_RUN_ID}"
WATCHER_TAG="CreatedBy=watcher,Purpose=48hr-capacity-retry,PipelineRunId=${PIPELINE_RUN_ID}"
TABLE_NAME="gpu-watcher-state-${PIPELINE_RUN_ID}"
LAMBDA_ROLE_NAME="gpu-watcher-lambda-role-${PIPELINE_RUN_ID}"
SM_NAME="gpu-capacity-pipeline-${PIPELINE_RUN_ID}"
SCHEDULE_NAME="gpu-watcher-retry-${PIPELINE_RUN_ID}"
APIGW_NAME="gpu-watcher-approval-${PIPELINE_RUN_ID}"

CLEANUP_FILES=()
trap 'rm -f "${CLEANUP_FILES[@]}" 2>/dev/null || true' EXIT

patch_config() {
  local key="$1" val="$2"
  local ts; ts=$(date +%Y%m%d_%H%M%S)
  cp "$CONFIG_FILE" "${CONFIG_FILE}.bak.${ts}"
  if grep -q "^${key}=" "$CONFIG_FILE"; then
    sed -i "s|^${key}=.*|${key}=\"${val}\"|" "$CONFIG_FILE"
  else
    echo "${key}=\"${val}\"" >> "$CONFIG_FILE"
  fi
}

if [[ "$DRY_RUN" == true ]]; then
  dryrun "Would deploy: Lambda role, 4 Lambdas, DynamoDB, API Gateway, Step Functions"
  dryrun "Pipeline Run ID would be: $PIPELINE_RUN_ID"
  dryrun "Combinations: $COMBINATIONS"
  dryrun "New simplified Step Functions flow (single PROCEED email, no per-AZ YES/NO/WAIT)"
  exit 0
fi

# ── Step 1: Save pipeline config to SSM ──────────────────────────────────────
header "1 / 8  Saving pipeline config to SSM"

put_param() {
  local _key="$1" _val="$2"
  [[ -z "$_val" ]] && _val="none"
  local _esc="${_val//\\/\\\\}"
  _esc="${_esc//\"/\\\"}"
  aws $PROFILE_FLAG ssm put-parameter \
    --region "$AWS_REGION" \
    --cli-input-json "{\"Name\":\"${SSM_PREFIX}/${_key}\",\"Value\":\"${_esc}\",\"Type\":\"String\",\"Overwrite\":true}" \
    > /dev/null
}

put_param "combinations"      "$COMBINATIONS"
put_param "instance-count"    "$INSTANCE_COUNT"
put_param "duration-days"     "$DURATION_DAYS"
put_param "start-date"        "$START_DATE"
put_param "alert-email"       "$ALERT_EMAIL"
put_param "retry-mins"        "$RETRY_MINS"
put_param "max-hours"         "$MAX_HOURS"
put_param "pipeline-run-id"   "$PIPELINE_RUN_ID"
put_param "finder-path"       "/var/task/app.py"
put_param "reserve-script"    "${ROOT_DIR}/reserve.sh"
put_param "launch-script"     "${ROOT_DIR}/launch.sh"
put_param "monitor-script"    "${ROOT_DIR}/monitor.sh"
put_param "aws-region"        "$AWS_REGION"

RESOLVED_SNS_ARN="${SNS_TOPIC_ARN:-}"
if [[ -z "$RESOLVED_SNS_ARN" && -n "${SNS_TOPIC_NAME:-}" ]]; then
  RESOLVED_SNS_ARN="arn:aws:sns:${AWS_REGION}:${AWS_ACCOUNT_ID}:${SNS_TOPIC_NAME}"
  info "SNS ARN constructed: $RESOLVED_SNS_ARN"
fi
put_param "sns-topic-arn"     "$RESOLVED_SNS_ARN"
put_param "cleanup-table"     "$TABLE_NAME"
put_param "cleanup-schedule"  "$SCHEDULE_NAME"
put_param "cleanup-apigw"     "$APIGW_NAME"
put_param "cleanup-sm-name"   "$SM_NAME"
put_param "cleanup-role-name" "$LAMBDA_ROLE_NAME"

# Initialise approval + control signals to empty
put_param "approval-decision"   ""
put_param "retry-quit-decision" ""
put_param "control-decision"    ""
put_param "proceed-token"       ""
put_param "found-offerings"     ""
put_param "selected-offering"   ""

ok "Pipeline config saved to SSM: $SSM_PREFIX"

# ── Step 2: Create IAM role for Lambda ────────────────────────────────────────
header "2 / 8  Creating Lambda IAM role"

LAMBDA_TRUST_JSON='{"Version":"2012-10-17","Statement":[{"Effect":"Allow","Principal":{"Service":"lambda.amazonaws.com"},"Action":"sts:AssumeRole"}]}'

LAMBDA_ROLE_ARN=$(aws $PROFILE_FLAG iam create-role \
  --role-name "$LAMBDA_ROLE_NAME" \
  --assume-role-policy-document "$LAMBDA_TRUST_JSON" \
  --description "GPU watcher Lambda execution role - temporary" \
  --tags Key=CreatedBy,Value=watcher Key=PipelineRunId,Value="$PIPELINE_RUN_ID" \
  --query "Role.Arn" --output text)

LAMBDA_PERMS_JSON='{"Version":"2012-10-17","Statement":[{"Effect":"Allow","Action":["logs:CreateLogGroup","logs:CreateLogStream","logs:PutLogEvents","ec2:DescribeCapacityBlockOfferings","ec2:DescribeCapacityReservations","sagemaker:SearchTrainingPlanOfferings","dynamodb:PutItem","dynamodb:GetItem","dynamodb:UpdateItem","dynamodb:Scan","dynamodb:DeleteTable","dynamodb:DescribeTable","ssm:GetParameter","ssm:PutParameter","ssm:GetParametersByPath","ssm:DeleteParameters","sns:Publish","scheduler:DeleteSchedule","apigateway:DELETE","states:StopExecution","states:DeleteStateMachine","lambda:DeleteFunction","lambda:InvokeFunction","iam:DetachRolePolicy","iam:DeleteRole","iam:DeleteRolePolicy","iam:ListRolePolicies","iam:ListAttachedRolePolicies","cloudwatch:DeleteAlarms","logs:DeleteLogGroup","ec2:DeleteKeyPair","ec2:DeleteSubnet","ec2:DeleteSecurityGroup","ec2:DeletePlacementGroup","ec2:DescribeSubnets","ec2:DescribeSecurityGroups","ec2:DescribePlacementGroups","ec2:DescribeKeyPairs","ec2:DeleteLaunchTemplate","ec2:DescribeLaunchTemplates","iam:DeleteInstanceProfile","iam:RemoveRoleFromInstanceProfile","iam:GetInstanceProfile","iam:DetachUserPolicy","iam:DeletePolicy","iam:ListPolicyVersions","iam:DeletePolicyVersion","iam:GetPolicy","sns:DeleteTopic","sns:ListSubscriptionsByTopic","sns:Unsubscribe","sns:ListTopics","cloudwatch:DescribeAlarms"],"Resource":"*"}]}'

aws $PROFILE_FLAG iam put-role-policy \
  --role-name "$LAMBDA_ROLE_NAME" \
  --policy-name "gpu-watcher-policy" \
  --policy-document "$LAMBDA_PERMS_JSON" > /dev/null

ok "Lambda role created: $LAMBDA_ROLE_ARN"
put_param "lambda-role-arn"          "$LAMBDA_ROLE_ARN"
put_param "cleanup-lambda-role-name" "$LAMBDA_ROLE_NAME"

info "Waiting 15 seconds for IAM role to propagate..."
sleep 15

# ── Step 3: Package and deploy Lambda functions ───────────────────────────────
header "3 / 8  Deploying Lambda functions"

deploy_lambda() {
  local FUNC_NAME="$1"
  local SOURCE_FILE="$2"
  local HANDLER="$3"

  local SRC_DIR;  SRC_DIR="$(dirname  "$SOURCE_FILE")"
  local SRC_BASE; SRC_BASE="$(basename "$SOURCE_FILE")"
  local ZIP_NAME="${FUNC_NAME}_deploy.zip"

  pushd "$SRC_DIR" > /dev/null
  python3 -c "
import zipfile
with zipfile.ZipFile('${ZIP_NAME}', 'w', zipfile.ZIP_DEFLATED) as zf:
    zf.write('${SRC_BASE}', '${SRC_BASE}')
print('ZIP created: ${ZIP_NAME}')
" || { fail "Failed to create ZIP for $FUNC_NAME"; popd > /dev/null; return 1; }

  if aws $PROFILE_FLAG lambda get-function \
      --function-name "$FUNC_NAME" \
      --region "$AWS_REGION" > /dev/null 2>&1; then
    aws $PROFILE_FLAG lambda update-function-code \
      --function-name "$FUNC_NAME" \
      --region "$AWS_REGION" \
      --zip-file "fileb://./${ZIP_NAME}" > /dev/null
  else
    aws $PROFILE_FLAG lambda create-function \
      --function-name "$FUNC_NAME" \
      --region "$AWS_REGION" \
      --runtime "python3.12" \
      --role "$LAMBDA_ROLE_ARN" \
      --handler "$HANDLER" \
      --zip-file "fileb://./${ZIP_NAME}" \
      --timeout 300 \
      --memory-size 512 \
      --environment "Variables={SSM_PREFIX=${SSM_PREFIX},AWS_REGION_NAME=${AWS_REGION},PIPELINE_RUN_ID=${PIPELINE_RUN_ID},TABLE_NAME=${TABLE_NAME}}" \
      > /dev/null
  fi

  rm -f "$ZIP_NAME"
  popd > /dev/null
  ok "Lambda deployed: $FUNC_NAME"
  put_param "lambda-${FUNC_NAME}" "$FUNC_NAME"
}

# Discovery Lambda
DISCO_NAME="gpu-watcher-discovery-${PIPELINE_RUN_ID}"
DISCO_ZIP="${DISCO_NAME}_deploy.zip"
pushd "${SCRIPT_DIR}" > /dev/null
python3 -c "
import zipfile
with zipfile.ZipFile('${DISCO_ZIP}', 'w', zipfile.ZIP_DEFLATED) as zf:
    zf.write('lambda_discovery.py', 'lambda_discovery.py')
print('ZIP created: ${DISCO_ZIP}')
" || { fail "Failed to create discovery ZIP"; popd > /dev/null; exit 1; }
if aws $PROFILE_FLAG lambda get-function \
    --function-name "$DISCO_NAME" --region "$AWS_REGION" > /dev/null 2>&1; then
  aws $PROFILE_FLAG lambda update-function-code \
    --function-name "$DISCO_NAME" --region "$AWS_REGION" \
    --zip-file "fileb://./${DISCO_ZIP}" > /dev/null
else
  aws $PROFILE_FLAG lambda create-function \
    --function-name "$DISCO_NAME" --region "$AWS_REGION" \
    --runtime "python3.12" --role "$LAMBDA_ROLE_ARN" \
    --handler "lambda_discovery.handler" \
    --zip-file "fileb://./${DISCO_ZIP}" \
    --timeout 300 --memory-size 512 \
    --environment "Variables={SSM_PREFIX=${SSM_PREFIX},AWS_REGION_NAME=${AWS_REGION},PIPELINE_RUN_ID=${PIPELINE_RUN_ID},TABLE_NAME=${TABLE_NAME}}" \
    > /dev/null
fi
rm -f "$DISCO_ZIP"
popd > /dev/null
ok "Lambda deployed: $DISCO_NAME"
put_param "lambda-${DISCO_NAME}" "$DISCO_NAME"

deploy_lambda "gpu-watcher-notify-${PIPELINE_RUN_ID}" \
  "${SCRIPT_DIR}/lambda_notify.py" \
  "lambda_notify.handler"

deploy_lambda "gpu-watcher-approve-${PIPELINE_RUN_ID}" \
  "${SCRIPT_DIR}/lambda_approve.py" \
  "lambda_approve.handler"

deploy_lambda "gpu-watcher-cleanup-${PIPELINE_RUN_ID}" \
  "${SCRIPT_DIR}/lambda_cleanup.py" \
  "lambda_cleanup.handler"

CLEANUP_LAMBDA_NAME="gpu-watcher-cleanup-${PIPELINE_RUN_ID}"
put_param "cleanup-lambda-name" "$CLEANUP_LAMBDA_NAME"

# ── Step 4: Create DynamoDB table ─────────────────────────────────────────────
header "4 / 8  Creating DynamoDB state table"

aws $PROFILE_FLAG dynamodb create-table \
  --region "$AWS_REGION" \
  --table-name "$TABLE_NAME" \
  --attribute-definitions AttributeName=pk,AttributeType=S \
  --key-schema AttributeName=pk,KeyType=HASH \
  --billing-mode PAY_PER_REQUEST \
  --tags Key=CreatedBy,Value=watcher Key=PipelineRunId,Value="$PIPELINE_RUN_ID" \
  > /dev/null

aws $PROFILE_FLAG dynamodb wait table-exists \
  --region "$AWS_REGION" \
  --table-name "$TABLE_NAME"

aws $PROFILE_FLAG dynamodb put-item \
  --region "$AWS_REGION" \
  --table-name "$TABLE_NAME" \
  --item "{
    \"pk\":           {\"S\": \"watcher-state\"},
    \"status\":       {\"S\": \"running\"},
    \"attemptCount\": {\"N\": \"0\"},
    \"maxAttempts\":  {\"N\": \"$(( MAX_HOURS * 60 / RETRY_MINS ))\"},
    \"startTime\":    {\"S\": \"$(date -u +%Y-%m-%dT%H:%M:%SZ)\"},
    \"maxHours\":     {\"N\": \"${MAX_HOURS}\"},
    \"pipelineRunId\":{\"S\": \"${PIPELINE_RUN_ID}\"}
  }" > /dev/null

ok "DynamoDB table created: $TABLE_NAME"

# ── Step 5: Create API Gateway ────────────────────────────────────────────────
header "5 / 8  Creating API Gateway approval endpoint"

APIGW_ID=$(aws $PROFILE_FLAG apigateway create-rest-api \
  --region "$AWS_REGION" \
  --name "$APIGW_NAME" \
  --description "GPU watcher approval endpoint - temporary" \
  --tags "CreatedBy=watcher,PipelineRunId=${PIPELINE_RUN_ID}" \
  --query "id" --output text)

ROOT_RESOURCE_ID=$(aws $PROFILE_FLAG apigateway get-resources \
  --region "$AWS_REGION" \
  --rest-api-id "$APIGW_ID" \
  --query "items[?path=='/'].id" --output text)

APPROVE_RESOURCE_ID=$(aws $PROFILE_FLAG apigateway create-resource \
  --region "$AWS_REGION" \
  --rest-api-id "$APIGW_ID" \
  --parent-id "$ROOT_RESOURCE_ID" \
  --path-part "approve" \
  --query "id" --output text)

aws $PROFILE_FLAG apigateway put-method \
  --region "$AWS_REGION" \
  --rest-api-id "$APIGW_ID" \
  --resource-id "$APPROVE_RESOURCE_ID" \
  --http-method GET \
  --authorization-type NONE > /dev/null

APPROVE_LAMBDA_ARN=$(aws $PROFILE_FLAG lambda get-function \
  --region "$AWS_REGION" \
  --function-name "gpu-watcher-approve-${PIPELINE_RUN_ID}" \
  --query "Configuration.FunctionArn" --output text)

aws $PROFILE_FLAG apigateway put-integration \
  --region "$AWS_REGION" \
  --rest-api-id "$APIGW_ID" \
  --resource-id "$APPROVE_RESOURCE_ID" \
  --http-method GET \
  --type AWS_PROXY \
  --integration-http-method POST \
  --uri "arn:aws:apigateway:${AWS_REGION}:lambda:path/2015-03-31/functions/${APPROVE_LAMBDA_ARN}/invocations" \
  > /dev/null

aws $PROFILE_FLAG apigateway create-deployment \
  --region "$AWS_REGION" \
  --rest-api-id "$APIGW_ID" \
  --stage-name "prod" > /dev/null

API_URL="https://${APIGW_ID}.execute-api.${AWS_REGION}.amazonaws.com/prod"
put_param "api-gateway-url" "$API_URL"
put_param "api-gateway-id"  "$APIGW_ID"

aws $PROFILE_FLAG lambda add-permission \
  --region "$AWS_REGION" \
  --function-name "gpu-watcher-approve-${PIPELINE_RUN_ID}" \
  --statement-id "apigw-invoke" \
  --action "lambda:InvokeFunction" \
  --principal "apigateway.amazonaws.com" \
  --source-arn "arn:aws:execute-api:${AWS_REGION}:${AWS_ACCOUNT_ID}:${APIGW_ID}/*/*/approve" \
  > /dev/null

ok "API Gateway created: $API_URL"

# ── Step 6: Create Step Functions state machine ───────────────────────────────
header "6 / 8  Creating Step Functions state machine"

SF_TRUST_JSON='{"Version":"2012-10-17","Statement":[{"Effect":"Allow","Principal":{"Service":"states.amazonaws.com"},"Action":"sts:AssumeRole"}]}'

SF_ROLE_ARN=$(aws $PROFILE_FLAG iam create-role \
  --role-name "gpu-watcher-sf-role-${PIPELINE_RUN_ID}" \
  --assume-role-policy-document "$SF_TRUST_JSON" \
  --tags Key=CreatedBy,Value=watcher Key=PipelineRunId,Value="$PIPELINE_RUN_ID" \
  --query "Role.Arn" --output text 2>/dev/null || \
  aws $PROFILE_FLAG iam get-role \
  --role-name "gpu-watcher-sf-role-${PIPELINE_RUN_ID}" \
  --query "Role.Arn" --output text)

SF_PERMS_JSON='{"Version":"2012-10-17","Statement":[{"Effect":"Allow","Action":["lambda:InvokeFunction","xray:PutTraceSegments","logs:*"],"Resource":"*"}]}'
aws $PROFILE_FLAG iam put-role-policy \
  --role-name "gpu-watcher-sf-role-${PIPELINE_RUN_ID}" \
  --policy-name "gpu-sf-policy" \
  --policy-document "$SF_PERMS_JSON" > /dev/null

sleep 10

DISCOVERY_ARN=$(aws $PROFILE_FLAG lambda get-function \
  --region "$AWS_REGION" \
  --function-name "gpu-watcher-discovery-${PIPELINE_RUN_ID}" \
  --query "Configuration.FunctionArn" --output text)

NOTIFY_ARN=$(aws $PROFILE_FLAG lambda get-function \
  --region "$AWS_REGION" \
  --function-name "gpu-watcher-notify-${PIPELINE_RUN_ID}" \
  --query "Configuration.FunctionArn" --output text)

CLEANUP_ARN=$(aws $PROFILE_FLAG lambda get-function \
  --region "$AWS_REGION" \
  --function-name "gpu-watcher-cleanup-${PIPELINE_RUN_ID}" \
  --query "Configuration.FunctionArn" --output text)

RETRY_MINS_SECS=$((RETRY_MINS * 60))
# 4 hours in seconds for approval waits
APPROVAL_WAIT_SECS=14400

# =============================================================================
# UPDATED Step Functions definition
#
# OLD states removed:
#   SendAZEmails, WaitForApproval, RouteApproval, SendReminder
#
# NEW states:
#   SendCapacityFoundEmail — triggers notify Lambda (single PROCEED email)
#   WaitForProceed         — waits up to 4h for user to click PROCEED
#   CheckProceedResult     — polls SSM for approval-decision
#   RouteProceed           — routes on proceed / cancelled / pending
#   WaitForConfirm         — waits up to 30min for CONFIRM PURCHASE click
#   CheckConfirmResult     — polls SSM for confirmed / cancelled / pending
#   RouteConfirm           — routes on confirmed / cancelled / pending
#
# NOT found path — unchanged:
#   WaitForNextRetry → RunDiscovery (loops every 15 min)
#
# Timeout path — unchanged:
#   Send48HourEmail → WaitForRetryOrQuit → CheckRetryOrQuit → route
# =============================================================================

SM_DEFINITION="{
  \"Comment\": \"GPU Capacity Block 48-hour watcher — simplified approval flow\",
  \"StartAt\": \"RunDiscovery\",
  \"States\": {

    \"RunDiscovery\": {
      \"Type\": \"Task\",
      \"Resource\": \"${DISCOVERY_ARN}\",
      \"Parameters\": {
        \"pipelineRunId\": \"${PIPELINE_RUN_ID}\",
        \"action\": \"discover\"
      },
      \"ResultPath\": \"$.discoveryResult\",
      \"Next\": \"CheckDiscoveryResult\",
      \"Catch\": [{
        \"ErrorEquals\": [\"States.ALL\"],
        \"Next\": \"DiscoveryFailed\"
      }]
    },

    \"CheckDiscoveryResult\": {
      \"Type\": \"Choice\",
      \"Choices\": [
        {
          \"Variable\": \"$.discoveryResult.found\",
          \"BooleanEquals\": true,
          \"Next\": \"SendCapacityFoundEmail\"
        },
        {
          \"Variable\": \"$.discoveryResult.timeout\",
          \"BooleanEquals\": true,
          \"Next\": \"Send48HourEmail\"
        }
      ],
      \"Default\": \"WaitForNextRetry\"
    },

    \"WaitForNextRetry\": {
      \"Type\": \"Wait\",
      \"Seconds\": ${RETRY_MINS_SECS},
      \"Next\": \"RunDiscovery\"
    },

    \"SendCapacityFoundEmail\": {
      \"Type\": \"Task\",
      \"Resource\": \"${NOTIFY_ARN}\",
      \"Parameters\": {
        \"pipelineRunId\": \"${PIPELINE_RUN_ID}\",
        \"action\": \"notify_found\"
      },
      \"ResultPath\": \"$.notifyResult\",
      \"Next\": \"WaitForProceed\",
      \"Catch\": [{
        \"ErrorEquals\": [\"States.ALL\"],
        \"Next\": \"DiscoveryFailed\"
      }]
    },

    \"WaitForProceed\": {
      \"Type\": \"Wait\",
      \"Seconds\": ${APPROVAL_WAIT_SECS},
      \"Next\": \"CheckProceedResult\"
    },

    \"CheckProceedResult\": {
      \"Type\": \"Task\",
      \"Resource\": \"${DISCOVERY_ARN}\",
      \"Parameters\": {
        \"pipelineRunId\": \"${PIPELINE_RUN_ID}\",
        \"action\": \"check_approval\"
      },
      \"ResultPath\": \"$.proceedResult\",
      \"Next\": \"RouteProceed\"
    },

    \"RouteProceed\": {
      \"Type\": \"Choice\",
      \"Choices\": [
        {
          \"Variable\": \"$.proceedResult.decision\",
          \"StringEquals\": \"proceed\",
          \"Next\": \"WaitForConfirm\"
        },
        {
          \"Variable\": \"$.proceedResult.decision\",
          \"StringEquals\": \"confirmed\",
          \"Next\": \"PipelineApproved\"
        },
        {
          \"Variable\": \"$.proceedResult.decision\",
          \"StringEquals\": \"cancelled\",
          \"Next\": \"CleanupAndExit\"
        }
      ],
      \"Default\": \"WaitForNextRetry\"
    },

    \"WaitForConfirm\": {
      \"Type\": \"Wait\",
      \"Seconds\": 1800,
      \"Next\": \"CheckConfirmResult\"
    },

    \"CheckConfirmResult\": {
      \"Type\": \"Task\",
      \"Resource\": \"${DISCOVERY_ARN}\",
      \"Parameters\": {
        \"pipelineRunId\": \"${PIPELINE_RUN_ID}\",
        \"action\": \"check_approval\"
      },
      \"ResultPath\": \"$.confirmResult\",
      \"Next\": \"RouteConfirm\"
    },

    \"RouteConfirm\": {
      \"Type\": \"Choice\",
      \"Choices\": [
        {
          \"Variable\": \"$.confirmResult.decision\",
          \"StringEquals\": \"confirmed\",
          \"Next\": \"PipelineApproved\"
        },
        {
          \"Variable\": \"$.confirmResult.decision\",
          \"StringEquals\": \"cancelled\",
          \"Next\": \"CleanupAndExit\"
        }
      ],
      \"Default\": \"WaitForConfirm\"
    },

    \"PipelineApproved\": {
      \"Type\": \"Pass\",
      \"Result\": \"approved\",
      \"End\": true
    },

    \"Send48HourEmail\": {
      \"Type\": \"Task\",
      \"Resource\": \"${NOTIFY_ARN}\",
      \"Parameters\": {
        \"pipelineRunId\": \"${PIPELINE_RUN_ID}\",
        \"action\": \"notify_timeout\"
      },
      \"ResultPath\": \"$.timeoutResult\",
      \"Next\": \"WaitForRetryOrQuit\"
    },

    \"WaitForRetryOrQuit\": {
      \"Type\": \"Wait\",
      \"Seconds\": ${APPROVAL_WAIT_SECS},
      \"Next\": \"CheckRetryOrQuit\"
    },

    \"CheckRetryOrQuit\": {
      \"Type\": \"Task\",
      \"Resource\": \"${DISCOVERY_ARN}\",
      \"Parameters\": {
        \"pipelineRunId\": \"${PIPELINE_RUN_ID}\",
        \"action\": \"check_retry_quit\"
      },
      \"ResultPath\": \"$.retryResult\",
      \"Next\": \"RouteRetryOrQuit\"
    },

    \"RouteRetryOrQuit\": {
      \"Type\": \"Choice\",
      \"Choices\": [
        {
          \"Variable\": \"$.retryResult.decision\",
          \"StringEquals\": \"retry\",
          \"Next\": \"ResetAndRetry\"
        },
        {
          \"Variable\": \"$.retryResult.decision\",
          \"StringEquals\": \"quit\",
          \"Next\": \"CleanupAndExit\"
        }
      ],
      \"Default\": \"CleanupAndExit\"
    },

    \"ResetAndRetry\": {
      \"Type\": \"Task\",
      \"Resource\": \"${DISCOVERY_ARN}\",
      \"Parameters\": {
        \"pipelineRunId\": \"${PIPELINE_RUN_ID}\",
        \"action\": \"reset_watcher\"
      },
      \"Next\": \"RunDiscovery\"
    },

    \"CleanupAndExit\": {
      \"Type\": \"Task\",
      \"Resource\": \"${CLEANUP_ARN}\",
      \"Parameters\": {
        \"pipelineRunId\": \"${PIPELINE_RUN_ID}\",
        \"reason\": \"user_exit\"
      },
      \"End\": true
    },

    \"DiscoveryFailed\": {
      \"Type\": \"Task\",
      \"Resource\": \"${NOTIFY_ARN}\",
      \"Parameters\": {
        \"pipelineRunId\": \"${PIPELINE_RUN_ID}\",
        \"action\": \"notify_error\"
      },
      \"Next\": \"CleanupAndExit\"
    }

  }
}"

SM_ARN=$(aws $PROFILE_FLAG stepfunctions create-state-machine \
  --region "$AWS_REGION" \
  --name "$SM_NAME" \
  --definition "$SM_DEFINITION" \
  --role-arn "$SF_ROLE_ARN" \
  --tags key=CreatedBy,value=watcher key=PipelineRunId,value="$PIPELINE_RUN_ID" \
  --query "stateMachineArn" --output text)

ok "Step Functions state machine created: $SM_ARN"
put_param "state-machine-arn" "$SM_ARN"

# ── Step 7: Start execution ───────────────────────────────────────────────────
header "7 / 8  Starting Step Functions execution"

EXECUTION_ARN=$(aws $PROFILE_FLAG stepfunctions start-execution \
  --region "$AWS_REGION" \
  --state-machine-arn "$SM_ARN" \
  --name "run-$(date +%Y%m%d-%H%M%S)" \
  --input "{\"pipelineRunId\":\"${PIPELINE_RUN_ID}\"}" \
  --query "executionArn" --output text)

ok "Execution started: $EXECUTION_ARN"
put_param "execution-arn" "$EXECUTION_ARN"

# ── Step 8: Save watcher details ──────────────────────────────────────────────
header "8 / 8  Saving watcher details to config.env"

patch_config "WATCHER_STATE_MACHINE_ARN" "$SM_ARN"
patch_config "WATCHER_DYNAMODB_TABLE"    "$TABLE_NAME"
patch_config "WATCHER_API_GATEWAY_URL"   "$API_URL"
patch_config "WATCHER_LAMBDA_ROLE_ARN"   "$LAMBDA_ROLE_ARN"

echo ""
ok "All watcher services deployed"
echo ""
info "Pipeline Run ID : $PIPELINE_RUN_ID"
info "State Machine   : $SM_ARN"
info "DynamoDB Table  : $TABLE_NAME"
info "API Gateway     : $API_URL"
info "SSM Prefix      : $SSM_PREFIX"
echo ""
info "New email flow:"
info "  Capacity found  →  single email with PROCEED link"
info "  PROCEED clicked →  final confirmation email (CONFIRM / CANCEL)"
info "  CONFIRM clicked →  purchase + launch"
info "  Ignore email    →  scan continues automatically every ${RETRY_MINS} min"
info ""
info "Monitor at: AWS Console → Step Functions → $SM_NAME"