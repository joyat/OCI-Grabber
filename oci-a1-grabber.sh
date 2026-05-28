#!/bin/bash

# ============================================================
#  oci-a1-grabber — Grab Oracle Cloud A1.Flex Free Tier VMs
# ============================================================
#  Automatically retries instance creation across all
#  availability domains until capacity appears.
#
#  https://github.com/YOUR_USERNAME/oci-a1-grabber
#  License: MIT
# ============================================================

set -euo pipefail

VERSION="1.0.0"
CONFIG_FILE="${OCI_A1_CONFIG:-$HOME/.oci-a1-grabber.conf}"
LOG_FILE="${OCI_A1_LOG:-$HOME/oci-a1-grabber.log}"
MAX_LOG_LINES=3000
INSTANCE_DETAILS_FILE="$HOME/oci-a1-grabber-instance.json"
CONNECT_SCRIPT="$HOME/oci-connect.sh"

# ============================================================
# Defaults (overridden by config file or CLI flags)
# ============================================================
TENANCY=""
SUBNET=""
IMAGE=""
SSH_KEY=""
DISPLAY_NAME="a1-free"
OCPUS="4"
MEMORY="24"
REGION=""
OCI_PROFILE="DEFAULT"
WAIT_MIN=60
WAIT_MAX=90
MAX_CONFIG_ERRORS=3
HEALTH_CHECK_INTERVAL=50
NOTIFY_MACOS=true
NOTIFY_TELEGRAM=false
TELEGRAM_BOT_TOKEN=""
TELEGRAM_CHAT_ID=""
TRY_MULTIPLE_SIZES=true
NO_RETRY_FLAG=true

# ============================================================
# Color output
# ============================================================
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
BOLD='\033[1m'
NC='\033[0m'

# ============================================================
# Usage
# ============================================================
usage() {
  cat <<EOF
${BOLD}oci-a1-grabber${NC} v${VERSION} — Grab Oracle Cloud A1.Flex Free Tier VMs

${BOLD}USAGE${NC}
  oci-a1-grabber [OPTIONS]
  oci-a1-grabber setup
  oci-a1-grabber status
  oci-a1-grabber stop

${BOLD}COMMANDS${NC}
  setup       Interactive setup wizard — creates config file
  status      Show current retry status from log
  stop        Stop the background grabber process

${BOLD}OPTIONS${NC}
  --tenancy ID          OCI tenancy OCID
  --subnet ID           Subnet OCID (must be public)
  --image ID            Compute image OCID (auto-detected if empty)
  --ssh-key PATH        Path to SSH public key file
  --name NAME           Instance display name (default: a1-free)
  --ocpus N             Number of OCPUs (default: 4, max free: 4)
  --memory N            Memory in GB (default: 24, max free: 24)
  --region REGION       OCI region (default: from OCI config)
  --profile NAME        OCI CLI profile (default: DEFAULT)
  --wait-min SECS       Min wait between attempts (default: 60)
  --wait-max SECS       Max wait between attempts (default: 90)
  --no-multi-size       Don't rotate through multiple sizes
  --background          Run in background (nohup)
  --config PATH         Config file path (default: ~/.oci-a1-grabber.conf)
  --help                Show this help
  --version             Show version

${BOLD}QUICK START${NC}
  1. oci-a1-grabber setup          # Interactive config wizard
  2. oci-a1-grabber --background   # Start grabbing in background
  3. oci-a1-grabber status          # Check progress
  4. ~/oci-connect.sh               # SSH in after success

${BOLD}ENVIRONMENT VARIABLES${NC}
  OCI_A1_CONFIG    Config file path (default: ~/.oci-a1-grabber.conf)
  OCI_A1_LOG       Log file path (default: ~/oci-a1-grabber.log)

EOF
  exit 0
}

