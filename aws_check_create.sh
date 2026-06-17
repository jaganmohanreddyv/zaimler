#!/usr/bin/env bash
# =============================================================================
# aws_check_create.sh  —  Windows Git Bash compatible (no Python required)
# Checks all resources in config.env, creates missing ones, patches the file.
#
# CHANGES FROM ORIGINAL:
#  FIX-1  SSH CIDR: auto-detects your public IP, blocks 0.0.0.0/0 default
#  FIX-2  IAM action: ec2:CreateCapacityReservation → ec2:PurchaseCapacityBlock
#          + added ec2:DescribeCapacityBlockOfferings (needed by app.py)
#  FIX-3  Temp file cleanup trap — files removed on any exit (error or normal)
#  FIX-4  Timestamped config backups — no longer overwritten on each patch
#  FIX-5  Windows path conversion uses pure bash — no cmd.exe dependency
#  FIX-6  AWS CLI error capture pattern — avoids set -e false triggers
#  FIX-7  SNS: warns loudly if topic has zero confirmed subscriptions
#  NEW-1  Section 3.5 — Cluster placement group (required for p5/p4d/trn2)
#  NEW-2  Section 7   — Launch template with CapacityReservationTarget
#  NEW-3  --dry-run flag: audit-only mode, no AWS resources created
#  NEW-4  Section 7   — Instance type mismatch detection: compares $Latest
#          version against config.env INSTANCE_TYPES. If different, creates a
#          new version automatically. Default version never changed — pipeline
#          always uses $Latest via launch.sh (Version=$Latest).
# =============================================================================

set -euo pipefail

# ── Dry-run flag ──────────────────────────────────────────────────────────────
DRY_RUN=false
for arg in "$@"; do
  [[ "$arg" == "--dry-run" ]] && DRY_RUN=true
done

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CONFIG_FILE="${SCRIPT_DIR}/config.env"

if [[ ! -f "$CONFIG_FILE" ]]; then
  echo "ERROR: config.env not found at $CONFIG_FILE"
  echo "Place this script in the same folder as config.env and re-run."
  exit 1
fi

# ── Source config ─────────────────────────────────────────────────────────────
set +u
CLEAN_ENV="/tmp/config_clean_$$.env"
sed 's/\r//' "$CONFIG_FILE" > "$CLEAN_ENV"
source "$CLEAN_ENV"
rm -f "$CLEAN_ENV"
set -u

# ── Colors ────────────────────────────────────────────────────────────────────
RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'
CYAN='\033[0;36m'; BOLD='\033[1m'; NC='\033[0m'

ok()     { echo -e "${GREEN}  ✔  $*${NC}"; }
warn()   { echo -e "${YELLOW}  ⚠  $*${NC}"; }
info()   { echo -e "${CYAN}  ℹ  $*${NC}"; }
fail()   { echo -e "${RED}  ✖  $*${NC}"; }
header() { echo -e "\n${BOLD}━━━━━  $*  ━━━━━${NC}"; }
dryrun() { echo -e "${CYAN}  [DRY-RUN] would: $*${NC}"; }

# ── Temp file cleanup trap ────────────────────────────────────────────────────
CLEANUP_FILES=()
cleanup() { rm -f "${CLEANUP_FILES[@]}" 2>/dev/null || true; }
trap cleanup EXIT

# ── Timestamped patch_config ──────────────────────────────────────────────────
patch_config() {
  local key="$1" value="$2"
  local ts; ts=$(date +%Y%m%d_%H%M%S)
  cp "$CONFIG_FILE" "${CONFIG_FILE}.bak.${ts}"
  if grep -q "^${key}=" "$CONFIG_FILE"; then
    sed -i "s|^${key}=.*|${key}=\"${value}\"|" "$CONFIG_FILE"
  else
    echo "${key}=\"${value}\"" >> "$CONFIG_FILE"
  fi
  info "config.env → ${key}=\"${value}\"  (backup: .bak.${ts})"
}

# ── Pure-bash Windows path helper ─────────────────────────────────────────────
to_win_path() {
  local p="$1"
  if [[ "$(uname -s)" == MINGW* || "$(uname -s)" == CYGWIN* ]]; then
    echo "$p" | sed 's|^/\([a-zA-Z]\)/|\u\1:\\|; s|/|\\|g'
  else
    echo "$p"
  fi
}

# ── AWS CLI sanity check ──────────────────────────────────────────────────────
if ! command -v aws &>/dev/null; then
  fail "AWS CLI not found."
  exit 1
fi

REGION="${AWS_REGION:-us-east-1}"
AZ="${AVAILABILITY_ZONE:-us-east-1a}"

PROFILE_FLAG=""
if [[ -n "${AWS_PROFILE:-}" ]]; then
  PROFILE_FLAG="--profile ${AWS_PROFILE}"
fi

aws_cmd()  { aws $PROFILE_FLAG --region "$REGION" --output text "$@"; }
aws_iam()  { aws $PROFILE_FLAG --output text "$@"; }
aws_safe() { aws_cmd "$@" 2>/dev/null || true; }

echo ""
if [[ "$DRY_RUN" == true ]]; then
  echo -e "${CYAN}${BOLD}  [DRY-RUN MODE] — no resources will be created${NC}"
fi
echo -e "${BOLD}  GPU Deployment — AWS Resource Audit${NC}"
echo -e "  Account: ${AWS_ACCOUNT_ID:-?}  |  Region: $REGION  |  AZ: $AZ"
echo    "  ──────────────────────────────────────────────────"

echo -e "\n${BOLD}  Verifying AWS credentials…${NC}"
ACCOUNT_ID=$(aws_cmd sts get-caller-identity --query "Account" 2>&1) || {
  fail "AWS credentials not configured or expired. Run: aws configure"
  exit 1
}
ok "Connected — account: $ACCOUNT_ID"

declare -a FOUND=() CREATED=() SKIPPED=()

# =============================================================================
# 1. KEY PAIR
# =============================================================================
header "1 / 8  Key Pair"

CURRENT_KEY="${KEY_PAIR_NAME:-}"
KEY_EXISTS=false

if [[ -n "$CURRENT_KEY" ]]; then
  KP=$(aws_safe ec2 describe-key-pairs \
        --key-names "$CURRENT_KEY" \
        --query "KeyPairs[0].KeyName")
  if [[ -n "$KP" && "$KP" != "None" ]]; then
    ok "Key pair '$KP' exists."
    KEY_EXISTS=true
    FOUND+=("Key pair: $KP")
  else
    warn "Key pair '$CURRENT_KEY' NOT found in $REGION."
  fi
else
  warn "KEY_PAIR_NAME is empty."
fi

if [[ "$KEY_EXISTS" == false ]]; then
  echo ""
  read -rp "  Name for new key pair [gpu-key]: " NEW_KEY_NAME
  NEW_KEY_NAME="${NEW_KEY_NAME:-gpu-key}"
  KEY_FILE="./${NEW_KEY_NAME}.pem"

  if [[ "$DRY_RUN" == true ]]; then
    dryrun "ec2 create-key-pair --key-name $NEW_KEY_NAME → $KEY_FILE"
    SKIPPED+=("Key pair: $NEW_KEY_NAME (dry-run)")
  else
    KEY_MATERIAL=$(aws_cmd ec2 create-key-pair \
      --key-name "$NEW_KEY_NAME" \
      --query "KeyMaterial" 2>&1) || {
      fail "AWS rejected key pair creation: $KEY_MATERIAL"
      exit 1
    }
    if [[ -z "$KEY_MATERIAL" || "$KEY_MATERIAL" == "None" ]]; then
      fail "Key pair created but private key was empty."
      exit 1
    fi
    printf '%s\n' "$KEY_MATERIAL" > "$KEY_FILE"
    chmod 400 "$KEY_FILE"
    ok "Key pair '$NEW_KEY_NAME' created → $KEY_FILE"
    warn "KEEP THIS .pem FILE SAFE — it cannot be downloaded again."
    patch_config "KEY_PAIR_NAME" "$NEW_KEY_NAME"
    CREATED+=("Key pair: $NEW_KEY_NAME  →  $KEY_FILE")
  fi
fi

# =============================================================================
# 2. SUBNET
# =============================================================================
header "2 / 8  Subnet"

CURRENT_SUBNET="${SUBNET_ID:-}"
SUBNET_EXISTS=false

