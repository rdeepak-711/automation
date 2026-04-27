#!/usr/bin/env bash
# Shared library for all audit scripts
# Source: source "$(dirname "${BASH_SOURCE[0]}")/lib/common.sh"

AUDIT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
OUTPUT_DIR="$AUDIT_DIR/../../output/audit"
mkdir -p "$OUTPUT_DIR"
OUTPUT_DIR="$(cd "$OUTPUT_DIR" && pwd)"

SSH_KEY="$HOME/.ssh/id_rsa_bluehost2"
SSH_HOST="dpskbcmy@50.6.155.174"
SSH_OPTS="-i $SSH_KEY -o StrictHostKeyChecking=no -o IdentitiesOnly=yes -o ConnectTimeout=15"

resolve_wp_path() {
  local hostname="$1"
  case "$hostname" in
    topkapipalace-guide.com)   echo "/home1/dpskbcmy/public_html/website_topkapi" ;;
    bluemosque-guide.com)      echo "/home1/dpskbcmy/public_html" ;;
    hagiasophia-guide.com)     echo "/home1/dpskbcmy/public_html/website_204db6f9" ;;
    montsaintmichel-guide.com) echo "/home1/dpskbcmy/public_html/website_58b542cb" ;;
    vangoghmuseum-guide.com)   echo "/home1/dpskbcmy/public_html/website_da6eadef" ;;
    plitvicelakes-guide.com)   echo "/home1/dpskbcmy/public_html/website_plitvice" ;;
    angkorwat-guide.com)       echo "/home1/dpskbcmy/public_html/website_angkorwat" ;;
    pyramidsofgiza-guide.com)  echo "/home1/dpskbcmy/public_html/website_pyramids" ;;
    *) echo "" ;;
  esac
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
