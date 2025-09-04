#!/usr/bin/env bash
set -euo pipefail

echo "Starting full installation..."

# Run each component installer
/opt/ldap-client.sh
/opt/ood-server.sh controller --cluster-name mini

echo "All components installed successfully!"
