#!/usr/bin/env bash
set -euo pipefail

echo "Starting full installation..."

# Run each component installer
/opt/ldap-client.sh
/opt/controller-slurm.sh worker1

echo "All components installed successfully!"
