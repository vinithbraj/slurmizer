#!/usr/bin/env bash
set -euo pipefail
# ============================================================
# Script purpose:
#   Provision a Slurm controller node with configless support.
#   Installs required packages, sets up MUNGE, generates slurm.conf,
#   configures JWT authentication for slurmrestd, and starts services.
#
#   Key features:
#     - Tunable vars via env (CLUSTER_NAME, PARTITION_NAME, etc.)
#     - Automatic package install & firewall setup
#     - MUNGE key creation and self-test
#     - slurm.conf auto-generation with optional GPU support
#     - JWT setup for slurmrestd (running as slurm user)
#     - Configless mode enabled for compute nodes
#     - Smoke tests at the end (sinfo, srun, JWT minting)
# ============================================================

# =========================
# Tunables (override via env)
# =========================
CLUSTER_NAME="${CLUSTER_NAME:-mini}"       # cluster name (default: "mini")
PARTITION_NAME="${PARTITION_NAME:-debug}" # default partition name

# Nodes to include in the default partition (default = local host)
NODES="${NODES:-$(hostname -s)}"

ENABLE_CONFIGLESS="${ENABLE_CONFIGLESS:-1}"   # enable configless mode (1=yes)
CONTROLLER_HOST="${CONTROLLER_HOST:-$(hostname -f || hostname -s)}"
GPU_ENABLE="${GPU_ENABLE:-0}"                 # if 1, add GPU support
LISTEN_ADDR="${LISTEN_ADDR:-0.0.0.0}"         # slurmrestd bind address
RESTD_PORT="${RESTD_PORT:-6820}"              # slurmrestd port
OPEN_PORTS="${OPEN_PORTS:-1}"                 # open firewall ports (1=yes)

# =========================
# Derived values
# =========================
HOST_SHORT="$(hostname -s)"
HOST_FQDN="$(hostname -f || echo "$HOST_SHORT")"
CPUS="$(nproc)"
MEM_MB="$(free -m | awk '/Mem:/ {printf "%d", $2*0.95}')"  # total RAM minus ~5%
echo "CPUS=$CPUS MEM_MB=$MEM_MB"

# =========================
# Helpers
# =========================
log()  { echo "[*] $*"; }
warn() { echo "[!] $*"; }
die()  { echo "[x] $*" >&2; exit 1; }

need_root() {
  [[ $EUID -eq 0 ]] || die "Run as root or with sudo."
}

# =========================
# Install required packages
# =========================
echo "[*] Installing packages..."
sudo apt-get update -y
sudo apt-get install -y \
  slurm-wlm slurmctld slurmd slurm-client slurmrestd \
  munge libmunge2 libmunge-dev jq chrony libpmix2 libpmix-dev binutils

# (Optional) open firewall ports for Slurm & slurmrestd
if [ "${OPEN_PORTS}" = "1" ]; then
  if command -v ufw >/dev/null 2>&1; then
    echo "[*] Opening ports with ufw..."
    sudo ufw allow 6817:6819/tcp || true   # Slurm daemons
    sudo ufw allow "${RESTD_PORT}"/tcp || true
  fi
fi

# =========================
# Hostname sanity
# =========================
echo "[*] Hostname sanity..."
if ! grep -qE "[[:space:]]${HOST_SHORT}(\s|$)" /etc/hosts; then
  echo "127.0.1.1  ${HOST_SHORT} ${HOST_FQDN}" | sudo tee -a /etc/hosts >/dev/null
fi

# =========================
# Time sync (chrony)
# =========================
echo "[*] Time sync (chrony)..."
sudo systemctl enable --now chrony

# =========================
# MUNGE setup
# =========================
echo "[*] MUNGE setup..."
sudo install -o munge -g munge -m 0700 -d /etc/munge
sudo install -o munge -g munge -m 0700 -d /var/lib/munge /var/log/munge /run/munge

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
if [ ! -f /etc/munge/munge.key ]; then
  if [ -f "$SCRIPT_DIR/create-munge-key.sh" ]; then
    sed -i 's/\r$//' "$SCRIPT_DIR/create-munge-key.sh" || true
    chmod +x "$SCRIPT_DIR/create-munge-key.sh"
    sudo bash "$SCRIPT_DIR/create-munge-key.sh"
  else
    sudo dd if=/dev/urandom of=/etc/munge/munge.key bs=1 count=1024 status=none
  fi
  sudo chown munge:munge /etc/munge/munge.key
  sudo chmod 0400 /etc/munge/munge.key