# ============================================================
# Logging
# ============================================================
log() { echo -e "$1" | tee -a "$LOG_FILE"; }
log_inline() { echo -ne "$1" | tee -a "$LOG_FILE"; }
log_ts() { log "[$(date '+%H:%M:%S')] $1"; }

rotate_log() {
  if [ -f "$LOG_FILE" ]; then
    local lines
    lines=$(wc -l < "$LOG_FILE" 2>/dev/null || echo 0)
    if [ "$lines" -gt "$MAX_LOG_LINES" ]; then
      tail -$((MAX_LOG_LINES / 2)) "$LOG_FILE" > "${LOG_FILE}.tmp"
      mv "${LOG_FILE}.tmp" "$LOG_FILE"
      log "[log rotated]"
    fi
  fi
}

# ============================================================
# Notifications
# ============================================================
notify() {
  local title="$1" message="$2" sound="${3:-Glass}"
  # macOS
  if [ "$NOTIFY_MACOS" = true ] && command -v osascript &>/dev/null; then
    osascript -e "display notification \"$message\" with title \"$title\" sound name \"$sound\"" 2>/dev/null || true
  fi
  # macOS voice
  if command -v say &>/dev/null; then
    say "$message" 2>/dev/null &
  fi
  # Telegram
  if [ "$NOTIFY_TELEGRAM" = true ] && [ -n "$TELEGRAM_BOT_TOKEN" ] && [ -n "$TELEGRAM_CHAT_ID" ]; then
    curl -s -X POST "https://api.telegram.org/bot${TELEGRAM_BOT_TOKEN}/sendMessage" \
      -d "chat_id=${TELEGRAM_CHAT_ID}" \
      -d "text=${title}: ${message}" \
      -d "parse_mode=HTML" &>/dev/null || true
  fi
}

notify_success() { notify "$1" "$2" "Glass"; }
notify_error() { notify "$1" "$2" "Basso"; }

# ============================================================
# Config file
# ============================================================
load_config() {
  if [ -f "$CONFIG_FILE" ]; then
    # shellcheck source=/dev/null
    source "$CONFIG_FILE"
  fi
}

save_config() {
  cat > "$CONFIG_FILE" <<CONF
# oci-a1-grabber configuration
# Generated: $(date)

TENANCY="$TENANCY"
SUBNET="$SUBNET"
IMAGE="$IMAGE"
SSH_KEY="$SSH_KEY"
DISPLAY_NAME="$DISPLAY_NAME"
OCPUS="$OCPUS"
MEMORY="$MEMORY"
REGION="$REGION"
OCI_PROFILE="$OCI_PROFILE"
WAIT_MIN="$WAIT_MIN"
WAIT_MAX="$WAIT_MAX"
TRY_MULTIPLE_SIZES="$TRY_MULTIPLE_SIZES"
NO_RETRY_FLAG="$NO_RETRY_FLAG"
NOTIFY_MACOS="$NOTIFY_MACOS"
NOTIFY_TELEGRAM="$NOTIFY_TELEGRAM"
TELEGRAM_BOT_TOKEN="$TELEGRAM_BOT_TOKEN"
TELEGRAM_CHAT_ID="$TELEGRAM_CHAT_ID"
CONF
  chmod 600 "$CONFIG_FILE"
  echo -e "${GREEN}Config saved to ${CONFIG_FILE}${NC}"
}

