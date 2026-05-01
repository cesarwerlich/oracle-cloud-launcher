#!/bin/bash
# Install/uninstall a per-account launchd job from the template.
#
# Usage:
#   ./scripts/install-launchd.sh install <account> <minute_a> <minute_b> [reverse_domain]
#   ./scripts/install-launchd.sh uninstall <account> [reverse_domain]
#   ./scripts/install-launchd.sh status
#
# Examples:
#   ./scripts/install-launchd.sh install gmx 0 30
#   ./scripts/install-launchd.sh install cdw 15 45
#   ./scripts/install-launchd.sh install custom 5 35 com.mycorp
#   ./scripts/install-launchd.sh uninstall gmx
#   ./scripts/install-launchd.sh status

set -euo pipefail

REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TEMPLATE="$REPO_DIR/templates/launchd.plist.template"
LAUNCH_AGENTS="$HOME/Library/LaunchAgents"
DEFAULT_REVERSE_DOMAIN="${LAUNCHD_REVERSE_DOMAIN:-com.local}"

usage() {
  sed -n '2,12p' "$0"
  exit 1
}

action="${1:-}"
case "$action" in
  install)
    account="${2:?missing account name}"
    minute_a="${3:?missing minute_a}"
    minute_b="${4:?missing minute_b}"
    reverse_domain="${5:-$DEFAULT_REVERSE_DOMAIN}"

    if [[ ! -f "$REPO_DIR/accounts/${account}.env" ]]; then
      echo "ERROR: accounts/${account}.env does not exist." >&2
      echo "  Create it from accounts/example.env first." >&2
      exit 1
    fi

    plist_name="${reverse_domain}.oracle-${account}.plist"
    plist_path="$LAUNCH_AGENTS/$plist_name"

    mkdir -p "$LAUNCH_AGENTS"
    sed -e "s|{{REPO_DIR}}|$REPO_DIR|g" \
        -e "s|{{ACCOUNT}}|$account|g" \
        -e "s|{{MINUTE_A}}|$minute_a|g" \
        -e "s|{{MINUTE_B}}|$minute_b|g" \
        -e "s|{{HOME}}|$HOME|g" \
        -e "s|{{REVERSE_DOMAIN}}|$reverse_domain|g" \
        "$TEMPLATE" > "$plist_path"

    label="${reverse_domain}.oracle-${account}"
    launchctl unload "$plist_path" 2>/dev/null || true
    launchctl load "$plist_path"
    echo "✅ Installed: $plist_path"
    echo "   Label: $label"
    echo "   Schedule: every hour at :$minute_a and :$minute_b"
    echo "   Trigger now: launchctl start $label"
    echo "   View logs: tail -f ~/Library/Logs/oracle-${account}-launch.log"
    ;;

  uninstall)
    account="${2:?missing account name}"
    reverse_domain="${3:-$DEFAULT_REVERSE_DOMAIN}"
    plist_path="$LAUNCH_AGENTS/${reverse_domain}.oracle-${account}.plist"

    if [[ ! -f "$plist_path" ]]; then
      echo "Not installed: $plist_path"
      exit 0
    fi

    launchctl unload "$plist_path" 2>/dev/null || true
    rm "$plist_path"
    echo "✅ Uninstalled: $plist_path"
    ;;

  status)
    echo "=== Loaded oracle-* launchd jobs ==="
    launchctl list | grep -i oracle- || echo "(none)"
    echo ""
    echo "=== Installed plist files ==="
    ls -la "$LAUNCH_AGENTS"/*oracle-*.plist 2>/dev/null || echo "(none)"
    ;;

  *)
    usage
    ;;
esac
