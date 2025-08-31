#!/usr/bin/env bash
set -uo pipefail

# Open OnDemand + Slurm client + MUNGE quick-setup for Ubuntu (focal/jammy/noble)
#
# FOLLOWS OFFICIAL STEPS to add the OOD apt repository and install 'ondemand'.
# Docs: https://osc.github.io/ood-documentation/latest/installation/install-software.html#add-repository-and-install
#
# Usage:
#   sudo ./install-ood-for-slurm-remote.sh <SLURM_CTLD_HOST_OR_IP> \
#     [--cluster-name <NAME>] \
#     [--basic-auth-user <WEBUSER>] \
#     [--munge-src <user@host:/etc/munge/munge.key>]
#
# Examples:
#   sudo ./install-ood-for-slurm-remote.sh 192.168.11.132
#   sudo ./install-ood-for-slurm-remote.sh 192.168.11.132 --cluster-name mini --basic-auth-user admin
#   sudo ./install-ood-for-slurm-remote.sh 192.168.11.132 --munge-src root@192.168.11.132:/etc/munge/munge.key

# --- args ---
if [[ $# -lt 1 ]]; then
  echo "Usage: sudo $0 <SLURM_CTLD_HOST_OR_IP> [--cluster-name <NAME>] [--basic-auth-user <WEBUSER>] [--munge-src <user@host:/etc/munge/munge.key>]"
  exit 1
fi

SLURM_CTLD="$1"; shift
CLUSTER_NAME="slurm"
BASIC_USER="admin"
MUNGE_SRC=""

while [[ $# -gt 0 ]]; do
  case "$1" in
    --cluster-name)     CLUSTER_NAME="$2"; shift 2;;
    --basic-auth-user)  BASIC_USER="$2"; shift 2;;
    --munge-src)        MUNGE_SRC="$2"; shift 2;;
    *) echo "Unknown arg: $1"; exit 1;;
  esac
done

[[ $EUID -eq 0 ]] || { echo "Run as root (use sudo)."; exit 1; }

source /etc/os-release
CODENAME="${VERSION_CODENAME:-}"
case "$CODENAME" in
  focal|jammy|noble) ;;
  *)
    echo "This script supports Ubuntu 20.04 (focal), 22.04 (jammy), and 24.04 (noble). Detected: ${CODENAME:-unknown}"
    ;;
esac

echo "[*] Slurm controller        : ${SLURM_CTLD}"
echo "[*] Cluster name            : ${CLUSTER_NAME}"
echo "[*] OOD web user (BasicAuth): ${BASIC_USER}"
echo "[*] Ubuntu codename         : ${CODENAME}"

# --- base deps ---
apt-get update -y
DEBIAN_FRONTEND=noninteractive apt-get install -y \
  apt-transport-https ca-certificates wget curl gnupg lsb-release \
  apache2 apache2-utils \
  slurm-client \
  munge libmunge2

# --- add OOD apt repo (official) & install ondemand ---
TMP_DEB="/tmp/ondemand-release-web_${CODENAME}.deb"
case "$CODENAME" in
  focal) OOD_DEB_URL="https://apt.osc.edu/ondemand/4.0/ondemand-release-web_4.0.0-focal_all.deb" ;;
  jammy) OOD_DEB_URL="https://apt.osc.edu/ondemand/4.0/ondemand-release-web_4.0.0-jammy_all.deb" ;;
  noble) OOD_DEB_URL="https://apt.osc.edu/ondemand/4.0/ondemand-release-web_4.0.0-noble_all.deb" ;;
esac

echo "[*] Downloading OOD repo descriptor for ${CODENAME}..."
wget -O "${TMP_DEB}" "${OOD_DEB_URL}"
apt-get install -y "${TMP_DEB}"
apt-get update -y
apt-get install -y ondemand  # official package from OSC repo

# --- MUNGE setup ---
if [[ -n "${MUNGE_SRC}" ]]; then
  echo "[*] Copying MUNGE key from ${MUNGE_SRC} ..."
  tmpdst="$(mktemp)"
  if scp -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null "${MUNGE_SRC}" "${tmpdst}"; then
    install -o munge -g munge -m 0400 "${tmpdst}" /etc/munge/munge.key
    rm -f "${tmpdst}"
    echo "[*] Installed /etc/munge/munge.key from remote."
  else
    echo "[!] Could not scp MUNGE key from ${MUNGE_SRC}; place it manually at /etc/munge/munge.key"
  fi
fi

if [[ -f /etc/munge/munge.key ]]; then
  chown munge:munge /etc/munge/munge.key
  chmod 0400 /etc/munge/munge.key