# ============================================================
# Setup wizard
# ============================================================
cmd_setup() {
  echo -e "${BOLD}${CYAN}oci-a1-grabber setup wizard${NC}"
  echo ""

  # Check OCI CLI
  if ! command -v oci &>/dev/null; then
    echo -e "${RED}Error: OCI CLI not found.${NC}"
    echo "Install: https://docs.oracle.com/en-us/iaas/Content/API/SDKDocs/cliinstall.htm"
    exit 1
  fi

  # Tenancy
  echo -e "${BOLD}Step 1: Tenancy OCID${NC}"
  echo "Find at: Oracle Console → Profile → Tenancy"
  if [ -n "$TENANCY" ]; then echo "  Current: $TENANCY"; fi
  read -rp "  Tenancy OCID [enter to keep current]: " input
  [ -n "$input" ] && TENANCY="$input"

  # Region
  echo ""
  echo -e "${BOLD}Step 2: Region${NC}"
  local default_region
  default_region=$(oci iam region-subscription list --tenancy-id "$TENANCY" --query "data[0].\"region-name\"" --raw-output 2>/dev/null || echo "")
  if [ -n "$default_region" ]; then
    echo "  Detected: $default_region"
    REGION="${REGION:-$default_region}"
  fi
  read -rp "  Region [$REGION]: " input
  [ -n "$input" ] && REGION="$input"

  # Subnet
  echo ""
  echo -e "${BOLD}Step 3: Subnet${NC}"
  echo "  Listing public subnets..."
  oci network subnet list --compartment-id "$TENANCY" \
    --query "data[?\"prohibit-public-ip-on-vnic\"==\`false\`].{name:\"display-name\",id:id}" \
    --output table --all 2>/dev/null || echo "  (could not list — enter manually)"
  if [ -n "$SUBNET" ]; then echo "  Current: $SUBNET"; fi
  read -rp "  Subnet OCID [enter to keep current]: " input
  [ -n "$input" ] && SUBNET="$input"

  # Image
  echo ""
  echo -e "${BOLD}Step 4: Ubuntu Image${NC}"
  echo "  Finding latest Ubuntu 22.04 ARM image..."
  local auto_image
  auto_image=$(oci compute image list \
    --compartment-id "$TENANCY" \
    --shape VM.Standard.A1.Flex \
    --query "data[?contains(\"display-name\",'Canonical-Ubuntu-22.04-aarch64')&&!contains(\"display-name\",'Minimal')].id | [0]" \
    --raw-output --all 2>/dev/null || echo "")
  if [ -n "$auto_image" ] && [ "$auto_image" != "null" ]; then
    local img_name
    img_name=$(oci compute image get --image-id "$auto_image" --query "data.\"display-name\"" --raw-output 2>/dev/null || echo "unknown")
    echo -e "  ${GREEN}Found: $img_name${NC}"
    IMAGE="$auto_image"
  fi
  read -rp "  Image OCID [enter to use auto-detected]: " input
  [ -n "$input" ] && IMAGE="$input"

  # SSH key
  echo ""
  echo -e "${BOLD}Step 5: SSH Key${NC}"
  local default_key=""
  for k in ~/.ssh/id_ed25519.pub ~/.ssh/id_rsa.pub ~/.ssh/oci-ai-agents.pub; do
    if [ -f "$k" ]; then default_key="$k"; break; fi
  done
  if [ -n "$default_key" ]; then echo "  Found: $default_key"; fi
  read -rp "  SSH public key path [$default_key]: " input
  SSH_KEY="${input:-$default_key}"

  # Instance config
  echo ""
  echo -e "${BOLD}Step 6: Instance Config${NC}"
  read -rp "  Display name [$DISPLAY_NAME]: " input
  [ -n "$input" ] && DISPLAY_NAME="$input"
  read -rp "  OCPUs (max free: 4) [$OCPUS]: " input
  [ -n "$input" ] && OCPUS="$input"
  read -rp "  Memory GB (max free: 24) [$MEMORY]: " input
  [ -n "$input" ] && MEMORY="$input"

  # Retry config
  echo ""
  echo -e "${BOLD}Step 7: Retry Interval${NC}"
  echo "  Recommended: 60-90s (fast enough to catch slots, avoids rate limits)"
  read -rp "  Min wait seconds [$WAIT_MIN]: " input
  [ -n "$input" ] && WAIT_MIN="$input"
  read -rp "  Max wait seconds [$WAIT_MAX]: " input
  [ -n "$input" ] && WAIT_MAX="$input"

  # Notifications
  echo ""
  echo -e "${BOLD}Step 8: Notifications${NC}"
  if command -v osascript &>/dev/null; then
    echo -e "  ${GREEN}macOS detected — voice + notification alerts enabled${NC}"
    NOTIFY_MACOS=true
  fi
  read -rp "  Enable Telegram notifications? (y/N): " input
  if [[ "$input" =~ ^[Yy] ]]; then
    NOTIFY_TELEGRAM=true
    read -rp "  Telegram bot token: " TELEGRAM_BOT_TOKEN
    read -rp "  Telegram chat ID: " TELEGRAM_CHAT_ID
  fi

  save_config

  echo ""
  echo -e "${GREEN}${BOLD}Setup complete!${NC}"
  echo ""
  echo "  Start grabbing:  oci-a1-grabber --background"
  echo "  Check status:    oci-a1-grabber status"
  echo "  View log:        tail -30 $LOG_FILE"
}

