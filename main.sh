#!/usr/bin/env bash
# ── Windows Git Bash path fix ─────────────────────────────────────────────────
# Prevents Git Bash converting /unix/paths to C:/Windows/paths for AWS CLI
export MSYS_NO_PATHCONV=1
export MSYS2_ARG_CONV_EXCL="*"
# =============================================================================
# main.sh — AWS GPU Capacity Block Reservation Pipeline — Entry Point
# Usage:  bash main.sh            (full pipeline)
#         bash main.sh --dry-run  (audit only, no AWS writes)
# =============================================================================

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CONFIG_FILE="${SCRIPT_DIR}/config.env"

# ── Dry-run flag ──────────────────────────────────────────────────────────────
DRY_RUN=false
for arg in "$@"; do [[ "$arg" == "--dry-run" ]] && DRY_RUN=true; done

# ── Colors ────────────────────────────────────────────────────────────────────
RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'
CYAN='\033[0;36m'; BOLD='\033[1m'; NC='\033[0m'

ok()     { echo -e "${GREEN}  ✔  $*${NC}"; }
info()   { echo -e "${CYAN}  ℹ  $*${NC}"; }
warn()   { echo -e "${YELLOW}  ⚠  $*${NC}"; }
fail()   { echo -e "${RED}  ✖  $*${NC}"; }
header() { echo -e "\n${BOLD}━━━━━  $*  ━━━━━${NC}"; }
dryrun() { echo -e "${CYAN}  [DRY-RUN] $*${NC}"; }

echo ""
echo -e "${BOLD}╔══════════════════════════════════════════════════════════╗${NC}"
echo -e "${BOLD}║     AWS GPU Capacity Block Reservation Pipeline          ║${NC}"
echo -e "${BOLD}╚══════════════════════════════════════════════════════════╝${NC}"
[[ "$DRY_RUN" == true ]] && echo -e "${CYAN}  [DRY-RUN MODE] — no resources will be created${NC}"
echo ""

# ── Step 1: Load config.env ───────────────────────────────────────────────────
header "Step 1 / 6  Loading config.env"

[[ ! -f "$CONFIG_FILE" ]] && { fail "config.env not found at $CONFIG_FILE"; exit 1; }

CLEAN_ENV="/tmp/config_clean_$$.env"
sed 's/\r//' "$CONFIG_FILE" > "$CLEAN_ENV"
set +u; source "$CLEAN_ENV"; set -u
rm -f "$CLEAN_ENV"

ok "config.env loaded"
info "Account : ${AWS_ACCOUNT_ID:-not set}"
info "Region  : ${AWS_REGION:-not set}"
info "Types   : ${INSTANCE_TYPES:-not set}"
info "Count   : ${INSTANCE_COUNT:-not set}"
info "Regions : ${REGIONS:-not set}"
info "AZs     : ${AVAILABILITY_ZONES:-not set}"

# Validate required fields
[[ -z "${AWS_ACCOUNT_ID:-}" ]] && { fail "AWS_ACCOUNT_ID not set in config.env"; exit 1; }
[[ -z "${ALERT_EMAIL:-}" ]]    && { fail "ALERT_EMAIL not set in config.env"; exit 1; }
[[ -z "${INSTANCE_TYPES:-}" ]] && { fail "INSTANCE_TYPES not set in config.env"; exit 1; }
[[ -z "${REGIONS:-}" ]]        && { fail "REGIONS not set in config.env"; exit 1; }
[[ -z "${AVAILABILITY_ZONES:-}" ]] && { fail "AVAILABILITY_ZONES not set in config.env"; exit 1; }

# ── Step 2: Check AWS CLI and credentials ─────────────────────────────────────
header "Step 2 / 6  Verifying AWS credentials"

command -v aws &>/dev/null || { fail "AWS CLI not found. Install from https://docs.aws.amazon.com/cli/latest/userguide/install-cliv2.html"; exit 1; }
command -v python3 &>/dev/null || { fail "Python 3 not found. Install from https://www.python.org/"; exit 1; }
command -v git &>/dev/null || { fail "Git not found. Install git before running this pipeline."; exit 1; }