if [[ -n "$CURRENT_SUBNET" ]]; then
  SUBNET_LINE=$(aws_safe ec2 describe-subnets \
    --subnet-ids "$CURRENT_SUBNET" \
    --query "Subnets[0].[AvailabilityZone,State,AvailableIpAddressCount]")
  if [[ -n "$SUBNET_LINE" && "$SUBNET_LINE" != "None" ]]; then
    SUBNET_AZ=$(echo "$SUBNET_LINE"    | awk '{print $1}')
    SUBNET_STATE=$(echo "$SUBNET_LINE" | awk '{print $2}')
    SUBNET_FREE=$(echo "$SUBNET_LINE"  | awk '{print $3}')
    ok "Subnet '$CURRENT_SUBNET' exists  (AZ: $SUBNET_AZ, State: $SUBNET_STATE, Free IPs: $SUBNET_FREE)"
    SUBNET_EXISTS=true
    FOUND+=("Subnet: $CURRENT_SUBNET  AZ=$SUBNET_AZ")
    [[ "$SUBNET_AZ" != "$AZ" ]] && \
      warn "Subnet AZ ($SUBNET_AZ) ≠ AVAILABILITY_ZONE ($AZ) — Capacity Block launch will fail if they differ."
  else
    warn "Subnet '$CURRENT_SUBNET' NOT found."
  fi
else
  warn "SUBNET_ID is empty."
fi