# ============================================================
# Status command
# ============================================================
cmd_status() {
  if [ ! -f "$LOG_FILE" ]; then
    echo "No log file found. Has the grabber been started?"
    exit 1
  fi
  echo -e "${BOLD}${CYAN}oci-a1-grabber status${NC}"
  echo ""
  # Last 20 lines
  tail -20 "$LOG_FILE"
  echo ""
  # Count attempts
  local attempts
  attempts=$(grep -c "^\\[#" "$LOG_FILE" 2>/dev/null || echo 0)
  echo -e "${BOLD}Total attempts:${NC} $attempts"
  # Check if running
  if pgrep -f "oci-a1-grabber" | grep -v $$ &>/dev/null; then
    echo -e "${BOLD}Status:${NC} ${GREEN}Running${NC}"
  else
    echo -e "${BOLD}Status:${NC} ${RED}Not running${NC}"
  fi
}

# ============================================================
# Stop command
# ============================================================
cmd_stop() {
  local pids
  pids=$(pgrep -f "oci-a1-grabber" 2>/dev/null | grep -v $$ || true)
  if [ -z "$pids" ]; then
    echo "No running oci-a1-grabber process found."
    exit 0
  fi
  echo "$pids" | xargs kill 2>/dev/null || true
  echo -e "${GREEN}Stopped oci-a1-grabber${NC}"
}