PROFILE_FLAG=""
[[ -n "${AWS_PROFILE:-}" ]] && PROFILE_FLAG="--profile ${AWS_PROFILE}"

CALLER_ID=$(aws $PROFILE_FLAG sts get-caller-identity --output json 2>&1) || {
  fail "AWS credentials invalid or expired."
  fail "Run: aws configure  or  export AWS_ACCESS_KEY_ID / AWS_SECRET_ACCESS_KEY"
  exit 1
}

ACCOUNT_ID=$(echo "$CALLER_ID" | python3 -c "import sys,json; print(json.load(sys.stdin)['Account'])")
CALLER_ARN=$(echo "$CALLER_ID" | python3 -c "import sys,json; print(json.load(sys.stdin)['Arn'])")
ok "Connected — Account: $ACCOUNT_ID"
info "Caller  : $CALLER_ARN"

# ── Step 3: Clone / update official AWS capacity finder repo ──────────────────
header "Step 3 / 6  AWS Capacity Finder Repo"

AWS_REPO_URL="https://github.com/aws-samples/sample-capacity-finder-for-ec2-capacity-block-and-sagemaker-training-plan"
FINDER_DIR="${SCRIPT_DIR}/capacity-finder"

# Use pushd/popd instead of git -C to avoid Windows path conversion issues
if [[ ! -d "$FINDER_DIR/.git" ]]; then
  # Directory missing or not a git repo — clone fresh
  info "Cloning official AWS capacity finder repo..."
  if [[ "$DRY_RUN" == true ]]; then
    dryrun "git clone $AWS_REPO_URL $FINDER_DIR"
  else
    # Remove partial directory if it exists but has no .git
    [[ -d "$FINDER_DIR" && ! -d "$FINDER_DIR/.git" ]] && rm -rf "$FINDER_DIR"
    git clone "$AWS_REPO_URL" "$FINDER_DIR"
    ok "Repo cloned → $FINDER_DIR"
  fi
else
  # Directory exists and is a git repo — update it
  info "Updating AWS capacity finder repo (git pull)..."
  if [[ "$DRY_RUN" == true ]]; then
    dryrun "cd $FINDER_DIR && git pull"
  else
    # Use pushd/popd instead of git -C — works correctly on Windows Git Bash
    pushd "$FINDER_DIR" > /dev/null
    git pull --quiet 2>/dev/null || warn "git pull failed — using existing repo version"
    popd > /dev/null
    ok "Repo updated — latest app.py from AWS"
  fi
fi

# Install dependencies from AWS repo
if [[ "$DRY_RUN" == false && -f "${FINDER_DIR}/requirements.txt" ]]; then
  info "Installing capacity-finder dependencies..."
  pip install -q -r "${FINDER_DIR}/requirements.txt" --break-system-packages 2>/dev/null || \
  pip install -q -r "${FINDER_DIR}/requirements.txt" 2>/dev/null || true
  ok "Dependencies installed"
fi

# ── Step 4: Build combination list ───────────────────────────────────────────
header "Step 4 / 6  Building combination list"

COMBO_COUNT=0
> /tmp/combinations_$$.txt

IFS=',' read -ra TYPES   <<< "$INSTANCE_TYPES"
IFS=',' read -ra REGIONS_LIST <<< "$REGIONS"
IFS=',' read -ra AZS     <<< "$AVAILABILITY_ZONES"

for ITYPE in "${TYPES[@]}"; do
  for i in "${!REGIONS_LIST[@]}"; do
    IREGION=$(echo "${REGIONS_LIST[$i]}" | tr -d ' ')
    IAZ=$(echo "${AZS[$i]:-${REGIONS_LIST[$i]}a}" | tr -d ' ')
    COMBO="${ITYPE}|${IREGION}|${IAZ}"
    # Deduplicate
    if ! grep -qF "$COMBO" /tmp/combinations_$$.txt 2>/dev/null; then
      echo "$COMBO" >> /tmp/combinations_$$.txt
      COMBO_COUNT=$((COMBO_COUNT + 1))
      info "Combination $COMBO_COUNT: $ITYPE in $IREGION / $IAZ"
    fi
  done
