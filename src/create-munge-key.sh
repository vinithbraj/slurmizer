#!/usr/bin/env bash
set -euo pipefail

# --- MUNGE (manual key + service) ---

# Ensure runtime and state dirs exist with correct ownership/perms
sudo install -o munge -g munge -m 0700 -d /etc/munge
sudo install -o munge -g munge -m 0700 -d /var/lib/munge /var/log/munge /run/munge

# Generate a strong random key if missing (equivalent to create-munge-key)
if [ ! -f /etc/munge/munge.key ]; then
  sudo dd if=/dev/urandom of=/etc/munge/munge.key bs=1 count=1024 status=none
  sudo chown munge:munge /etc/munge/munge.key
  sudo chmod 400 /etc/munge/munge.key
fi

# Start and enable MUNGE
if command -v systemctl >/dev/null 2>&1; then
  sudo systemctl enable --now munge
else
  sudo service munge start
fi

# Quick health check (prints decoded credential)
if ! munge -n | unmunge >/dev/null 2>&1; then
  echo "ERROR: MUNGE self-test failed. Check /var/log/munge/munged.log" >&2
  exit 1
fi

echo "MUNGE is up and healthy."