# ============================================================
# Pre-flight checks
# ============================================================
preflight() {
  log ""
  log "========================================="
  log "${BOLD}oci-a1-grabber${NC} v${VERSION}"
  log "Started: $(date)"
  log "Region: $REGION"
  log "Retry interval: ${WAIT_MIN}-${WAIT_MAX}s"
  if [ "$TRY_MULTIPLE_SIZES" = true ]; then
    log "Sizes: ${OCPUS}/${MEMORY} + fallbacks"
  else
    log "Size: ${OCPUS}cpu / ${MEMORY}GB"
  fi
  log "========================================="
  log ""

  # Check OCI CLI
  if ! command -v oci &>/dev/null; then
    log "${RED}FATAL: OCI CLI not installed${NC}"
    notify_error "OCI Error" "OCI CLI not installed"
    exit 1
  fi

  # Check for existing instances
  log "[preflight] Checking for existing instances..."
  for state in RUNNING PROVISIONING STARTING; do
    local existing
    existing=$(oci compute instance list \
      --compartment-id "$TENANCY" \
      --display-name "$DISPLAY_NAME" \
      --lifecycle-state "$state" \
      --query "data[0].id" --raw-output 2>/dev/null || echo "")
    if [ -n "$existing" ] && [ "$existing" != "null" ] && [ "$existing" != "None" ]; then
      log "  ${YELLOW}Instance '$DISPLAY_NAME' is $state!${NC}"
      log "  ID: $existing"
      if [ "$state" = "RUNNING" ]; then
        local ip
        ip=$(oci compute instance list-vnics \
          --instance-id "$existing" \
          --query "data[0].\"public-ip\"" --raw-output 2>/dev/null || echo "unknown")
        log "  IP: $ip"
        echo "ssh -i ${SSH_KEY%.pub} ubuntu@$ip" > "$CONNECT_SCRIPT"
        chmod +x "$CONNECT_SCRIPT"
        log "  Connect: $CONNECT_SCRIPT"
        notify_success "OCI Already Running" "IP: $ip"
      fi
      exit 0
    fi
  done
  log "  ${GREEN}✓ No existing instance${NC}"

  # Auth check
  log "[preflight] Checking OCI auth..."
  local auth
  auth=$(oci iam tenancy get --tenancy-id "$TENANCY" --query "data.name" --raw-output 2>&1)
  if [ $? -ne 0 ]; then
    log "  ${RED}FATAL: Auth failed — $auth${NC}"
    notify_error "OCI Error" "Authentication failed"
    exit 1
  fi
  log "  ${GREEN}✓ Auth OK ($auth)${NC}"

  # Subnet check
  log "[preflight] Checking subnet..."
  local subnet_name
  subnet_name=$(oci network subnet get --subnet-id "$SUBNET" --query "data.\"display-name\"" --raw-output 2>&1)
  if [ $? -ne 0 ]; then
    log "  ${RED}FATAL: Subnet not found — $subnet_name${NC}"
    notify_error "OCI Error" "Subnet not found"
    exit 1
  fi
  log "  ${GREEN}✓ Subnet OK ($subnet_name)${NC}"

  # Image check + auto-heal
  log "[preflight] Checking image..."
  local img_name
  img_name=$(oci compute image get --image-id "$IMAGE" --query "data.\"display-name\"" --raw-output 2>&1)
  if [ $? -ne 0 ]; then
    log "  ${YELLOW}Image deprecated. Finding latest...${NC}"
    local new_image
    new_image=$(oci compute image list \
      --compartment-id "$TENANCY" \
      --shape VM.Standard.A1.Flex \
      --query "data[?contains(\"display-name\",'Canonical-Ubuntu-22.04-aarch64')&&!contains(\"display-name\",'Minimal')].id | [0]" \
      --raw-output --all 2>/dev/null || echo "")
    if [ -n "$new_image" ] && [ "$new_image" != "null" ]; then
      IMAGE="$new_image"
      img_name=$(oci compute image get --image-id "$IMAGE" --query "data.\"display-name\"" --raw-output 2>/dev/null || echo "unknown")
      log "  ${GREEN}✓ Auto-replaced: $img_name${NC}"
    else
      log "  ${RED}FATAL: No Ubuntu 22.04 ARM image found${NC}"
      notify_error "OCI Error" "No valid image found"
      exit 1
    fi
  else
    log "  ${GREEN}✓ Image OK ($img_name)${NC}"
  fi

  # SSH key check
  log "[preflight] Checking SSH key..."
  if [ ! -f "$SSH_KEY" ]; then
    log "  ${RED}FATAL: SSH key not found at $SSH_KEY${NC}"
    notify_error "OCI Error" "SSH key missing"
    exit 1
  fi
  log "  ${GREEN}✓ SSH key OK${NC}"

  # Discover availability domains
  log "[preflight] Discovering availability domains..."
  ADS=()
  while IFS= read -r ad; do
    ADS+=("$ad")
  done < <(oci iam availability-domain list \
    --compartment-id "$TENANCY" \
    --query "data[*].name" --raw-output 2>/dev/null | tr -d '[]"' | tr ',' '\n' | sed 's/^ *//')
  if [ ${#ADS[@]} -eq 0 ]; then
    log "  ${RED}FATAL: No availability domains found${NC}"
    exit 1
  fi
  log "  ${GREEN}✓ Found ${#ADS[@]} ADs${NC}"

  log ""
  log "${GREEN}All checks passed. Starting retry loop...${NC}"
  log "========================================="
}

# ============================================================
# Error classification
# ============================================================
CONSECUTIVE_CONFIG_ERRORS=0

classify_error() {
  local result="$1"
  # Capacity — expected
  if echo "$result" | grep -qi "out of.*capacity\|InternalError\|host capacity"; then
    CONSECUTIVE_CONFIG_ERRORS=0
    return 0
  fi
  # Rate limit
  if echo "$result" | grep -qi "TooManyRequests\|rate.limit\|429"; then
    log ""
    log "  ${YELLOW}Rate limited! Backing off 120s...${NC}"
    sleep 120
    CONSECUTIVE_CONFIG_ERRORS=0
    return 0
  fi
  # Config/auth errors
  if echo "$result" | grep -qi "NotAuthenticated\|InvalidParameter\|NotAuthorized\|LimitExceeded\|InvalidSignature\|NotFound\|Unauthorized"; then
    CONSECUTIVE_CONFIG_ERRORS=$((CONSECUTIVE_CONFIG_ERRORS + 1))
    local msg
    msg=$(echo "$result" | grep -o '"message": *"[^"]*"' | head -1)
    log ""
    log "  ${RED}CONFIG ERROR ($CONSECUTIVE_CONFIG_ERRORS/$MAX_CONFIG_ERRORS): $msg${NC}"
    if [ $CONSECUTIVE_CONFIG_ERRORS -ge $MAX_CONFIG_ERRORS ]; then
      log ""
      log "========================================="
      log "${RED}STOPPED — $MAX_CONFIG_ERRORS config errors in a row${NC}"
      log "Last error: $msg"
      log "Full output: ~/oci-a1-grabber-error.txt"
      log "========================================="
      echo "$result" > ~/oci-a1-grabber-error.txt
      notify_error "OCI Stopped" "Config error: $msg"
      exit 1
    fi
    return 1
  fi
  # Unknown
  CONSECUTIVE_CONFIG_ERRORS=$((CONSECUTIVE_CONFIG_ERRORS + 1))
  log_inline "(err?)"
  if [ $CONSECUTIVE_CONFIG_ERRORS -ge $MAX_CONFIG_ERRORS ]; then
    log ""
    log "${RED}STOPPED — too many unknown errors${NC}"
    echo "$result" > ~/oci-a1-grabber-error.txt
    notify_error "OCI Stopped" "Unknown errors"
    exit 1
  fi
  return 1
}

# ============================================================
# Success handler
# ============================================================
handle_success() {
  local result="$1" label="$2" ad="$3" attempt="$4" start_epoch="$5"
  local elapsed=$(( ($(date +%s) - start_epoch) / 60 ))
  log ""
  log ""
  log "========================================="
  log "${GREEN}${BOLD}✅ SUCCESS!${NC}"
  log "Attempt: $attempt"
  log "Time: $(date)"
  log "Elapsed: ${elapsed} minutes"
  log "Shape: $label"
  log "AD: $ad"
  log "========================================="
  echo "$result" > "$INSTANCE_DETAILS_FILE"
  local instance_id
  instance_id=$(echo "$result" | grep '"id"' | head -1 | cut -d'"' -f4)
  log "Instance ID: $instance_id"
  log "Waiting 90s for public IP..."
  sleep 90
  local public_ip=""
  for i in 1 2 3; do
    public_ip=$(oci compute instance list-vnics \
      --instance-id "$instance_id" \
      --query "data[0].\"public-ip\"" --raw-output 2>/dev/null || echo "")
    if [ -n "$public_ip" ] && [ "$public_ip" != "null" ] && [ "$public_ip" != "None" ]; then
      break
    fi
    log "  IP not ready, retry $i/3 in 30s..."
    sleep 30
  done
  log ""
  log "========================================="
  log "${GREEN}${BOLD}🎉 DONE${NC}"
  log "Public IP: $public_ip"
  log "Shape: $label"
  log ""
  log "Connect:"
  log "  ssh -i ${SSH_KEY%.pub} ubuntu@$public_ip"
  log "  or: $CONNECT_SCRIPT"
  log "========================================="
  echo "ssh -i ${SSH_KEY%.pub} ubuntu@$public_ip" > "$CONNECT_SCRIPT"
  chmod +x "$CONNECT_SCRIPT"
  notify_success "OCI Success 🎉" "VM created! IP: $public_ip"
  exit 0
}

# ============================================================
# Main retry loop
# ============================================================
cmd_run() {
  load_config

  # Validate required config
  for var in TENANCY SUBNET SSH_KEY; do
    if [ -z "${!var}" ]; then
      echo -e "${RED}Error: $var not set. Run 'oci-a1-grabber setup' first.${NC}"
      exit 1
    fi
  done

  # Auto-detect image if empty
  if [ -z "$IMAGE" ]; then
    IMAGE=$(oci compute image list \
      --compartment-id "$TENANCY" \
      --shape VM.Standard.A1.Flex \
      --query "data[?contains(\"display-name\",'Canonical-Ubuntu-22.04-aarch64')&&!contains(\"display-name\",'Minimal')].id | [0]" \
      --raw-output --all 2>/dev/null || echo "")
  fi

  # Auto-detect region if empty
  if [ -z "$REGION" ]; then
    REGION=$(grep -A1 "\[$OCI_PROFILE\]" ~/.oci/config 2>/dev/null | grep region | head -1 | cut -d= -f2 | tr -d ' ' || echo "")
  fi

  # Build size list
  local sizes=()
  if [ "$TRY_MULTIPLE_SIZES" = true ]; then
    sizes=("${OCPUS}:${MEMORY}")
    # Add smaller sizes as fallbacks
    if [ "$OCPUS" -ge 4 ]; then sizes+=("2:12"); fi
    if [ "$OCPUS" -ge 2 ]; then sizes+=("1:6"); fi
    # Deduplicate
    local unique_sizes=()
    for s in "${sizes[@]}"; do
      local found=false
      for u in "${unique_sizes[@]:-}"; do [ "$s" = "$u" ] && found=true; done
      [ "$found" = false ] && unique_sizes+=("$s")
    done
    sizes=("${unique_sizes[@]}")
  else
    sizes=("${OCPUS}:${MEMORY}")
  fi

  local no_retry_arg=""
  if [ "$NO_RETRY_FLAG" = true ]; then
    no_retry_arg="--no-retry"
  fi

  preflight

  local attempt=0
  local start_epoch
  start_epoch=$(date +%s)
  local size_index=0

  while true; do
    attempt=$((attempt + 1))
    rotate_log

    # Pick size for this attempt (rotate through sizes)
    local config="${sizes[$((size_index % ${#sizes[@]}))]}"
    local cpus="${config%:*}"
    local ram="${config#*:}"
    size_index=$((size_index + 1))

    local elapsed=$(( ($(date +%s) - start_epoch) / 60 ))
    log_inline "[#${attempt} ${elapsed}min] $(date '+%H:%M:%S') ${cpus}cpu/${ram}GB →"

    for ad in "${ADS[@]}"; do
      local ad_short="${ad##*AD-}"
      log_inline " AD${ad_short}"
      local result
      result=$(oci compute instance launch \
        --compartment-id "$TENANCY" \
        --availability-domain "$ad" \
        --shape VM.Standard.A1.Flex \
        --shape-config "{\"ocpus\":$cpus,\"memoryInGBs\":$ram}" \
        --image-id "$IMAGE" \
        --subnet-id "$SUBNET" \
        --assign-public-ip true \
        --ssh-authorized-keys-file "$SSH_KEY" \
        --display-name "$DISPLAY_NAME" \
        $no_retry_arg 2>&1) || true
      if echo "$result" | grep -q '"lifecycle-state"'; then
        handle_success "$result" "A1.Flex ${cpus}/${ram}" "$ad" "$attempt" "$start_epoch"
      fi
      classify_error "$result" || true
    done

    # Periodic health check
    if [ $((attempt % HEALTH_CHECK_INTERVAL)) -eq 0 ]; then
      log ""
      log "  [health] Checking for existing instance..."
      local existing
      existing=$(oci compute instance list \
        --compartment-id "$TENANCY" \
        --display-name "$DISPLAY_NAME" \
        --lifecycle-state RUNNING \
        --query "data[0].id" --raw-output 2>/dev/null || echo "")
      if [ -n "$existing" ] && [ "$existing" != "null" ] && [ "$existing" != "None" ]; then
        log "  ${GREEN}Instance found!${NC}"
        local ip
        ip=$(oci compute instance list-vnics \
          --instance-id "$existing" \
          --query "data[0].\"public-ip\"" --raw-output 2>/dev/null || echo "unknown")
        log "  IP: $ip"
        echo "ssh -i ${SSH_KEY%.pub} ubuntu@$ip" > "$CONNECT_SCRIPT"
        chmod +x "$CONNECT_SCRIPT"
        notify_success "OCI Success 🎉" "VM found! IP: $ip"
        exit 0
      fi
      # Re-validate auth
      if ! oci iam tenancy get --tenancy-id "$TENANCY" --query "data.name" --raw-output &>/dev/null; then
        log ""
        log "  ${RED}Auth expired!${NC}"
        notify_error "OCI Error" "Auth expired"
        exit 1
      fi
      log "  ${GREEN}✓ Auth valid${NC}"
    fi

    local wait_secs=$((WAIT_MIN + RANDOM % (WAIT_MAX - WAIT_MIN + 1)))
    log " | wait ${wait_secs}s"
    sleep $wait_secs
  done
}

# ============================================================
# Parse CLI arguments
# ============================================================
load_config

case "${1:-}" in
  setup)    cmd_setup; exit 0 ;;
  status)   cmd_status; exit 0 ;;
  stop)     cmd_stop; exit 0 ;;
  --help)   usage ;;
  --version) echo "oci-a1-grabber v${VERSION}"; exit 0 ;;