else
  echo "[!] /etc/munge/munge.key not found. Slurm CLI will fail until the correct key is installed."
fi

systemctl enable munge || true
systemctl restart munge || true

# --- minimal slurm.conf on OOD host (client only) ---
mkdir -p /etc/slurm
SLURM_CONF="/etc/slurm/slurm.conf"
cat > "${SLURM_CONF}" <<EOF
# Minimal slurm.conf for OOD submission node
ClusterName=${CLUSTER_NAME}
SlurmctldHost=${SLURM_CTLD}
SlurmctldPort=6817
SlurmdPort=6818
AuthType=auth/munge
StateSaveLocation=/var/spool/slurmctld
SlurmdSpoolDir=/var/spool/slurmd
SwitchType=switch/none
MpiDefault=none
ProctrackType=proctrack/pgid
ReturnToService=2
SlurmctldTimeout=120
SlurmdTimeout=300
SchedulerType=sched/backfill
# This node doesn't run slurmd; it only needs to reach the controller.
EOF
chmod 644 "${SLURM_CONF}"

# --- OOD portal config (Basic Auth quickstart) ---
mkdir -p /etc/ood/config /etc/ood/config/clusters.d
PORTAL_YML="/etc/ood/config/ood_portal.yml"
HTPASS_FILE="/etc/ood/ood_portal_htpasswd"

if [[ ! -f "${HTPASS_FILE}" ]]; then
  RAND_PASS="pass123"
  htpasswd -b -c "${HTPASS_FILE}" "${BASIC_USER}" "${RAND_PASS}"
  echo "[*] Created Basic Auth credentials:"
  echo "    Username: ${BASIC_USER}"
  echo "    Password: ${RAND_PASS}"
else
  echo "[*] Using existing Basic Auth file: ${HTPASS_FILE}"
fi
chmod 640 "${HTPASS_FILE}"
chown root:www-data "${HTPASS_FILE}"

cat > "${PORTAL_YML}" <<'YAML'
---
servername: "localhost"
use_ubuntu_apache: true
ssl:
  - 'SSLCertificateFile "/etc/ssl/certs/ssl-cert-snakeoil.pem"'
  - 'SSLCertificateKeyFile "/etc/ssl/private/ssl-cert-snakeoil.key"'

auth:
  - 'AuthType Basic'
  - 'AuthName "Open OnDemand"'
  - 'AuthUserFile "/etc/ood/ood_portal_htpasswd"'
  - 'Require valid-user'
YAML

# Enable needed Apache mods
a2enmod ssl proxy proxy_http headers rewrite auth_basic authn_file || true

# Generate Apache vhost for OOD (the package ships update_ood_portal)
if command -v /opt/ood/ood-portal-generator/sbin/update_ood_portal >/dev/null 2>&1; then
  /opt/ood/ood-portal-generator/sbin/update_ood_portal
fi

# Start/enable Apache (per official instructions)
systemctl start apache2
systemctl enable apache2

# --- OOD cluster wiring (Slurm adapter) ---
CLUSTER_YML="/etc/ood/config/clusters.d/${CLUSTER_NAME}.yml"
cat > "${CLUSTER_YML}" <<YAML
---
v2:
  metadata:
    title: "${CLUSTER_NAME}"
  login:
    host: "localhost"
  job:
    adapter: "slurm"
    conf: "/etc/slurm/slurm.conf"
    bin: "/usr/bin"
YAML

# --- sanity checks ---
echo "[*] Checking Slurm CLI..."
set +e
sinfo -h >/dev/null 2>&1
RC=$?
set -e
if [[ $RC -ne 0 ]]; then
  echo "[!] 'sinfo' failed. Likely MUNGE or controller connectivity."
  echo "    - Ensure /etc/munge/munge.key matches the controller (0400, munge:munge)."
  echo "    - Verify ${SLURM_CTLD} reachable; ports 6817/6818 open."
fi

echo
echo "[✓] OOD installed via official apt repo and wired to Slurm controller at ${SLURM_CTLD}."
echo "    - Portal config : ${PORTAL_YML}"
echo "    - Basic Auth    : ${HTPASS_FILE}"
echo "    - Slurm conf    : ${SLURM_CONF}"
echo "    - Cluster YAML  : ${CLUSTER_YML}"
echo
echo "Next:"
echo "  1) If you didn't pass --munge-src, copy your controller's /etc/munge/munge.key here, then: systemctl restart munge"
echo "  2) Browse to https://<this-host>/ (you'll see OOD asking to set up auth; we already configured Basic Auth)."
