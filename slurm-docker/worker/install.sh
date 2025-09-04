#!/usr/bin/env bash
set -euo pipefail

echo "Starting full installation..."

# Run each component installer
/opt/ldap-client.sh
/opt/worker-slurm.sh --controller=controller

echo "All components installed successfully!"
