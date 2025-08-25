#!/usr/bin/env bash
set -euo pipefail
# ============================================================
# Script purpose:
#   Set up and verify the MUNGE authentication service.
#   MUNGE is required by Slurm for secure authentication
#   between controller and compute nodes.
#
#   This script:
#     1. Ensures required directories exist with correct perms.
#     2. Creates a secure munge.key if missing.
#     3. Starts & enables the MUNGE service.
#     4. Runs a quick self-test to confirm it’s working.
# ============================================================

# --- MUNGE runtime and state directories ---
# Creates (if missing) /etc/munge, /var/lib/munge, /var/log/munge, /run/munge
# Sets owner to user:group "munge" and perms 0700 (owner-only access).
sudo install -o munge -g munge -m 0700 -d /etc/munge
sudo install -o munge -g munge -m 0700 -d /var/lib/munge /var/log/munge /run/munge

# --- Generate munge.key (only if it doesn’t already exist) ---
# Uses /dev/urandom for strong randomness, 1024 bytes.
# Sets ownership to munge:munge and mode 0400 (read-only for owner).
if [ ! -f /etc/munge/munge.key ]; then
  sudo dd if=/dev/urandom of=/etc/munge/munge.key bs=1 count=1024 status=none
  sudo chown munge:munge /etc/munge/munge.key
  sudo chmod 400 /etc/munge/munge.key
fi

# --- Start and enable MUNGE service ---
# Uses systemd if available, falls back to SysV init.
if command -v systemctl >/dev/null 2>&1; then
  sudo systemctl enable --now munge
else
  sudo service munge start
fi

# --- Quick health check ---
# Generates a credential with munge, decodes with unmunge.
# If this fails, exits with error and suggests checking munged.log.
if ! munge -n | unmunge >/dev/null 2>&1; then
  echo "ERROR: MUNGE self-test failed. Check /var/log/munge/munged.log" >&2
  exit 1
fi

echo "MUNGE is up and healthy."