fi

sudo systemctl enable --now munge

echo "[*] Ensure munge socket permissions..."
sudo mkdir -p /run/munge
sudo chown -R munge:munge /run/munge
sudo chmod 700 /run/munge
sudo systemctl restart munge

echo "[*] MUNGE self-test..."
if ! munge -n | unmunge >/dev/null 2>&1; then
  echo "[ERROR] MUNGE self-test failed. Check /var/log/munge/munged.log" >&2
  exit 1
fi

# =========================
# Slurm directories
# =========================
echo "[*] Slurm state dirs..."
sudo mkdir -p /var/spool/slurmctld /var/spool/slurmd /var/log/slurm
sudo chown -R slurm:slurm /var/spool/slurmctld /var/spool/slurmd /var/log/slurm
sudo chmod 755 /var/spool/slurmctld /var/spool/slurmd

# Ensure slurm.conf (if already exists) references these dirs
test -f /etc/slurm/slurm.conf && grep -E '^(StateSaveLocation|SlurmUser)' /etc/slurm/slurm.conf || true

# Ensure log files exist
sudo touch /var/log/slurmctld.log /var/log/slurmd.log
sudo chown slurm:slurm /var/log/slurmctld.log /var/log/slurmd.log

# =========================
# Generate slurm.conf (controller copy)
# =========================
# --- gather nodes from CLI (space or comma separated) or $NODES env ---
NODES_CLI="$(printf '%s' "$*" | tr ' ' ',' | sed 's/^,\+//;s/,\+$//;s/,,\+/,/g')"
if [ -z "$NODES_CLI" ] && [ -n "${NODES:-}" ]; then
  NODES_CLI="$(printf '%s' "$NODES" | tr ' ' ',' | sed 's/^,\+//;s/,\+$//;s/,,\+/,/g')"
fi

# All nodes that will go into the partition
ALL_NODES="${HOST_SHORT}${NODES_CLI:+,${NODES_CLI}}"

SLURM_CONF=/etc/slurm/slurm.conf
echo "[*] Writing $SLURM_CONF ..."
sudo tee "$SLURM_CONF" >/dev/null <<EOF
ClusterName=${CLUSTER_NAME}
SlurmctldHost=${CONTROLLER_HOST}
SlurmUser=slurm
AuthType=auth/munge
$( [ "${ENABLE_CONFIGLESS}" = "1" ] && echo "SlurmctldParameters=enable_configless" )

SlurmctldLogFile=/var/log/slurmctld.log
SlurmdLogFile=/var/log/slurmd.log
SlurmctldPidFile=/run/slurmctld.pid
SlurmdPidFile=/run/slurmd.pid
StateSaveLocation=/var/spool/slurmctld
SlurmdSpoolDir=/var/spool/slurmd

SchedulerType=sched/backfill
SelectType=select/cons_tres
SelectTypeParameters=CR_CPU_Memory
ProctrackType=proctrack/linuxproc
ReturnToService=2
AccountingStorageType=accounting_storage/none
MpiDefault=none

SlurmctldPort=6817
SlurmdPort=6818
$( [ "${GPU_ENABLE}" = "1" ] && echo "GresTypes=gpu" )

# --- define the controller node explicitly ---
NodeName=${HOST_SHORT} CPUs=${CPUS} RealMemory=${MEM_MB} State=UNKNOWN
# --- define extra worker nodes passed via CLI/env (can be ranges like n[01-04]) ---
$( [ -n "$NODES_CLI" ] && echo "NodeName=${NODES_CLI} CPUs=${CPUS} RealMemory=${MEM_MB} State=UNKNOWN" )

# Partition includes controller + workers
PartitionName=${PARTITION_NAME} Nodes=${ALL_NODES} Default=YES MaxTime=INFINITE State=UP
EOF

# =========================
# JWT + slurmrestd (non-root)
# =========================
sudo usermod -aG munge slurm

# Create JWT key
sudo dd if=/dev/urandom of=/etc/slurm/jwt_hs256.key bs=32 count=1 status=none
sudo chown slurm:slurm /etc/slurm/jwt_hs256.key
sudo chmod 600 /etc/slurm/jwt_hs256.key

