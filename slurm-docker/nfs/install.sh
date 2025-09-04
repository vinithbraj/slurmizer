#!/usr/bin/env bash
set -euo pipefail

echo "Starting full installation..."

# Run each component installer
/opt/nfs-server.sh
/opt/ldap-client.sh

echo "All components installed successfully!"
