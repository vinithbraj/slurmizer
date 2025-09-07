# 1. Make directory for OOD certs
sudo mkdir -p /etc/ssl/ood

# 2. Create OpenSSL config with SAN for IP
cat <<'EOF' | sudo tee /etc/ssl/ood/ood-openssl.cnf
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
CN = 192.168.11.13

[ v3_req ]
subjectAltName = @alt_names

[ alt_names ]
IP.1 = 192.168.11.13
EOF

# 3. Generate key + cert (valid 1 year)
sudo openssl req -x509 -nodes -days 365 \
  -newkey rsa:2048 \
  -keyout /etc/ssl/ood/ood.key \
  -out /etc/ssl/ood/ood.crt \
  -config /etc/ssl/ood/ood-openssl.cnf

# 4. Update OOD portal config to use IP + new cert
sudo sed -i 's/^servername:.*/servername: "192.168.11.13"/' /etc/ood/config/ood_portal.yml

sudo sed -i '/^ssl:/,/^auth:/c\ssl:\n  - '\''SSLCertificateFile "/etc/ssl/ood/ood.crt"'\''\n  - '\''SSLCertificateKeyFile "/etc/ssl/ood/ood.key"'\''\n\nauth:' /etc/ood/config/ood_portal.yml

# 5. Rebuild Apache config & reload
sudo /opt/ood/ood-portal-generator/sbin/update_ood_portal
sudo systemctl reload apache2
