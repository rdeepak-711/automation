#!/usr/bin/env bash
# Shared library for all audit scripts
# Source: source "$(dirname "${BASH_SOURCE[0]}")/lib/common.sh"

AUDIT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
OUTPUT_DIR="$AUDIT_DIR/../../output/audit"
mkdir -p "$OUTPUT_DIR"
OUTPUT_DIR="$(cd "$OUTPUT_DIR" && pwd)"

# ── Server 2 (default) ────────────────────────────────────────────────────────
SSH_KEY="$HOME/.ssh/id_rsa_bluehost2"
SSH_HOST="dpskbcmy@50.6.155.174"
SSH_OPTS="-i $SSH_KEY -o StrictHostKeyChecking=no -o IdentitiesOnly=yes -o ConnectTimeout=15"

# ── Server 1 ──────────────────────────────────────────────────────────────────
SSH_KEY_S1="$HOME/.ssh/id_rsa_bluehost_old"
SSH_HOST_S1="kzrmeomy@50.6.109.30"
SSH_OPTS_S1="-i $SSH_KEY_S1 -o StrictHostKeyChecking=no -o IdentitiesOnly=yes -o ConnectTimeout=15"

resolve_server() {
  local hostname="$1"
  case "$hostname" in
    auschwitz-guide.com|operagarnier-guide.com) echo "1" ;;
    *) echo "2" ;;
  esac
}

resolve_wp_path() {
  local hostname="$1"
  case "$hostname" in
    # ── Server 1 ──────────────────────────────────────────────────────────────
    auschwitz-guide.com)       echo "/home1/kzrmeomy/public_html/website_ce6ca565" ;;
    operagarnier-guide.com)    echo "/home1/kzrmeomy/public_html/website_b9cdec12" ;;
    montsaintmichel-guide.com) echo "/home1/dpskbcmy/public_html/website_58b542cb" ;;
    # ── Server 2 ──────────────────────────────────────────────────────────────
    topkapipalace-guide.com)   echo "/home1/dpskbcmy/public_html/website_topkapi" ;;
    bluemosque-guide.com)      echo "/home1/dpskbcmy/public_html" ;;
    hagiasophia-guide.com)     echo "/home1/dpskbcmy/public_html/website_204db6f9" ;;
    vangoghmuseum-guide.com)   echo "/home1/dpskbcmy/public_html/website_da6eadef" ;;
    plitvicelakes-guide.com)   echo "/home1/dpskbcmy/public_html/website_plitvice" ;;
    angkorwat-guide.com)       echo "/home1/dpskbcmy/public_html/website_angkorwat" ;;
    pyramidsofgiza-guide.com)  echo "/home1/dpskbcmy/public_html/website_pyramids" ;;
    basilicacistern-guide.com) echo "/home1/dpskbcmy/public_html/website_basilica" ;;
    *) echo "" ;;
  esac
}

# Set active SSH vars based on hostname (call after resolve_wp_path)
_set_ssh_for_host() {
  local server
  server="$(resolve_server "$1")"
  if [[ "$server" == "1" ]]; then
    SSH_KEY="$SSH_KEY_S1"
    SSH_HOST="$SSH_HOST_S1"
    SSH_OPTS="$SSH_OPTS_S1"
  fi
}

# Run command on server
ssh_run() {
  SSH_AUTH_SOCK="" ssh $SSH_OPTS $SSH_HOST "$@"
}

# Run WP-CLI command on server
wp_run() {
  local wp_path="$1"; shift
  SSH_AUTH_SOCK="" ssh $SSH_OPTS $SSH_HOST "wp $* --path=$wp_path"
}

# Upload a file to server temp
ssh_upload() {
  local local_file="$1"
  local remote_file="$2"
  SSH_AUTH_SOCK="" scp $SSH_OPTS "$local_file" "$SSH_HOST:$remote_file"
}

# Save output file
save_output() {
  local step="$1"
  local hostname="$2"
  local ext="${3:-json}"
  echo "$OUTPUT_DIR/${step}-${hostname}.${ext}"
}