done

COMBINATIONS=$(cat /tmp/combinations_$$.txt | grep -v "^$" | tr '\n' ';' | sed 's/;$//')
rm -f /tmp/combinations_$$.txt
ok "$COMBO_COUNT combination(s) registered"

# ── Step 5: Run aws_check_create.sh ──────────────────────────────────────────
header "Step 5 / 6  Infrastructure (aws_check_create.sh)"

CHECK_SCRIPT="${SCRIPT_DIR}/aws_check_create.sh"
[[ ! -f "$CHECK_SCRIPT" ]] && { fail "aws_check_create.sh not found in $SCRIPT_DIR"; exit 1; }

chmod +x "$CHECK_SCRIPT"
if [[ "$DRY_RUN" == true ]]; then
  bash "$CHECK_SCRIPT" --dry-run
else
  bash "$CHECK_SCRIPT"
fi

# Re-source config after aws_check_create.sh fills in resource IDs
CLEAN_ENV="/tmp/config_clean2_$$.env"
sed 's/\r//' "$CONFIG_FILE" > "$CLEAN_ENV"
set +u; source "$CLEAN_ENV"; set -u
rm -f "$CLEAN_ENV"
ok "config.env re-sourced with new resource IDs"

# ── Step 6: Deploy watcher and start Step Functions ───────────────────────────
header "Step 6 / 6  Deploying watcher services and starting pipeline"

DEPLOY_SCRIPT="${SCRIPT_DIR}/watcher/deploy_watcher.sh"
[[ ! -f "$DEPLOY_SCRIPT" ]] && { fail "watcher/deploy_watcher.sh not found"; exit 1; }

chmod +x "$DEPLOY_SCRIPT"
if [[ "$DRY_RUN" == true ]]; then
  bash "$DEPLOY_SCRIPT" --dry-run \
    --combinations "$COMBINATIONS" \
    --instance-count "${INSTANCE_COUNT}" \
    --duration-days "${DURATION_DAYS}" \
    --start-date "${START_DATE}" \
    --alert-email "${ALERT_EMAIL}" \
    --retry-mins "${RETRY_INTERVAL_MINS:-15}" \
    --max-hours "${MAX_RETRY_HOURS:-48}"
else
  bash "$DEPLOY_SCRIPT" \
    --combinations "$COMBINATIONS" \
    --instance-count "${INSTANCE_COUNT}" \
    --duration-days "${DURATION_DAYS}" \
    --start-date "${START_DATE}" \
    --alert-email "${ALERT_EMAIL}" \
    --retry-mins "${RETRY_INTERVAL_MINS:-15}" \
    --max-hours "${MAX_RETRY_HOURS:-48}"
fi

# ── Final message ─────────────────────────────────────────────────────────────
echo ""
echo -e "${BOLD}╔══════════════════════════════════════════════════════════╗${NC}"
echo -e "${BOLD}║              PIPELINE STARTED SUCCESSFULLY               ║${NC}"
echo -e "${BOLD}╚══════════════════════════════════════════════════════════╝${NC}"
echo ""
ok "You can now close your laptop."
ok "All processes are running in AWS."
echo ""
info "What happens next:"
info "  • The watcher scans for capacity every ${RETRY_INTERVAL_MINS:-15} minutes"
info "  • You will receive an email at ${ALERT_EMAIL} when capacity is found"
info "  • All approvals are made through email links only"
info "  • The dashboard is read-only: streamlit run dashboard.py"
echo ""
info "Monitoring:"
info "  • AWS Console → Step Functions → gpu-capacity-pipeline"
info "  • AWS Console → DynamoDB → gpu-watcher-state"
info "  • AWS Console → CloudWatch → Log groups → /gpu-watcher"
echo ""