esac

BACKGROUND=false

while [[ $# -gt 0 ]]; do
  case $1 in
    --tenancy)      TENANCY="$2"; shift 2 ;;
    --subnet)       SUBNET="$2"; shift 2 ;;
    --image)        IMAGE="$2"; shift 2 ;;
    --ssh-key)      SSH_KEY="$2"; shift 2 ;;
    --name)         DISPLAY_NAME="$2"; shift 2 ;;
    --ocpus)        OCPUS="$2"; shift 2 ;;
    --memory)       MEMORY="$2"; shift 2 ;;
    --region)       REGION="$2"; shift 2 ;;
    --profile)      OCI_PROFILE="$2"; shift 2 ;;
    --wait-min)     WAIT_MIN="$2"; shift 2 ;;
    --wait-max)     WAIT_MAX="$2"; shift 2 ;;
    --no-multi-size) TRY_MULTIPLE_SIZES=false; shift ;;
    --background)   BACKGROUND=true; shift ;;
    --config)       CONFIG_FILE="$2"; load_config; shift 2 ;;
    *)              echo "Unknown option: $1"; usage ;;
  esac
done

if [ "$BACKGROUND" = true ]; then
  nohup "$0" > "$LOG_FILE" 2>&1 &
  echo -e "${GREEN}oci-a1-grabber running in background (PID: $!)${NC}"
  echo "  Check: oci-a1-grabber status"
  echo "  Stop:  oci-a1-grabber stop"
  echo "  Log:   tail -30 $LOG_FILE"
  exit 0
fi

cmd_run