if [[ "$SUBNET_EXISTS" == false ]]; then
  DEFAULT_VPC=$(aws_safe ec2 describe-vpcs \
    --filters "Name=isDefault,Values=true" \
    --query "Vpcs[0].VpcId")
  [[ -z "$DEFAULT_VPC" || "$DEFAULT_VPC" == "None" ]] && DEFAULT_VPC=""

  info "Scanning all VPCs for available subnets in region $REGION..."

  ALL_RAW=$(aws_safe ec2 describe-subnets \
    --filters "Name=state,Values=available" \
    --query "Subnets[*].[SubnetId,AvailabilityZone,CidrBlock,VpcId,DefaultForAz]" \
    2>/dev/null | tr '\t' '|' || echo "")

  if [[ -z "$ALL_RAW" ]]; then
    fail "No available subnets found in region $REGION."
    SKIPPED+=("Subnet: no subnets found — manual action required")
  else
    declare -a PREF_IDS=()  PREF_AZS=()  PREF_CIDRS=()  PREF_VPCS=()  PREF_DEFS=()
    declare -a OTHER_IDS=() OTHER_AZS=() OTHER_CIDRS=() OTHER_VPCS=() OTHER_DEFS=()

    while IFS='|' read -r SID SAZ SCIDR SVPC SDEF; do
      [[ -z "$SID" || "$SID" == "None" ]] && continue
      if [[ "$SAZ" == "$AZ" ]]; then
        PREF_IDS+=("$SID");  PREF_AZS+=("$SAZ");  PREF_CIDRS+=("$SCIDR")
        PREF_VPCS+=("$SVPC"); PREF_DEFS+=("$SDEF")
      else
        OTHER_IDS+=("$SID");  OTHER_AZS+=("$SAZ");  OTHER_CIDRS+=("$SCIDR")
        OTHER_VPCS+=("$SVPC"); OTHER_DEFS+=("$SDEF")
      fi
    done <<< "$ALL_RAW"

    echo ""
    echo -e "${BOLD}  Available subnets — choose one:${NC}"
    echo ""

    IDX=1
    declare -a MENU_IDS=() MENU_AZS=() MENU_VPCS=()

    if [[ ${#PREF_IDS[@]} -gt 0 ]]; then
      echo -e "  ${GREEN}── Subnets in your target AZ ($AZ) ──────────────────────────${NC}"
      for i in "${!PREF_IDS[@]}"; do
        VPC_LABEL="${PREF_VPCS[$i]}"
        [[ "${PREF_VPCS[$i]}" == "$DEFAULT_VPC" ]] && VPC_LABEL="${PREF_VPCS[$i]} [DEFAULT VPC]"
        DEF_LABEL=""
        [[ "${PREF_DEFS[$i]}" == "True" ]] && DEF_LABEL=" [defaultForAz]"
        printf "  ${GREEN}[%d]${NC}  %-26s  AZ: %-12s  CIDR: %-18s  VPC: %s%s\n" \
          "$IDX" "${PREF_IDS[$i]}" "${PREF_AZS[$i]}" "${PREF_CIDRS[$i]}" "$VPC_LABEL" "$DEF_LABEL"
        MENU_IDS+=("${PREF_IDS[$i]}")
        MENU_AZS+=("${PREF_AZS[$i]}")
        MENU_VPCS+=("${PREF_VPCS[$i]}")
        IDX=$((IDX+1))
      done
      echo ""
    fi

    if [[ ${#OTHER_IDS[@]} -gt 0 ]]; then
      echo -e "  ${YELLOW}── Subnets in other AZs ──────────────────────────────────────${NC}"
      for i in "${!OTHER_IDS[@]}"; do
        VPC_LABEL="${OTHER_VPCS[$i]}"
        [[ "${OTHER_VPCS[$i]}" == "$DEFAULT_VPC" ]] && VPC_LABEL="${OTHER_VPCS[$i]} [DEFAULT VPC]"
        DEF_LABEL=""
        [[ "${OTHER_DEFS[$i]}" == "True" ]] && DEF_LABEL=" [defaultForAz]"
        printf "  ${YELLOW}[%d]${NC}  %-26s  AZ: %-12s  CIDR: %-18s  VPC: %s%s\n" \
          "$IDX" "${OTHER_IDS[$i]}" "${OTHER_AZS[$i]}" "${OTHER_CIDRS[$i]}" "$VPC_LABEL" "$DEF_LABEL"
        MENU_IDS+=("${OTHER_IDS[$i]}")
        MENU_AZS+=("${OTHER_AZS[$i]}")
        MENU_VPCS+=("${OTHER_VPCS[$i]}")
        IDX=$((IDX+1))
      done
      echo ""
    fi

    TOTAL_OPTIONS=${#MENU_IDS[@]}

    if [[ $TOTAL_OPTIONS -eq 1 ]]; then
      CHOSEN_IDX=0
      info "Only one subnet available — selecting automatically."
    else
      echo -e "  ${CYAN}[c]${NC}  Enter a custom subnet ID not listed above"
      echo ""
      while true; do
        read -rp "  Choose [1-${TOTAL_OPTIONS}] or c for custom: " CHOICE
        CHOICE=$(echo "$CHOICE" | tr -d ' ')

        if [[ "$CHOICE" == "c" || "$CHOICE" == "C" ]]; then
          read -rp "  Enter subnet ID (subnet-xxxx): " CUSTOM_SUBNET
          CUSTOM_SUBNET=$(echo "$CUSTOM_SUBNET" | tr -d ' ')
          if [[ -z "$CUSTOM_SUBNET" ]]; then
            fail "Subnet ID cannot be empty."
            continue
          fi
          CUSTOM_INFO=$(aws_safe ec2 describe-subnets \
            --subnet-ids "$CUSTOM_SUBNET" \
            --query "Subnets[0].[SubnetId,AvailabilityZone,CidrBlock,VpcId]" 2>/dev/null || echo "")
          if [[ -z "$CUSTOM_INFO" || "$CUSTOM_INFO" == "None" ]]; then
            fail "Subnet '$CUSTOM_SUBNET' not found in $REGION. Try again."
            continue
          fi
          CUSTOM_AZ=$(echo "$CUSTOM_INFO"   | awk '{print $2}')
          CUSTOM_CIDR=$(echo "$CUSTOM_INFO" | awk '{print $3}')
          CUSTOM_VPC=$(echo "$CUSTOM_INFO"  | awk '{print $4}')
          ok "Custom subnet validated: $CUSTOM_SUBNET  AZ=$CUSTOM_AZ  CIDR=$CUSTOM_CIDR  VPC=$CUSTOM_VPC"
          if [[ "$DRY_RUN" == true ]]; then
            dryrun "use custom subnet $CUSTOM_SUBNET in $CUSTOM_AZ"
            SKIPPED+=("Subnet: dry-run, would use custom $CUSTOM_SUBNET")
          else
            patch_config "SUBNET_ID"          "$CUSTOM_SUBNET"
            patch_config "AVAILABILITY_ZONE"  "$CUSTOM_AZ"
            patch_config "AVAILABILITY_ZONES" "$CUSTOM_AZ"
            AZ="$CUSTOM_AZ"
            FOUND+=("Subnet: $CUSTOM_SUBNET  AZ=$CUSTOM_AZ  CIDR=$CUSTOM_CIDR")
          fi
          SUBNET_EXISTS=true
          break
        fi

        if [[ "$CHOICE" =~ ^[0-9]+$ ]] && \
           [[ "$CHOICE" -ge 1 ]] && \
           [[ "$CHOICE" -le "$TOTAL_OPTIONS" ]]; then
          CHOSEN_IDX=$((CHOICE - 1))
          break
        fi

        fail "Invalid choice '$CHOICE'. Enter a number between 1 and $TOTAL_OPTIONS, or c."
      done
    fi

    if [[ "$SUBNET_EXISTS" == false ]]; then
      SEL_ID="${MENU_IDS[$CHOSEN_IDX]}"
      SEL_AZ="${MENU_AZS[$CHOSEN_IDX]}"
      SEL_VPC="${MENU_VPCS[$CHOSEN_IDX]}"
      SEL_CIDR=$(aws_safe ec2 describe-subnets \
        --subnet-ids "$SEL_ID" \
        --query "Subnets[0].CidrBlock")

      ok "Selected: $SEL_ID  AZ=$SEL_AZ  CIDR=$SEL_CIDR  VPC=$SEL_VPC"

      if [[ "$SEL_AZ" != "$AZ" ]]; then
        warn "Selected AZ ($SEL_AZ) differs from AVAILABILITY_ZONE config ($AZ)"
        warn "Updating AVAILABILITY_ZONE in config.env to $SEL_AZ"
      fi

      if [[ "$DRY_RUN" == true ]]; then
        dryrun "use subnet $SEL_ID  AZ=$SEL_AZ  VPC=$SEL_VPC"
        SKIPPED+=("Subnet: dry-run, would use $SEL_ID in $SEL_AZ")
      else
        patch_config "SUBNET_ID"          "$SEL_ID"
        patch_config "AVAILABILITY_ZONE"  "$SEL_AZ"
        patch_config "AVAILABILITY_ZONES" "$SEL_AZ"
        AZ="$SEL_AZ"
        FOUND+=("Subnet: $SEL_ID  AZ=$SEL_AZ  CIDR=$SEL_CIDR")
      fi
    fi
  fi
fi


# =============================================================================
# 2.5 SECOND SUBNET (for multi-AZ — only when AVAILABILITY_ZONES has 2+ AZs)
# =============================================================================
header "2.5 / 8  Second Subnet  (multi-AZ)"

# Count how many AZs are configured
AZ_COUNT=$(echo "${AVAILABILITY_ZONES:-}" | tr ',' '\n' | grep -v "^$" | wc -l | tr -d ' \t\r\n')
AZ_COUNT="${AZ_COUNT//[^0-9]/}"
AZ_COUNT="${AZ_COUNT:-1}"

if [[ "$AZ_COUNT" -lt 2 ]]; then
  info "Single AZ configured — skipping second subnet check."
else
  AZ2=$(echo "${AVAILABILITY_ZONES:-}" | cut -d',' -f2 | tr -d ' ')
  CURRENT_SUBNET2="${SUBNET_ID_AZ2:-}"
  SUBNET2_EXISTS=false

  if [[ -n "$CURRENT_SUBNET2" ]]; then
    SUBNET2_LINE=$(aws_safe ec2 describe-subnets \
      --subnet-ids "$CURRENT_SUBNET2" \
      --query "Subnets[0].[AvailabilityZone,State,AvailableIpAddressCount]")
    if [[ -n "$SUBNET2_LINE" && "$SUBNET2_LINE" != "None" ]]; then
      S2_AZ=$(echo "$SUBNET2_LINE"    | awk '{print $1}')
      S2_STATE=$(echo "$SUBNET2_LINE" | awk '{print $2}')
      S2_FREE=$(echo "$SUBNET2_LINE"  | awk '{print $3}')
      ok "Second subnet '$CURRENT_SUBNET2' exists  (AZ: $S2_AZ, State: $S2_STATE, Free IPs: $S2_FREE)"
      SUBNET2_EXISTS=true
      FOUND+=("Second subnet: $CURRENT_SUBNET2  AZ=$S2_AZ")
      [[ "$S2_AZ" != "$AZ2" ]] && \
        warn "Second subnet AZ ($S2_AZ) ≠ second AVAILABILITY_ZONES entry ($AZ2)"
    else
      warn "SUBNET_ID_AZ2 '$CURRENT_SUBNET2' NOT found in AWS."
    fi
  else
    info "SUBNET_ID_AZ2 is empty — need a subnet in $AZ2"
  fi

  if [[ "$SUBNET2_EXISTS" == false ]]; then
    info "Scanning for available subnets in $AZ2..."
    echo ""
    echo -e "${BOLD}  Subnets available in $AZ2:${NC}"
    echo ""

    AZ2_RAW=$(aws_safe ec2 describe-subnets \
      --filters "Name=state,Values=available" "Name=availabilityZone,Values=${AZ2}" \
      --query "Subnets[*].[SubnetId,AvailabilityZone,CidrBlock,VpcId]" \
      2>/dev/null | tr '\t' '|' || echo "")

    if [[ -z "$AZ2_RAW" ]]; then
      warn "No subnets found in $AZ2."
      warn "Create one manually then set SUBNET_ID_AZ2 in config.env"
      warn "  aws ec2 create-subnet --vpc-id <VPC_ID> --cidr-block <CIDR> --availability-zone $AZ2"
      SKIPPED+=("Second subnet: none found in $AZ2 — create manually")
    else
      IDX2=1
      declare -a S2_IDS=() S2_AZNS=() S2_CIDRS=() S2_VPCS=()
      while IFS='|' read -r SID SAZ SCIDR SVPC; do
        [[ -z "$SID" || "$SID" == "None" ]] && continue
        printf "  ${GREEN}[%d]${NC}  %-26s  AZ: %-12s  CIDR: %-18s  VPC: %s\n" \
          "$IDX2" "$SID" "$SAZ" "$SCIDR" "$SVPC"
        S2_IDS+=("$SID"); S2_AZNS+=("$SAZ"); S2_CIDRS+=("$SCIDR"); S2_VPCS+=("$SVPC")
        IDX2=$((IDX2+1))
      done <<< "$AZ2_RAW"

      echo ""
      echo -e "  ${CYAN}[c]${NC}  Enter a custom subnet ID"
      echo ""

      TOTAL2=${#S2_IDS[@]}
      if [[ $TOTAL2 -eq 1 ]]; then
        CHOSEN2=0
        info "Only one subnet in $AZ2 — selecting automatically."
      else
        while true; do
          read -rp "  Choose [1-${TOTAL2}] or c for custom: " CHOICE2
          CHOICE2=$(echo "$CHOICE2" | tr -d ' ')
          if [[ "$CHOICE2" == "c" || "$CHOICE2" == "C" ]]; then
            read -rp "  Enter subnet ID (subnet-xxxx): " CUSTOM2
            CUSTOM2=$(echo "$CUSTOM2" | tr -d ' ')
            CUSTOM2_INFO=$(aws_safe ec2 describe-subnets \
              --subnet-ids "$CUSTOM2" \
              --query "Subnets[0].[SubnetId,AvailabilityZone]" 2>/dev/null || echo "")
            if [[ -z "$CUSTOM2_INFO" || "$CUSTOM2_INFO" == "None" ]]; then
              fail "Subnet '$CUSTOM2' not found. Try again."
              continue
            fi
            CHOSEN_ID2="$CUSTOM2"
            ok "Custom subnet: $CHOSEN_ID2"
            [[ "$DRY_RUN" == false ]] && patch_config "SUBNET_ID_AZ2" "$CHOSEN_ID2"
            SUBNET2_EXISTS=true
            break
          fi
          if [[ "$CHOICE2" =~ ^[0-9]+$ ]] && [[ "$CHOICE2" -ge 1 ]] && [[ "$CHOICE2" -le "$TOTAL2" ]]; then
            CHOSEN2=$((CHOICE2-1))
            break
          fi
          fail "Invalid choice. Enter 1-${TOTAL2} or c."
        done
      fi

      if [[ "$SUBNET2_EXISTS" == false ]]; then
        CHOSEN_ID2="${S2_IDS[$CHOSEN2]}"
        ok "Selected second subnet: $CHOSEN_ID2  AZ=${S2_AZNS[$CHOSEN2]}"
        [[ "$DRY_RUN" == false ]] && patch_config "SUBNET_ID_AZ2" "$CHOSEN_ID2"
        FOUND+=("Second subnet: $CHOSEN_ID2  AZ=${S2_AZNS[$CHOSEN2]}")
      fi
    fi
  fi
fi

# =============================================================================
# 3. SECURITY GROUP
# =============================================================================
header "3 / 8  Security Group"

CURRENT_SG="${SECURITY_GROUP_IDS:-}"
SG_EXISTS=false

if [[ -n "$CURRENT_SG" ]]; then
  FIRST_SG=$(echo "$CURRENT_SG" | cut -d',' -f1 | tr -d ' \r')
  SG_LINE=$(aws_safe ec2 describe-security-groups \
    --group-ids "$FIRST_SG" \
    --query "SecurityGroups[0].[GroupName,VpcId]")
  if [[ -n "$SG_LINE" && "$SG_LINE" != "None" ]]; then
    SG_NAME=$(echo "$SG_LINE" | awk '{print $1}')
    SG_VPC=$(echo "$SG_LINE"  | awk '{print $2}')
    ok "Security group '$FIRST_SG' exists  (Name: $SG_NAME, VPC: $SG_VPC)"
    SG_EXISTS=true
    FOUND+=("Security group: $FIRST_SG  Name=$SG_NAME")
  else
    warn "Security group '$FIRST_SG' NOT found."
  fi
else
  warn "SECURITY_GROUP_IDS is empty."
fi

if [[ "$SG_EXISTS" == false ]]; then
  SG_VPC=""
  CURRENT_SUBNET_FOR_SG="${SUBNET_ID:-}"
  if [[ -n "$CURRENT_SUBNET_FOR_SG" ]]; then
    SG_VPC=$(aws_safe ec2 describe-subnets \
      --subnet-ids "$CURRENT_SUBNET_FOR_SG" \
      --query "Subnets[0].VpcId")
    [[ -n "$SG_VPC" && "$SG_VPC" != "None" ]] && \
      info "Security group will be created in subnet VPC: $SG_VPC"
  fi
  if [[ -z "$SG_VPC" || "$SG_VPC" == "None" ]]; then
    SG_VPC=$(aws_safe ec2 describe-vpcs \
      --filters "Name=isDefault,Values=true" \
      --query "Vpcs[0].VpcId")
  fi
  DEFAULT_VPC="$SG_VPC"
  if [[ -z "$DEFAULT_VPC" || "$DEFAULT_VPC" == "None" ]]; then
    fail "No VPC found — cannot auto-create security group."
    SKIPPED+=("Security group: no VPC found — manual action required")
  else
    echo ""
    read -rp "  Name for new security group [gpu-sg]: " NEW_SG_NAME
    NEW_SG_NAME="${NEW_SG_NAME:-gpu-sg}"

    DETECTED_IP=$(curl -sf --max-time 5 https://checkip.amazonaws.com 2>/dev/null | tr -d '[:space:]' || echo "")
    if [[ -n "$DETECTED_IP" ]]; then
      DEFAULT_CIDR="${DETECTED_IP}/32"
      info "Detected your public IP: $DETECTED_IP"
    else
      DEFAULT_CIDR=""
      warn "Could not auto-detect public IP — you must enter it manually."
    fi

    while true; do
      read -rp "  Your IP for SSH access (x.x.x.x/32)${DEFAULT_CIDR:+ [$DEFAULT_CIDR]}: " SSH_CIDR
      SSH_CIDR="${SSH_CIDR:-$DEFAULT_CIDR}"
      if [[ -z "$SSH_CIDR" ]]; then
        fail "SSH CIDR cannot be empty."
        continue
      fi
      if [[ "$SSH_CIDR" == "0.0.0.0/0" ]]; then
        fail "0.0.0.0/0 opens SSH to the entire internet — not allowed."
        continue
      fi
      break
    done

    if [[ "$DRY_RUN" == true ]]; then
      dryrun "ec2 create-security-group + authorize-ingress SSH from $SSH_CIDR"
      SKIPPED+=("Security group: dry-run, would create $NEW_SG_NAME SSH=$SSH_CIDR")
    else
      NEW_SG_ID=$(aws_cmd ec2 create-security-group \
        --group-name "$NEW_SG_NAME" \
        --description "GPU instance security group" \
        --vpc-id "$DEFAULT_VPC" \
        --query "GroupId")

      aws_cmd ec2 authorize-security-group-ingress \
        --group-id "$NEW_SG_ID" \
        --protocol tcp --port 22 --cidr "$SSH_CIDR" > /dev/null

      aws_cmd ec2 authorize-security-group-ingress \
        --group-id "$NEW_SG_ID" \
        --protocol -1 --port -1 \
        --source-group "$NEW_SG_ID" > /dev/null

      aws_cmd ec2 create-tags \
        --resources "$NEW_SG_ID" \
        --tags "Key=Name,Value=$NEW_SG_NAME" \
               "Key=Project,Value=${TAG_PROJECT:-gpu-deployment}" > /dev/null

      ok "Security group '$NEW_SG_ID' created  (SSH from $SSH_CIDR, self-referencing for NCCL)"
      patch_config "SECURITY_GROUP_IDS" "$NEW_SG_ID"
      CREATED+=("Security group: $NEW_SG_ID  Name=$NEW_SG_NAME  SSH=$SSH_CIDR")
    fi
  fi
fi

# =============================================================================
# 3.5 CLUSTER PLACEMENT GROUP
# =============================================================================
header "3.5 / 8  Cluster Placement Group  (NEW)"

CURRENT_PG="${PLACEMENT_GROUP_NAME:-}"
PG_EXISTS=false

if [[ -n "$CURRENT_PG" ]]; then
  PG_LINE=$(aws_safe ec2 describe-placement-groups \
    --group-names "$CURRENT_PG" \
    --query "PlacementGroups[0].[GroupName,State,Strategy]")
  if [[ -n "$PG_LINE" && "$PG_LINE" != "None" ]]; then
    PG_NAME_OUT=$(echo "$PG_LINE" | awk '{print $1}')
    PG_STATE=$(echo "$PG_LINE"    | awk '{print $2}')
    PG_STRATEGY=$(echo "$PG_LINE" | awk '{print $3}')
    ok "Placement group '$PG_NAME_OUT' exists  (State: $PG_STATE, Strategy: $PG_STRATEGY)"
    PG_EXISTS=true
    FOUND+=("Placement group: $PG_NAME_OUT  strategy=$PG_STRATEGY")
  else
    warn "Placement group '$CURRENT_PG' NOT found."
  fi
else
  warn "PLACEMENT_GROUP_NAME is empty."
fi

if [[ "$PG_EXISTS" == false ]]; then
  echo ""
  read -rp "  Name for new placement group [gpu-cluster-pg]: " NEW_PG_NAME
  NEW_PG_NAME="${NEW_PG_NAME:-gpu-cluster-pg}"

  if [[ "$DRY_RUN" == true ]]; then
    dryrun "ec2 create-placement-group --strategy cluster --group-name $NEW_PG_NAME"
    SKIPPED+=("Placement group: dry-run, would create $NEW_PG_NAME")
  else
    aws_cmd ec2 create-placement-group \
      --group-name "$NEW_PG_NAME" \
      --strategy cluster > /dev/null

    aws_cmd ec2 create-tags \
      --resources "$NEW_PG_NAME" \
      --tags "Key=Name,Value=$NEW_PG_NAME" \
             "Key=Project,Value=${TAG_PROJECT:-gpu-deployment}" > /dev/null 2>&1 || true

    ok "Placement group '$NEW_PG_NAME' created  (strategy: cluster)"
    patch_config "PLACEMENT_GROUP_NAME" "$NEW_PG_NAME"
    CREATED+=("Placement group: $NEW_PG_NAME  strategy=cluster")
  fi
fi

# =============================================================================
# 4. IAM INSTANCE PROFILE
# =============================================================================
header "4 / 8  IAM Instance Profile"

CURRENT_PROFILE_ARN="${IAM_INSTANCE_PROFILE:-}"
PROFILE_NAME=$(basename "$CURRENT_PROFILE_ARN" 2>/dev/null || echo "")
PROFILE_EXISTS=false

if [[ -n "$PROFILE_NAME" ]]; then
  PROFILE_LINE=$(aws_iam iam get-instance-profile \
    --instance-profile-name "$PROFILE_NAME" \
    --query "InstanceProfile.[Arn,Roles[0].RoleName]" \
    2>/dev/null || true)
  if [[ -n "$PROFILE_LINE" && "$PROFILE_LINE" != "None" ]]; then
    P_ARN=$(echo "$PROFILE_LINE"  | awk '{print $1}')
    P_ROLE=$(echo "$PROFILE_LINE" | awk '{print $2}')
    ok "Instance profile '$PROFILE_NAME' exists  (Role: ${P_ROLE:-none})"
    PROFILE_EXISTS=true
    FOUND+=("IAM instance profile: $PROFILE_NAME  Role=${P_ROLE:-none}")
  else
    warn "Instance profile '$PROFILE_NAME' NOT found."
  fi
else
  warn "IAM_INSTANCE_PROFILE is empty."
fi

if [[ "$PROFILE_EXISTS" == false ]]; then
  echo ""
  read -rp "  Name for new IAM instance profile [gpu-instance-profile]: " NEW_PROFILE_NAME
  NEW_PROFILE_NAME="${NEW_PROFILE_NAME:-gpu-instance-profile}"
  ROLE_NAME="${NEW_PROFILE_NAME}-role"

  if [[ "$DRY_RUN" == true ]]; then
    dryrun "iam create-role $ROLE_NAME + create-instance-profile $NEW_PROFILE_NAME"
    SKIPPED+=("IAM instance profile: dry-run, would create $NEW_PROFILE_NAME")
  else
    TRUST_FILE="./trust_policy_$$.json"
    CLEANUP_FILES+=("$TRUST_FILE")

    cat > "$TRUST_FILE" <<'EOF'
{
  "Version": "2012-10-17",
  "Statement": [{
    "Effect": "Allow",
    "Principal": { "Service": "ec2.amazonaws.com" },
    "Action": "sts:AssumeRole"
  }]
}
EOF

    TRUST_FILE_NATIVE=$(to_win_path "$TRUST_FILE")

    aws_iam iam create-role \
      --role-name "$ROLE_NAME" \
      --assume-role-policy-document "file://${TRUST_FILE_NATIVE}" \
      --description "GPU EC2 instance role" > /dev/null

    for POLICY in \
      "arn:aws:iam::aws:policy/AmazonSSMManagedInstanceCore" \
      "arn:aws:iam::aws:policy/CloudWatchAgentServerPolicy" \
      "arn:aws:iam::aws:policy/AmazonEC2ContainerRegistryReadOnly"; do
      aws_iam iam attach-role-policy \
        --role-name "$ROLE_NAME" \
        --policy-arn "$POLICY" > /dev/null
      info "  Attached: $POLICY"
    done

    aws_iam iam create-instance-profile \
      --instance-profile-name "$NEW_PROFILE_NAME" > /dev/null

    aws_iam iam add-role-to-instance-profile \
      --instance-profile-name "$NEW_PROFILE_NAME" \
      --role-name "$ROLE_NAME" > /dev/null

    NEW_PROFILE_ARN="arn:aws:iam::${ACCOUNT_ID}:instance-profile/${NEW_PROFILE_NAME}"
    ok "Instance profile '$NEW_PROFILE_NAME' created  (Role: $ROLE_NAME)"
    patch_config "IAM_INSTANCE_PROFILE" "$NEW_PROFILE_ARN"
    CREATED+=("IAM instance profile: $NEW_PROFILE_NAME  Role=$ROLE_NAME")
  fi
fi

# =============================================================================
# 5. SNS TOPIC & EMAIL SUBSCRIPTION
# =============================================================================
header "5 / 8  SNS Topic + Email Subscription"

SNS_NAME="${SNS_TOPIC_NAME:-gpu-capacity-alerts}"
ALERT_EMAIL_ADDR="${ALERT_EMAIL:-}"
SNS_EXISTS=false

SNS_ARN=$(aws_cmd sns list-topics \
  --query "Topics[].TopicArn" 2>/dev/null \
  | tr '\t' '\n' | grep ":${SNS_NAME}$" || true)

if [[ -n "$SNS_ARN" ]]; then
  ok "SNS topic '$SNS_NAME' exists  ($SNS_ARN)"
  SNS_EXISTS=true
  FOUND+=("SNS topic: $SNS_ARN")
else
  warn "SNS topic '$SNS_NAME' NOT found."
  echo ""
  read -rp "  Name for new SNS topic [$SNS_NAME]: " NEW_SNS_NAME
  NEW_SNS_NAME="${NEW_SNS_NAME:-$SNS_NAME}"

  if [[ "$DRY_RUN" == true ]]; then
    dryrun "sns create-topic --name $NEW_SNS_NAME"
    SNS_ARN="arn:aws:sns:${REGION}:${ACCOUNT_ID}:${NEW_SNS_NAME}"
    SKIPPED+=("SNS topic: dry-run, would create $NEW_SNS_NAME")
  else
    SNS_ARN=$(aws_cmd sns create-topic \
      --name "$NEW_SNS_NAME" \
      --query "TopicArn")
    ok "SNS topic '$NEW_SNS_NAME' created  ($SNS_ARN)"
    patch_config "SNS_TOPIC_NAME" "$NEW_SNS_NAME"
    CREATED+=("SNS topic: $SNS_ARN")
  fi
fi

if [[ -n "$ALERT_EMAIL_ADDR" && "$DRY_RUN" == false ]]; then
  SUB_STATUS=$(aws_cmd sns list-subscriptions-by-topic \
    --topic-arn "$SNS_ARN" \
    --query "Subscriptions[?Endpoint=='${ALERT_EMAIL_ADDR}'].SubscriptionArn" \
    2>/dev/null | tr '\t' '\n' | head -1 || true)

  if [[ -n "$SUB_STATUS" && "$SUB_STATUS" != "None" ]]; then
    if [[ "$SUB_STATUS" == "PendingConfirmation" ]]; then
      warn "Email '$ALERT_EMAIL_ADDR' is subscribed but PENDING — check your inbox and confirm."
    else
      ok "Email '$ALERT_EMAIL_ADDR' subscription confirmed."
      FOUND+=("SNS subscription: $ALERT_EMAIL_ADDR ✔")
    fi
  else
    aws_cmd sns subscribe \
      --topic-arn "$SNS_ARN" \
      --protocol email \
      --notification-endpoint "$ALERT_EMAIL_ADDR" > /dev/null
    warn "Subscription created — check '$ALERT_EMAIL_ADDR' inbox and click CONFIRM."
    CREATED+=("SNS subscription: $ALERT_EMAIL_ADDR  (confirm email sent)")
  fi

  CONFIRMED_COUNT=$(aws_cmd sns list-subscriptions-by-topic \
    --topic-arn "$SNS_ARN" \
    --query "Subscriptions[?SubscriptionArn!='PendingConfirmation'].SubscriptionArn" \
    2>/dev/null | tr '\t' '\n' | grep -c "arn:" || true)
  if [[ "$CONFIRMED_COUNT" -eq 0 ]]; then
    warn "WARNING: SNS topic has NO confirmed subscriptions — alerts will be silently dropped."
  fi
elif [[ -z "$ALERT_EMAIL_ADDR" ]]; then
  warn "ALERT_EMAIL is empty — skipping subscription."
fi

# =============================================================================
# 6. CALLER IAM PERMISSIONS
# =============================================================================
header "6 / 8  Caller IAM Permissions"

CALLER_ARN=$(aws_cmd sts get-caller-identity --query "Arn" 2>/dev/null || true)

CALLER_USER=""
case "$CALLER_ARN" in
  *:user/*) CALLER_USER="${CALLER_ARN##*/}" ;;
esac

POLICY_NAME="gpu-deployment-permissions"

if [[ -z "$CALLER_USER" ]]; then
  warn "Caller is not an IAM user ($CALLER_ARN) — cannot attach policy to user."
  SKIPPED+=("IAM permissions: caller is not a user — manual action required")
else
  MANAGED_POLICY_ARN="arn:aws:iam::${ACCOUNT_ID}:policy/${POLICY_NAME}"

  EXISTING_MANAGED=$(aws_iam iam list-attached-user-policies \
    --user-name "$CALLER_USER" \
    --query "AttachedPolicies[?PolicyName=='${POLICY_NAME}'].PolicyName" \
    2>/dev/null | tr '\t' '\n' | grep -x "$POLICY_NAME" || true)

  if [[ -n "$EXISTING_MANAGED" ]]; then
    ok "Managed policy '$POLICY_NAME' already attached to user '$CALLER_USER'."
    FOUND+=("IAM permissions: $POLICY_NAME on $CALLER_USER")
  elif [[ "$DRY_RUN" == true ]]; then
    dryrun "iam create-policy + attach-user-policy --user-name $CALLER_USER --policy-name $POLICY_NAME"
    SKIPPED+=("IAM permissions: dry-run, would attach $POLICY_NAME to $CALLER_USER")
  else
    PERM_FILE="./gpu_perms_$$.json"
    CLEANUP_FILES+=("$PERM_FILE")

    cat > "$PERM_FILE" <<'EOF'
{
  "Version": "2012-10-17",
  "Statement": [
    {
      "Sid": "GpuDeploymentEc2",
      "Effect": "Allow",
      "Action": [
        "ec2:PurchaseCapacityBlock",
        "ec2:DescribeCapacityBlockOfferings",
        "ec2:DescribeCapacityReservations",
        "ec2:CancelCapacityReservation",
        "ec2:RunInstances",
        "ec2:DescribeInstances",
        "ec2:TerminateInstances",
        "ec2:CreateTags",
        "ec2:DescribePlacementGroups",
        "ec2:CreatePlacementGroup",
        "ec2:DeletePlacementGroup",
        "ec2:DescribeLaunchTemplates",
        "ec2:CreateLaunchTemplate",
        "ec2:DeleteLaunchTemplate",
        "ec2:CreateLaunchTemplateVersion",
        "ec2:ModifyLaunchTemplate",
        "ec2:DescribeLaunchTemplateVersions",
        "ec2:DescribeSubnets",
        "ec2:CreateSubnet",
        "ec2:DeleteSubnet",
        "ec2:DescribeSecurityGroups",
        "ec2:CreateSecurityGroup",
        "ec2:DeleteSecurityGroup",
        "ec2:AuthorizeSecurityGroupIngress",
        "ec2:DescribeKeyPairs",
        "ec2:CreateKeyPair",
        "ec2:DeleteKeyPair",
        "ec2:DescribeVpcs",
        "ec2:DescribeInstanceStatus",
        "ec2:DescribeImages"
      ],
      "Resource": "*"
    },
    {
      "Sid": "GpuDeploymentLambda",
      "Effect": "Allow",
      "Action": [
        "lambda:CreateFunction",
        "lambda:UpdateFunctionCode",
        "lambda:UpdateFunctionConfiguration",
        "lambda:GetFunction",
        "lambda:DeleteFunction",
        "lambda:InvokeFunction",
        "lambda:TagResource",
        "lambda:ListFunctions",
        "lambda:AddPermission",
        "lambda:RemovePermission"
      ],
      "Resource": "*"
    },
    {
      "Sid": "GpuDeploymentStepFunctions",
      "Effect": "Allow",
      "Action": [
        "states:CreateStateMachine",
        "states:DeleteStateMachine",
        "states:StartExecution",
        "states:StopExecution",
        "states:ListExecutions",
        "states:DescribeExecution",
        "states:TagResource"
      ],
      "Resource": "*"
    },
    {
      "Sid": "GpuDeploymentDynamoDB",
      "Effect": "Allow",
      "Action": [
        "dynamodb:CreateTable",
        "dynamodb:DeleteTable",
        "dynamodb:DescribeTable",
        "dynamodb:PutItem",
        "dynamodb:GetItem",
        "dynamodb:UpdateItem",
        "dynamodb:Scan",
        "dynamodb:TagResource"
      ],
      "Resource": "*"
    },
    {
      "Sid": "GpuDeploymentApiGateway",
      "Effect": "Allow",
      "Action": [
        "apigateway:POST",
        "apigateway:GET",
        "apigateway:PUT",
        "apigateway:DELETE",
        "apigateway:PATCH"
      ],
      "Resource": "*"
    },
    {
      "Sid": "GpuDeploymentScheduler",
      "Effect": "Allow",
      "Action": [
        "scheduler:CreateSchedule",
        "scheduler:DeleteSchedule",
        "scheduler:GetSchedule",
        "scheduler:ListSchedules",
        "scheduler:UpdateSchedule"
      ],
      "Resource": "*"
    },
    {
      "Sid": "GpuDeploymentIamWatcher",
      "Effect": "Allow",
      "Action": [
        "iam:CreateRole",
        "iam:DeleteRole",
        "iam:GetRole",
        "iam:PutRolePolicy",
        "iam:DeleteRolePolicy",
        "iam:ListRolePolicies",
        "iam:AttachRolePolicy",
        "iam:DetachRolePolicy",
        "iam:ListAttachedRolePolicies",
        "iam:PassRole",
        "iam:TagRole"
      ],
      "Resource": "arn:aws:iam::*:role/gpu-*"
    },
    {
      "Sid": "GpuDeploymentSsm",
      "Effect": "Allow",
      "Action": [
        "ssm:PutParameter",
        "ssm:GetParameter",
        "ssm:DeleteParameter",
        "ssm:DeleteParameters",
        "ssm:GetParametersByPath"
      ],
      "Resource": "*"
    },
    {
      "Sid": "GpuDeploymentSns",
      "Effect": "Allow",
      "Action": [
        "sns:CreateTopic",
        "sns:DeleteTopic",
        "sns:Subscribe",
        "sns:Unsubscribe",
        "sns:Publish",
        "sns:ListTopics",
        "sns:ListSubscriptionsByTopic",
        "sns:GetTopicAttributes"
      ],
      "Resource": "*"
    },
    {
      "Sid": "GpuDeploymentCloudWatch",
      "Effect": "Allow",
      "Action": [
        "cloudwatch:PutMetricAlarm",
        "cloudwatch:DeleteAlarms",
        "cloudwatch:DescribeAlarms",
        "logs:CreateLogGroup",
        "logs:DeleteLogGroup",
        "logs:DescribeLogGroups",
        "logs:CreateLogStream",
        "logs:PutLogEvents"
      ],
      "Resource": "*"
    }
  ]
}
EOF

    PERM_FILE_NATIVE=$(to_win_path "$PERM_FILE")
    IAM_ERR_FILE="/tmp/iam_perm_err_$$"
    CLEANUP_FILES+=("$IAM_ERR_FILE")

    EXISTING_POLICY=$(aws_iam iam get-policy \
      --policy-arn "$MANAGED_POLICY_ARN" \
      --query "Policy.Arn" 2>/dev/null || echo "")
    if [[ -n "$EXISTING_POLICY" && "$EXISTING_POLICY" != "None" ]]; then
      aws_iam iam detach-user-policy \
        --user-name "$CALLER_USER" \
        --policy-arn "$MANAGED_POLICY_ARN" 2>/dev/null || true
      NON_DEF=$(aws_iam iam list-policy-versions \
        --policy-arn "$MANAGED_POLICY_ARN" \
        --query "Versions[?!IsDefaultVersion].VersionId" \
        2>/dev/null | tr '\t' '\n' | grep -v "^$" || echo "")
      for VID in $NON_DEF; do
        aws_iam iam delete-policy-version \
          --policy-arn "$MANAGED_POLICY_ARN" \
          --version-id "$VID" 2>/dev/null || true
      done
      aws_iam iam delete-policy \
        --policy-arn "$MANAGED_POLICY_ARN" 2>/dev/null || true
      info "Removed old version of managed policy $POLICY_NAME"
    fi

    NEW_POLICY_ARN=$(aws_iam iam create-policy \
      --policy-name "$POLICY_NAME" \
      --policy-document "file://${PERM_FILE_NATIVE}" \
      --query "Policy.Arn" 2>"$IAM_ERR_FILE") || {
      fail "Could not create managed policy: $(tr -d '\r\n' < "$IAM_ERR_FILE")"
      SKIPPED+=("IAM permissions: create-policy failed — manual action required")
      NEW_POLICY_ARN=""
    }

    if [[ -n "$NEW_POLICY_ARN" ]]; then
      if aws_iam iam attach-user-policy \
          --user-name "$CALLER_USER" \
          --policy-arn "$NEW_POLICY_ARN" 2>"$IAM_ERR_FILE"; then
        ok "Managed policy '$POLICY_NAME' created and attached to user '$CALLER_USER'."
        info "ARN: $NEW_POLICY_ARN"
        CREATED+=("IAM permissions: $POLICY_NAME on $CALLER_USER (managed policy)")
      else
        fail "Policy created but could not attach: $(tr -d '\r\n' < "$IAM_ERR_FILE")"
        SKIPPED+=("IAM permissions: attach-user-policy failed — run manually")
      fi
    fi
  fi
fi

# =============================================================================
# 7. LAUNCH TEMPLATE  — with instance type mismatch detection (NEW-4)
# =============================================================================
header "7 / 8  Launch Template  (NEW)"

CURRENT_LT="${LAUNCH_TEMPLATE_NAME:-}"
LT_EXISTS=false
LT_NEEDS_UPDATE=false

CB_INSTANCE_TYPE="$(echo "${INSTANCE_TYPES:-p5.48xlarge}" | cut -d"," -f1 | tr -d " ")"
CB_AMI_ID="${AMI_ID:-}"
CB_RESERVATION_ID="${CAPACITY_RESERVATION_ID:-}"

if [[ -n "$CURRENT_LT" ]]; then
  LT_LINE=$(aws_safe ec2 describe-launch-templates \
    --launch-template-names "$CURRENT_LT" \
    --query "LaunchTemplates[0].[LaunchTemplateId,DefaultVersionNumber,LatestVersionNumber]")

  if [[ -n "$LT_LINE" && "$LT_LINE" != "None" ]]; then
    LT_ID_FOUND=$(echo "$LT_LINE"  | awk '{print $1}')
    LT_LAT_V=$(echo "$LT_LINE"     | awk '{print $3}')

    # ── NEW-4: Check instance type in $Latest version ─────────────────────────
    # Pipeline always uses $Latest (launch.sh: Version=$Latest) so we compare
    # against $Latest only. Default version concept is unused and ignored.
    # If config.env INSTANCE_TYPES changed, detect it and create a new version.
    CURRENT_LT_ITYPE=$(aws_safe ec2 describe-launch-template-versions \
      --launch-template-id "$LT_ID_FOUND" \
      --versions "\$Latest" \
      --query "LaunchTemplateVersions[0].LaunchTemplateData.InstanceType")

    ok "Launch template '$CURRENT_LT' exists  (ID: $LT_ID_FOUND, latest v$LT_LAT_V)"
    info "Template latest instance type : ${CURRENT_LT_ITYPE:-unknown}"
    info "config.env instance type      : $CB_INSTANCE_TYPE"

    if [[ -n "$CURRENT_LT_ITYPE" && \
          "$CURRENT_LT_ITYPE" != "None" && \
          "$CURRENT_LT_ITYPE" != "$CB_INSTANCE_TYPE" ]]; then
      warn "Instance type mismatch detected!"
      warn "  Template \$Latest uses         : $CURRENT_LT_ITYPE"
      warn "  config.env INSTANCE_TYPES is  : $CB_INSTANCE_TYPE"
      warn "  A new \$Latest version will be created automatically."
      LT_EXISTS=true
      LT_NEEDS_UPDATE=true
      LT_ID_TO_UPDATE="$LT_ID_FOUND"
    else
      ok "Instance type matches config.env — no update needed."
      LT_EXISTS=true
      FOUND+=("Launch template: $CURRENT_LT  v$LT_LAT_V  instance=$CURRENT_LT_ITYPE")
    fi
  else
    warn "Launch template '$CURRENT_LT' NOT found."
  fi
else
  warn "LAUNCH_TEMPLATE_NAME is empty."
fi

# ── Resolve AMI for create or update ─────────────────────────────────────────
resolve_ami() {
  # IMPORTANT: called inside $(...) subshell — ALL status output must go to
  # stderr (>&2) so only the bare AMI ID reaches stdout. Any extra text
  # captured by $() corrupts the variable and kills the script under set -e.
  local itype="$1"
  local resolved_ami="${CB_AMI_ID:-}"

  if [[ -z "$resolved_ami" || "$resolved_ami" == "ami-XXXXXXXX" ]]; then
    warn "AMI_ID not set — auto-discovering correct AMI for $itype..." >&2

    if [[ "$itype" == trn* ]]; then
      info "Trainium instance — searching for Neuron AMI..." >&2
      resolved_ami=$(aws_safe ec2 describe-images \
        --owners amazon --region "$AWS_REGION" \
        --filters \
          "Name=name,Values=Deep Learning AMI Neuron PyTorch*" \
          "Name=state,Values=available" \
          "Name=architecture,Values=x86_64" \
        --query "sort_by(Images,&CreationDate)[-1].ImageId")
      if [[ -z "$resolved_ami" || "$resolved_ami" == "None" ]]; then
        resolved_ami=$(aws_safe ec2 describe-images \
          --owners amazon --region "$AWS_REGION" \
          --filters \
            "Name=name,Values=al2023-ami-2023*" \
            "Name=state,Values=available" \
            "Name=architecture,Values=x86_64" \
          --query "sort_by(Images,&CreationDate)[-1].ImageId")
        [[ -n "$resolved_ami" && "$resolved_ami" != "None" ]] && \
          warn "Using Amazon Linux 2023 AMI — install Neuron SDK manually after launch" >&2
      fi
    else
      info "GPU instance — searching for Deep Learning GPU AMI..." >&2

      # Method 1a: SSM — PyTorch 2.8 Ubuntu 24.04 (latest as of 2026)
      resolved_ami=$(aws $PROFILE_FLAG ssm get-parameter \
        --region "$AWS_REGION" \
        --name "/aws/service/deeplearning/ami/x86_64/oss-nvidia-driver-gpu-pytorch-2.8-ubuntu-24.04/latest/ami-id" \
        --query "Parameter.Value" --output text 2>/dev/null || echo "")

      # Method 1b: SSM — PyTorch 2.7 Ubuntu 22.04
      if [[ -z "$resolved_ami" || "$resolved_ami" == "None" ]]; then
        info "Trying PyTorch 2.7 Ubuntu 22.04 SSM path..." >&2
        resolved_ami=$(aws $PROFILE_FLAG ssm get-parameter \
          --region "$AWS_REGION" \
          --name "/aws/service/deeplearning/ami/x86_64/oss-nvidia-driver-gpu-pytorch-2.7-ubuntu-22.04/latest/ami-id" \
          --query "Parameter.Value" --output text 2>/dev/null || echo "")
      fi

      # Method 1c: SSM — PyTorch 2.8 Amazon Linux 2023
      if [[ -z "$resolved_ami" || "$resolved_ami" == "None" ]]; then
        info "Trying PyTorch 2.8 Amazon Linux 2023 SSM path..." >&2
        resolved_ami=$(aws $PROFILE_FLAG ssm get-parameter \
          --region "$AWS_REGION" \
          --name "/aws/service/deeplearning/ami/x86_64/oss-nvidia-driver-gpu-pytorch-2.8-amazon-linux-2023/latest/ami-id" \
          --query "Parameter.Value" --output text 2>/dev/null || echo "")
      fi

      # Method 2: describe-images — OSS Nvidia naming pattern (current)
      if [[ -z "$resolved_ami" || "$resolved_ami" == "None" ]]; then
        info "SSM failed — trying describe-images OSS pattern..." >&2
        resolved_ami=$(aws_safe ec2 describe-images \
          --owners amazon --region "$AWS_REGION" \
          --filters \
            "Name=name,Values=Deep Learning OSS Nvidia Driver AMI GPU PyTorch*" \
            "Name=state,Values=available" \
            "Name=architecture,Values=x86_64" \
          --query "sort_by(Images,&CreationDate)[-1].ImageId")
      fi

      # Method 3: describe-images — legacy naming pattern
      if [[ -z "$resolved_ami" || "$resolved_ami" == "None" ]]; then
        info "Trying legacy Deep Learning AMI pattern..." >&2
        resolved_ami=$(aws_safe ec2 describe-images \
          --owners amazon --region "$AWS_REGION" \
          --filters \
            "Name=name,Values=Deep Learning AMI GPU PyTorch*" \
            "Name=state,Values=available" \
            "Name=architecture,Values=x86_64" \
          --query "sort_by(Images,&CreationDate)[-1].ImageId")
      fi
    fi

    if [[ -n "$resolved_ami" && "$resolved_ami" != "None" ]]; then
      info "Auto-discovered AMI: $resolved_ami" >&2
      CB_AMI_ID="$resolved_ami"
    else
      fail "Could not auto-discover AMI for $itype. Set AMI_ID in config.env and re-run." >&2
      exit 1
    fi
  fi
  # Only the bare AMI ID to stdout — captured cleanly by $()
  echo "$resolved_ami"
}

# ── Update existing template if instance type mismatch ───────────────────────
if [[ "$LT_NEEDS_UPDATE" == true ]]; then
  RESOLVED_AMI=$(resolve_ami "$CB_INSTANCE_TYPE")

  if [[ "$DRY_RUN" == true ]]; then
    dryrun "ec2 create-launch-template-version on $LT_ID_TO_UPDATE"
    dryrun "  InstanceType: $CB_INSTANCE_TYPE  AMI: $RESOLVED_AMI"
    SKIPPED+=("Launch template: dry-run, would update $CURRENT_LT for $CB_INSTANCE_TYPE")
  else
    # patch_config called here (outside subshell) to write AMI_ID to config.env
    # resolve_ami set CB_AMI_ID but could not call patch_config from inside $()
    [[ -n "$CB_AMI_ID" ]] && patch_config "AMI_ID" "$CB_AMI_ID"

    info "Creating new launch template version..."
    info "  Instance type : $CB_INSTANCE_TYPE"
    info "  AMI           : $RESOLVED_AMI"

    LT_UPDATE_DATA="{\"ImageId\":\"${RESOLVED_AMI}\",\"InstanceType\":\"${CB_INSTANCE_TYPE}\"}"

    NEW_LT_VERSION=$(aws_cmd ec2 create-launch-template-version \
      --launch-template-id "$LT_ID_TO_UPDATE" \
      --source-version "\$Latest" \
      --version-description "${CB_INSTANCE_TYPE} — updated by aws_check_create.sh" \
      --launch-template-data "$LT_UPDATE_DATA" \
      --query "LaunchTemplateVersion.VersionNumber")

    # Default version intentionally NOT updated — pipeline always uses $Latest.
    # launch.sh calls RunInstances with Version=$Latest so default is irrelevant.

    ok "Launch template updated — new \$Latest version: v${NEW_LT_VERSION}"
    ok "  Instance type : $CB_INSTANCE_TYPE"
    ok "  AMI           : $RESOLVED_AMI"
    info "Pipeline uses \$Latest — default version unchanged (not relevant)"
    CREATED+=("Launch template update: $CURRENT_LT → v${NEW_LT_VERSION} \$Latest  ($CB_INSTANCE_TYPE)")
  fi
fi

# ── Create template from scratch if it does not exist ────────────────────────
if [[ "$LT_EXISTS" == false ]]; then
  echo ""
  read -rp "  Name for new launch template [gpu-cb-lt]: " NEW_LT_NAME
  NEW_LT_NAME="${NEW_LT_NAME:-gpu-cb-lt}"

  RESOLVED_AMI=$(resolve_ami "$CB_INSTANCE_TYPE")

  if [[ -z "$CB_RESERVATION_ID" ]]; then
    warn "CAPACITY_RESERVATION_ID is empty — template will target 'open' capacity."
    CB_CR_SPEC='"CapacityReservationPreference": "open"'
  else
    info "Targeting Capacity Block: $CB_RESERVATION_ID"
    CB_CR_SPEC="\"CapacityReservationPreference\": \"none\", \"CapacityReservationTarget\": { \"CapacityReservationId\": \"${CB_RESERVATION_ID}\" }"
  fi

  # Re-source config.env — patch_config wrote new values (subnet, SG, etc.)
  # to the file but did not update the running shell environment.
  # Without this re-source RESOLVED_SUBNET etc. will be empty.
  CLEAN_RESYNC="/tmp/config_resync_$$.env"
  sed 's/\r//' "$CONFIG_FILE" > "$CLEAN_RESYNC"
  set +u; source "$CLEAN_RESYNC"; set -u
  rm -f "$CLEAN_RESYNC"

  RESOLVED_SG="${SECURITY_GROUP_IDS:-}"
  RESOLVED_SUBNET="${SUBNET_ID:-}"
  RESOLVED_PROFILE_ARN="${IAM_INSTANCE_PROFILE:-}"
  RESOLVED_KEY="${KEY_PAIR_NAME:-}"
  RESOLVED_PG="${PLACEMENT_GROUP_NAME:-}"

  if [[ "$DRY_RUN" == true ]]; then
    dryrun "ec2 create-launch-template --name $NEW_LT_NAME (instance: $CB_INSTANCE_TYPE, ami: $RESOLVED_AMI)"
    SKIPPED+=("Launch template: dry-run, would create $NEW_LT_NAME")
  else
    LT_FILE="./lt_data_$$.json"
    CLEANUP_FILES+=("$LT_FILE")

    cat > "$LT_FILE" <<EOF
{
  "ImageId": "${RESOLVED_AMI}",
  "InstanceType": "${CB_INSTANCE_TYPE}",
  "KeyName": "${RESOLVED_KEY}",
  "Placement": {
    "GroupName": "${RESOLVED_PG}",
    "AvailabilityZone": "${AZ}"
  },
  "NetworkInterfaces": [{
    "DeviceIndex": 0,
    "SubnetId": "${RESOLVED_SUBNET}",
    "Groups": ["${RESOLVED_SG}"],
    "InterfaceType": "efa",
    "DeleteOnTermination": true
  }],
  "IamInstanceProfile": {
    "Arn": "${RESOLVED_PROFILE_ARN}"
  },
  "BlockDeviceMappings": [{
    "DeviceName": "/dev/sda1",
    "Ebs": {
      "VolumeType": "gp3",
      "VolumeSize": 200,
      "DeleteOnTermination": true,
      "Encrypted": true
    }
  }],
  "CapacityReservationSpecification": {
    ${CB_CR_SPEC}
  },
  "TagSpecifications": [{
    "ResourceType": "instance",
    "Tags": [
      { "Key": "Project",     "Value": "${TAG_PROJECT:-gpu-deployment}" },
      { "Key": "LaunchedBy",  "Value": "aws_check_create.sh" }
    ]
  }],
  "MetadataOptions": {
    "HttpTokens": "required",
    "HttpEndpoint": "enabled"
  },
  "UserData": ""
}
EOF

    LT_FILE_NATIVE=$(to_win_path "$LT_FILE")

    NEW_LT_ID=$(aws_cmd ec2 create-launch-template \
      --launch-template-name "$NEW_LT_NAME" \
      --version-description "Initial version — created by aws_check_create.sh" \
      --launch-template-data "file://${LT_FILE_NATIVE}" \
      --query "LaunchTemplate.LaunchTemplateId")

    ok "Launch template '$NEW_LT_NAME' created  (ID: $NEW_LT_ID)"
    patch_config "LAUNCH_TEMPLATE_NAME" "$NEW_LT_NAME"
    patch_config "LAUNCH_TEMPLATE_ID"   "$NEW_LT_ID"
    CREATED+=("Launch template: $NEW_LT_NAME  ID=$NEW_LT_ID")
  fi
fi

# =============================================================================
# 8. CLOUDWATCH ALARM
# =============================================================================
header "8 / 8  CloudWatch Alarm — Capacity Block Expiry Reminder"

if [[ -n "${SNS_ARN:-}" ]]; then
  CW_ALARM_NAME="gpu-capacity-block-expiry-reminder"
  ALARM_EXISTS=$(aws_cmd cloudwatch describe-alarms \
    --alarm-names "$CW_ALARM_NAME" \
    --query "MetricAlarms[0].AlarmName" 2>/dev/null || true)

  if [[ -n "$ALARM_EXISTS" && "$ALARM_EXISTS" != "None" ]]; then
    ok "CloudWatch alarm '$CW_ALARM_NAME' exists."
    FOUND+=("CloudWatch alarm: $CW_ALARM_NAME")
  elif [[ "$DRY_RUN" == true ]]; then
    dryrun "cloudwatch put-metric-alarm --alarm-name $CW_ALARM_NAME"
    SKIPPED+=("CloudWatch alarm: dry-run, would create $CW_ALARM_NAME")
  else
    aws_cmd cloudwatch put-metric-alarm \
      --alarm-name "$CW_ALARM_NAME" \
      --alarm-description "Reminder: review GPU Capacity Block reservation status" \
      --metric-name "CPUUtilization" \
      --namespace "AWS/EC2" \
      --statistic "Average" \
      --period 86400 \
      --threshold 1 \
      --comparison-operator "LessThanThreshold" \
      --evaluation-periods 1 \
      --alarm-actions "$SNS_ARN" \
      --treat-missing-data "notBreaching" > /dev/null
    ok "CloudWatch alarm '$CW_ALARM_NAME' created."
    CREATED+=("CloudWatch alarm: $CW_ALARM_NAME")
  fi
else
  warn "SNS_ARN not available — skipping CloudWatch alarm."
  SKIPPED+=("CloudWatch alarm: no SNS ARN available")
fi

# =============================================================================
# FINAL SUMMARY
# =============================================================================
echo ""
echo -e "${BOLD}╔══════════════════════════════════════════════════════════╗${NC}"
if [[ "$DRY_RUN" == true ]]; then
echo -e "${BOLD}║          AUDIT COMPLETE (DRY-RUN) — SUMMARY             ║${NC}"
else
echo -e "${BOLD}║              AUDIT COMPLETE — SUMMARY                   ║${NC}"
fi
echo -e "${BOLD}╚══════════════════════════════════════════════════════════╝${NC}"

if [[ ${#FOUND[@]} -gt 0 ]]; then
  echo -e "\n${GREEN}${BOLD}Already existed (${#FOUND[@]}):${NC}"
  for item in "${FOUND[@]}"; do echo -e "  ${GREEN}✔${NC}  $item"; done
fi

if [[ ${#CREATED[@]} -gt 0 ]]; then
  echo -e "\n${CYAN}${BOLD}Created / updated (${#CREATED[@]}):${NC}"
  for item in "${CREATED[@]}"; do echo -e "  ${CYAN}+${NC}  $item"; done
fi

if [[ ${#SKIPPED[@]} -gt 0 ]]; then
  echo -e "\n${YELLOW}${BOLD}Needs manual action / dry-run (${#SKIPPED[@]}):${NC}"
  for item in "${SKIPPED[@]}"; do echo -e "  ${YELLOW}!${NC}  $item"; done
fi

echo ""
if [[ "$DRY_RUN" == false ]]; then
  info "config.env updated. Timestamped backups → ${CONFIG_FILE}.bak.<timestamp>"
fi
echo ""