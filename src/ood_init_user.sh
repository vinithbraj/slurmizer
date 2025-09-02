#!/usr/bin/env bash
set -euo pipefail

if [[ $# -lt 2 ]]; then
  echo "Usage: $0 <username> <password>"
  exit 1
fi

USERNAME="$1"
PASSWORD="$2"

# Check if expect is installed
if ! command -v expect >/dev/null 2>&1; then
  echo "Installing 'expect' (needed for password automation)..."
  sudo apt-get update && sudo apt-get install -y expect
fi

# Use expect to handle the password prompt for sudo
expect <<EOF
spawn sudo -u "$USERNAME" -i
expect {
  "password for" {
    send "$PASSWORD\r"
    exp_continue
  }
  eof
}
interact
EOF