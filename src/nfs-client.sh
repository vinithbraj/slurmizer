#!/usr/bin/env bash
set -euo pipefail

# ==== Tunables ====
SERVER="${SERVER:-nfs}"       # NFS server IP or hostname
DOMAIN="${DOMAIN:-lab.local}"           # must match server's idmapd Domain
MOUNT_HOME="${MOUNT_HOME:-/home}"
MOUNT_SCRATCH="${MOUNT_SCRATCH:-/shared/scratch}"

apt-get update
apt-get install -y nfs-common acl

# NFSv4 idmap domain
sed -i "s/^#*Domain = .*/Domain = ${DOMAIN}/" /etc/idmapd.conf
systemctl restart nfs-client.target || true

# Create mount points
mkdir -p "$MOUNT_HOME" "$MOUNT_SCRATCH"

# Strongly recommended: systemd automounts (fast boot, on-demand)
# Mount NFSv4 pseudo paths: server:/home and server:/scratch
if ! grep -q "$MOUNT_HOME" /etc/fstab; then
  echo "server:/home fstab entry"
  cat <<EOF >> /etc/fstab
${SERVER}:/home   ${MOUNT_HOME}     nfs4  rw,nofail,_netdev,noatime  0 0
${SERVER}:/scratch ${MOUNT_SCRATCH} nfs4  rw,nofail,_netdev,noatime  0 0
EOF
fi

systemctl daemon-reload
mount -a

echo "[OK] Mounted ${SERVER}:/home -> ${MOUNT_HOME}"
echo "[OK] Mounted ${SERVER}:/scratch -> ${MOUNT_SCRATCH}"
