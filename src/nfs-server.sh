#!/usr/bin/env bash
set -euo pipefail

# ==== Tunables ====
NET_CIDR="${NET_CIDR:-192.168.11.0/24}"     # your cluster subnet
DOMAIN="${DOMAIN:-lab.local}"                # for idmapd (match your LDAP domain if possible)
HOMEROOT="${HOMEROOT:-/home}"                # where home dirs live
SCRATCH="${SCRATCH:-/shared/scratch}"        # shared scratch
NFS_PSEUDO="${NFS_PSEUDO:-/srv/nfs4}"        # NFSv4 pseudo-root

apt-get update
apt-get install -y nfs-kernel-server acl

# Create directories (bind-mount into an NFSv4 pseudo tree)
mkdir -p "$HOMEROOT" "$SCRATCH" "$NFS_PSEUDO"/{home,scratch}

# Optional: sane perms (homes are LDAP-managed; keep restrictive default)
chmod 755 "$HOMEROOT"
mkdir -p "$SCRATCH"
chmod 1777 "$SCRATCH"   # sticky bit scratch, like /tmp

# Bind-mount real paths into the NFSv4 pseudo tree
grep -q " $NFS_PSEUDO/home " /etc/fstab || echo "$HOMEROOT  $NFS_PSEUDO/home  none  bind  0 0" >> /etc/fstab
grep -q " $NFS_PSEUDO/scratch " /etc/fstab || echo "$SCRATCH  $NFS_PSEUDO/scratch  none  bind  0 0" >> /etc/fstab
mount -a

# NFSv4 only; set idmap domain
sed -i "s/^#*Domain = .*/Domain = ${DOMAIN}/" /etc/idmapd.conf

# Exports (NFSv4 pseudo-root + child exports)
cat >/etc/exports <<EOF
$NFS_PSEUDO          $NET_CIDR(ro,fsid=0,sec=sys,crossmnt,no_subtree_check)
$NFS_PSEUDO/home     $NET_CIDR(rw,sec=sys,no_subtree_check,no_root_squash,async)
$NFS_PSEUDO/scratch  $NET_CIDR(rw,sec=sys,no_subtree_check,no_root_squash,async)
EOF

exportfs -ra

# NFS server config: v4 only, disable v2/v3
grep -q '^RPCMOUNTDOPTS' /etc/default/nfs-kernel-server || echo 'RPCMOUNTDOPTS="--manage-gids"' >> /etc/default/nfs-kernel-server
# Make sure v4 is enabled (it is by default on Ubuntu), nfsd threads:
sed -i 's/^#*RPCNFSDCOUNT=.*/RPCNFSDCOUNT="16"/' /etc/default/nfs-kernel-server || true

systemctl enable --now nfs-server

echo "[OK] NFSv4 server is up."
echo "Exported: filesrv:/    (pseudo-root), filesrv:/home, filesrv:/scratch"
echo "Clients should mount:   filesrv:/home  -> /home"
echo "                        filesrv:/scratch -> /shared/scratch"
echo "sudo exportfs -ra, sudo exportfs -v"