# Insert AuthAlt lines if missing
sudo awk '
  BEGIN{t=0;p=0}
  /^AuthAltTypes/      { $0="AuthAltTypes=auth/jwt"; t=1 }
  /^AuthAltParameters/ { $0="AuthAltParameters=jwt_key=/etc/slurm/jwt_hs256.key"; p=1 }
  {print}
  END{
    if(!t) print "AuthAltTypes=auth/jwt";
    if(!p) print "AuthAltParameters=jwt_key=/etc/slurm/jwt_hs256.key";
  }
' "$SLURM_CONF" | sudo tee /etc/slurm/slurm.conf.new >/dev/null
sudo mv /etc/slurm/slurm.conf.new /etc/slurm/slurm.conf

# Override systemd unit for slurmrestd (run as slurmrestd user with JWT)
sudo useradd --system --no-create-home slurmrestd
sudo mkdir -p /etc/systemd/system/slurmrestd.service.d
sudo tee /etc/systemd/system/slurmrestd.service.d/override.conf >/dev/null <<EOF
[Service]
User=slurmrestd
Group=slurmrestd
ExecStart=
ExecStart=/usr/sbin/slurmrestd -a rest_auth/jwt -s slurmctld, slurmdbd ${LISTEN_ADDR}:${RESTD_PORT}
UMask=0077
EOF

# =========================
# Configless slurmd setup
# =========================
echo "[*] Pointing slurmd at conf-server=${CONTROLLER_HOST} …"
if [[ -f /etc/default/slurmd ]]; then
  if grep -q '^SLURMD_OPTIONS=' /etc/default/slurmd; then
    sudo sed -i 's|^SLURMD_OPTIONS=.*|SLURMD_OPTIONS="--conf-server='"${CONTROLLER_HOST}"'"|' /etc/default/slurmd
  else
    echo 'SLURMD_OPTIONS="--conf-server='"${CONTROLLER_HOST}"'"' | sudo tee -a /etc/default/slurmd >/dev/null
  fi
else
  echo 'SLURMD_OPTIONS="--conf-server='"${CONTROLLER_HOST}"'"' | sudo tee /etc/default/slurmd >/dev/null
fi

# =========================
# Start/restart services
# =========================
echo "[*] Enable and (re)start slurm daemons..."
sudo systemctl daemon-reload || true
sudo systemctl enable slurmctld slurmd >/dev/null 2>&1 || true

sudo systemctl restart slurmctld   # controller first
sudo systemctl restart slurmd      # then node daemon
sudo scontrol reconfigure || true  # push changes
sudo systemctl enable --now slurmrestd || true

# =========================
# Smoke tests
# =========================
echo "[*] Quick smoke test..."
sinfo || echo "[warn] sinfo not ready yet"
srun -N1 -n1 hostname || echo "[warn] srun failed"

echo "[*] Attempting to mint a JWT (optional)..."
if command -v scontrol >/dev/null 2>&1; then
  TOKEN="$(scontrol token 2>/dev/null | tail -n1 | tr -d '\r\n')"
  if [ -n "${TOKEN}" ]; then
    echo "${TOKEN}" > /tmp/SLURM_JWT
    echo "[ok] JWT saved to /tmp/SLURM_JWT"
    echo "Try: curl -s -H \"Authorization: Bearer \$(cat /tmp/SLURM_JWT)\" http://localhost:${RESTD_PORT}/openapi/v0.0.40/ping | jq"
  else
    echo "[warn] 'scontrol token' produced no token. Switch slurmrestd to -a rest_auth/munge for dev."
  fi
fi

# =========================
# Verify services
# =========================
sudo systemctl --no-pager --full status munge || true
sudo systemctl --no-pager --full status slurmctld || true
sudo systemctl --no-pager --full status slurmd || true
sudo systemctl --no-pager --full status slurmrestd || true

echo
echo "[DONE] Controller ready on ${HOST_SHORT}."
echo "      - Cluster: ${CLUSTER_NAME}"
echo "      - Nodes in default partition: ${NODES}"
echo
if [ "${ENABLE_CONFIGLESS}" = "1" ]; then
  cat <<TIP
TIP: For compute nodes, copy /etc/munge/munge.key, install Slurm,
and point slurmd at this controller:
  CTRL=${CONTROLLER_HOST}
  echo "SLURMD_OPTIONS=\\"--conf-server=\$CTRL\\"" | sudo tee /etc/default/slurmd
  sudo systemctl enable --now munge
  sudo systemctl restart slurmd
Then verify from the controller:
  sinfo -N -l
  srun -w <node> -N1 -n1 hostname
TIP
fi
