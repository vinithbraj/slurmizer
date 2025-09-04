#!/usr/bin/env bash
set -uo pipefail

echo "Starting full installation..."

# Run each component installer
/opt/ldap-server.sh

echo "All components installed successfully!"
