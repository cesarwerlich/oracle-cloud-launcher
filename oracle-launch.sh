#!/bin/bash
# Oracle Cloud Instance Launcher (multi-account)
#
# Usage:
#   ./oracle-launch.sh <account-name>
#
# Looks for config at: accounts/<account-name>.env
# Examples:
#   ./oracle-launch.sh gmx   → reads accounts/gmx.env
#   ./oracle-launch.sh cdw   → reads accounts/cdw.env

set -euo pipefail

# ── Account argument ───────────────────────────────────────────────
if [[ $# -lt 1 ]]; then
  echo "ERROR: missing account name. Usage: $0 <account-name>" >&2
  exit 1
fi
ACCOUNT_NAME="$1"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ENV_FILE="${SCRIPT_DIR}/accounts/${ACCOUNT_NAME}.env"

# ── Lock dir (per-account, prevents concurrent runs of the same account) ──
LOCK_DIR="/tmp/oracle-${ACCOUNT_NAME}.lock"
if ! mkdir "$LOCK_DIR" 2>/dev/null; then
  if [[ -f "$LOCK_DIR" ]]; then
    rm -f "$LOCK_DIR"
    if ! mkdir "$LOCK_DIR" 2>/dev/null; then
      echo "[$(date '+%Y-%m-%d %H:%M:%S')] [${ACCOUNT_NAME}] Another instance is already running. Exiting." >&2
      exit 0
    fi
  else
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] [${ACCOUNT_NAME}] Another instance is already running. Exiting." >&2
    exit 0
  fi
fi
trap 'rmdir "$LOCK_DIR" 2>/dev/null' EXIT

# ── Pre-flight checks ──────────────────────────────────────────────
for cmd in oci jq curl; do
  if ! command -v "$cmd" &>/dev/null; then
    echo "ERROR: Required command '$cmd' not found in PATH. Aborting." >&2
    exit 1
  fi
done

if [[ ! -f "$ENV_FILE" ]]; then
  echo "ERROR: account env file not found at $ENV_FILE" >&2
  echo "  Create it from accounts/example.env and fill in your OCI details." >&2
  exit 1
fi

# shellcheck disable=SC1090
source "$ENV_FILE"

# ── Validate required variables ────────────────────────────────────
REQUIRED_VARS=(
  COMPARTMENT_OCID AD_NAMES SUBNET_OCID IMAGE_OCID
  INSTANCE_NAME INSTANCE_SHAPE INSTANCE_OCPUS INSTANCE_MEMORY_GB
  SSH_PUBLIC_KEY_PATH MAX_RETRIES RETRY_INTERVAL
)
missing=()
for var in "${REQUIRED_VARS[@]}"; do
  if [[ -z "${!var:-}" ]]; then
    missing+=("$var")
  fi
done
if [[ ${#missing[@]} -gt 0 ]]; then
  echo "ERROR: Missing required variables in $ENV_FILE: ${missing[*]}" >&2
  exit 1
fi

# ── Account display label (for logs/notifications) ─────────────────
# Falls back to uppercased account name if ACCOUNT_LABEL not set in env.
ACCOUNT_LABEL="${ACCOUNT_LABEL:-$(echo "$ACCOUNT_NAME" | tr '[:lower:]' '[:upper:]')}"

# ── Build OCI CLI extra args ──────────────────────────────────────────
OCI_EXTRA_ARGS=""
if [[ -n "${OCI_CONFIG_FILE:-}" ]]; then
  OCI_EXTRA_ARGS="$OCI_EXTRA_ARGS --config-file $OCI_CONFIG_FILE"
fi
if [[ -n "${OCI_PROFILE:-}" ]]; then
  OCI_EXTRA_ARGS="$OCI_EXTRA_ARGS --profile $OCI_PROFILE"
fi

# ── SSH key validation ─────────────────────────────────────────────
SSH_PUBLIC_KEY_PATH="${SSH_PUBLIC_KEY_PATH/#\~/$HOME}"

if [[ ! -f "$SSH_PUBLIC_KEY_PATH" ]]; then
  echo "ERROR: SSH public key not found at $SSH_PUBLIC_KEY_PATH" >&2
  exit 1
fi
if ! grep -q '^ssh-' "$SSH_PUBLIC_KEY_PATH"; then
  echo "ERROR: SSH public key at $SSH_PUBLIC_KEY_PATH does not contain a valid key" >&2
  exit 1
fi

# ── Parse AD list ──────────────────────────────────────────────────
IFS=' ' read -r -a ADS <<< "$AD_NAMES"
if [[ ${#ADS[@]} -eq 0 ]]; then
  echo "ERROR: AD_NAMES must contain at least one availability domain" >&2
  exit 1
fi

# ── Logging (per-account log file) ─────────────────────────────────
LOG_FILE="${HOME}/Library/Logs/oracle-${ACCOUNT_NAME}-launch.log"
mkdir -p "$(dirname "$LOG_FILE")"

log() { echo "[$(date '+%Y-%m-%d %H:%M:%S')] [${ACCOUNT_LABEL}] $*" | tee -a "$LOG_FILE"; }

# ── Notifications ──────────────────────────────────────────────────
notify() {
  local msg="$1"
  local prefixed="${ACCOUNT_LABEL}: ${msg}"

  # macOS Notification Center
  osascript -e "display notification \"$prefixed\" with title \"Oracle Cloud\"" 2>/dev/null || true

  # Telegram (optional)
  if [[ -n "${TELEGRAM_BOT_TOKEN:-}" && -n "${TELEGRAM_CHAT_ID:-}" ]]; then
    local resp http_code body
    resp=$(curl -sS -w "\n%{http_code}" -m 10 -X POST \
      "https://api.telegram.org/bot${TELEGRAM_BOT_TOKEN}/sendMessage" \
      --data-urlencode "chat_id=${TELEGRAM_CHAT_ID}" \
      --data-urlencode "text=🖥️ ${prefixed}" 2>&1) || true
    http_code=$(echo "$resp" | tail -n1)
    body=$(echo "$resp" | sed '$d')

    if [[ "$http_code" != "200" ]]; then
      log "  [telegram] HTTP $http_code — notification may not have been delivered"
    elif ! echo "$body" | jq -e '.ok == true' &>/dev/null; then
      local err_desc
      err_desc=$(echo "$body" | jq -r '.description // "unknown error"' 2>/dev/null || echo "unknown error")
      log "  [telegram] API error: $err_desc"
    fi
  fi
}

# ── Existence check (with retry on API failure) ────────────────────
log "Checking for existing instance: $INSTANCE_NAME"
EXISTING="null"
CHECK_ATTEMPT=0
MAX_CHECK_ATTEMPTS=3

while [[ $CHECK_ATTEMPT -lt $MAX_CHECK_ATTEMPTS ]]; do
  if EXISTING=$(oci $OCI_EXTRA_ARGS compute instance list \
    --compartment-id "$COMPARTMENT_OCID" \
    --display-name "$INSTANCE_NAME" \
    --query "data[?\"lifecycle-state\"!='TERMINATED'] | [0]" 2>/dev/null); then
    break
  fi
  CHECK_ATTEMPT=$((CHECK_ATTEMPT + 1))
  if [[ $CHECK_ATTEMPT -lt $MAX_CHECK_ATTEMPTS ]]; then
    log "  Existence check failed, retrying ($CHECK_ATTEMPT/$MAX_CHECK_ATTEMPTS)..."
    sleep 10
  fi
done

if [[ "$EXISTING" != "null" && -n "$EXISTING" ]]; then
  STATE=$(echo "$EXISTING" | jq -r '."lifecycle-state" // "UNKNOWN"')
  ID=$(echo "$EXISTING" | jq -r '.id // "UNKNOWN"')
  log "Instance already exists (state: $STATE, id: $ID). Exiting."
  notify "Instance already exists ($STATE)"
  exit 0
fi

# ── Main launch loop ───────────────────────────────────────────────
TOTAL_ADS=${#ADS[@]}
log "Launching new instance (max $MAX_RETRIES attempts, ${RETRY_INTERVAL}s between, rotating across ${TOTAL_ADS} AD(s))"
attempt=1
while [[ $attempt -le $MAX_RETRIES ]]; do
  AD_IDX=$(( (attempt - 1) % TOTAL_ADS ))
  AD_NAME="${ADS[$AD_IDX]}"
  log "Attempt $attempt/$MAX_RETRIES → $AD_NAME"

  RESPONSE=$(oci $OCI_EXTRA_ARGS compute instance launch \
    --availability-domain "$AD_NAME" \
    --compartment-id "$COMPARTMENT_OCID" \
    --display-name "$INSTANCE_NAME" \
    --vnic-display-name "vnic-$INSTANCE_NAME" \
    --hostname-label "$INSTANCE_NAME" \
    --shape "$INSTANCE_SHAPE" \
    --shape-config "{\"ocpus\":$INSTANCE_OCPUS,\"memoryInGBs\":$INSTANCE_MEMORY_GB}" \
    --image-id "$IMAGE_OCID" \
    --subnet-id "$SUBNET_OCID" \
    --assign-public-ip true \
    --ssh-authorized-keys-file "$SSH_PUBLIC_KEY_PATH" 2>&1 || true)

  ERROR_CODE=$(echo "$RESPONSE" | jq -r '.code // empty' 2>/dev/null || true)
  ERROR_MSG=$(echo "$RESPONSE" | jq -r '.message // empty' 2>/dev/null || true)

  # Structural check: did we get a PROVISIONING instance?
  if echo "$RESPONSE" | jq -e '.data."lifecycle-state" == "PROVISIONING"' &>/dev/null; then
    log "SUCCESS! Instance is PROVISIONING in $AD_NAME."
    notify "✅ Instance created and PROVISIONING! ($AD_NAME)"
    exit 0

  # Out of capacity — try next AD
  elif [[ "${ERROR_MSG:-}" =~ [Oo]ut\ of.*[Cc]apacity ]] || \
       echo "$RESPONSE" | grep -qi "out of.*capacity"; then
    log "$AD_NAME: out of capacity — ${ERROR_MSG:-no detail}"

  # Rate limit — back off until next launchd run
  elif [[ "$ERROR_CODE" == "TooManyRequests" ]]; then
    log "$AD_NAME: rate limited (TooManyRequests)"
    notify "🚦 Rate limited - will try next run"
    exit 0

  # Connection issues — back off
  elif [[ "${ERROR_MSG:-}" =~ [Tt]imed\ ?[Oo]ut|[Tt]imeout|[Cc]onnection ]] || \
       echo "$RESPONSE" | grep -qi "timed out\|timeout\|connection"; then
    log "$AD_NAME: connection issue — ${ERROR_MSG:-no detail}"
    notify "🌐 Connection timeout - will try next run"
    exit 0

  # Fatal auth / permission errors — don't retry
  elif [[ "$ERROR_CODE" == "NotAuthorizedOrNotFound" || "$ERROR_CODE" == "NotAuthenticated" ]]; then
    log "FATAL ($AD_NAME, $ERROR_CODE): ${ERROR_MSG:-$RESPONSE}"
    notify "❌ Auth error ($ERROR_CODE) - check your OCI config"
    exit 1

  # Unknown error — retryable (try next AD instead of dying)
  else
    log "$AD_NAME: unexpected error (${ERROR_CODE:-unknown}) — ${ERROR_MSG:-$RESPONSE}"
  fi

  sleep "$RETRY_INTERVAL"
  ((attempt++))
done

log "Failed after $MAX_RETRIES attempts across ${TOTAL_ADS} AD(s): ${ADS[*]}"
notify "⏱️ Out of capacity — all ${TOTAL_ADS} AD(s) exhausted across $MAX_RETRIES attempts"
# Exit 0: capacity exhaustion is the expected steady-state outcome on free
# tier and shouldn't mark scheduled jobs as failed. Truly fatal conditions
# (auth, config, missing deps) keep returning exit 1 above.
exit 0
