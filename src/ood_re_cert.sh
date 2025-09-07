#!/usr/bin/env bash
set -euo pipefail

# === Config ===
IP_ADDR="${1:-192.168.11.13}"   # Pass IP as first argument, default to 192.168.11.13
CERT_DIR="/etc/ssl/ood"
CONF_FILE="${CERT_DIR}/ood-openssl.cnf"
KEY_FILE="${CERT_DIR}/ood.key"
CRT_FILE="${CERT_DIR}/ood.crt"
OOD_PORTAL_YML="/etc/ood/config/ood_portal.yml"

echo "[1/5] Creating cert directory..."
sudo mkdir -p "$CERT_DIR"

echo "[2/5] Generating OpenSSL config with SAN for $IP_ADDR..."
sudo tee "$CONF_FILE" >/dev/null <<EOF
[ req ]
default_bits       = 2048
prompt             = no
default_md         = sha256
distinguished_name = dn
x509_extensions    = v3_req

[ dn ]
C  = US
ST = CA
L  = Lab
O  = HPC
CN = $IP_ADDR

[ v3_req ]
subjectAltName = @alt_names

[ alt_names ]
IP.1 = $IP_ADDR
EOF

echo "[3/5] Generating key + self-signed certificate (valid 1 year)..."
sudo openssl req -x509 -nodes -days 365 \
  -newkey rsa:2048 \
  -keyout "$KEY_FILE" \
  -out "$CRT_FILE" \
  -config "$CONF_FILE"

echo "[4/5] Updating OOD portal config ($OOD_PORTAL_YML)..."
sudo sed -i "s/^servername:.*/servername: \"$IP_ADDR\"/" "$OOD_PORTAL_YML"

# Replace ssl: ... auth: block
sudo sed -i "/^ssl:/,/^auth:/c\ssl:\n  - 'SSLCertificateFile \"$CRT_FILE\"'\n  - 'SSLCertificateKeyFile \"$KEY_FILE\"'\n\nauth:" "$OOD_PORTAL_YML"

echo "[5/5] Rebuilding Apache config and reloading..."
sudo /opt/ood/ood-portal-generator/sbin/update_ood_portal
sudo systemctl reload apache2

echo "✅ OOD SSL certificate setup complete for $IP_ADDR"
