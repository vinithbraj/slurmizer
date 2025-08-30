#!/usr/bin/env bash
set -euo pipefail
# ============================================================
# Script purpose:
#   Provision a Slurm controller node with configless support.
#   Installs slurmctld/slurmd, sets up MUNGE, generates slurm.conf,
#   and enables JWT in slurm.conf for scontrol token.
#   (NO slurmrestd parts in this script)
# ============================================================

# =========================
# Tunables (override via env)
# =========================
CLUSTER_NAME="${CLUSTER_NAME:-mini}"         # cluster name
PARTITION_NAME="${PARTITION_NAME:-debug}"    # default partition
NODES="${NODES:-$(hostname -s)}"             # extra nodes (range ok)
ENABLE_CONFIGLESS="${ENABLE_CONFIGLESS:-1}"  # 1=yes
CONTROLLER_HOST="${CONTROLLER_HOST:-$(hostname -f || hostname -s)}"
GPU_ENABLE="${GPU_ENABLE:-0}"
OPEN_PORTS="${OPEN_PORTS:-1}"                # open slurm ports (6817-6819)

# =========================
# Derived values
# =========================
HOST_SHORT="$(hostname -s)"
HOST_FQDN="$(hostname -f || echo "$HOST_SHORT")"
CPUS="$(nproc)"
MEM_MB="$(free -m | awk '/Mem:/ {printf "%d", $2*0.95}')"
echo "CPUS=$CPUS MEM_MB=$MEM_MB"

# =========================
# Helpers
# =========================
log()  { echo "[*] $*"; }
warn() { echo "[!] $*"; }
die()  { echo "[x] $*" >&2; exit 1; }
need_root() { [[ $EUID -eq 0 ]] || die "Run as root or with sudo."; }

need_root

# =========================
# Packages
# =========================
log "Installing packages..."
apt-get update -y
apt-get install -y \
  slurm-wlm slurmctld slurmd slurm-client \
  munge libmunge2 libmunge-dev jq chrony libpmix2 libpmix-dev binutils

# (Optional) open firewall ports for Slurm only
if [ "${OPEN_PORTS}" = "1" ] && command -v ufw >/dev/null 2>&1; then
  log "Opening Slurm ports with ufw..."
  ufw allow 6817:6819/tcp || true
fi

# =========================
# Hostname sanity
# =========================
log "Hostname sanity..."
if ! grep -qE "[[:space:]]${HOST_SHORT}(\s|$)" /etc/hosts; then
  echo "127.0.1.1  ${HOST_SHORT} ${HOST_FQDN}" | tee -a /etc/hosts >/dev/null
fi

# =========================
# Time sync
# =========================
log "Enabling chrony..."
systemctl enable --now chrony

# =========================
# MUNGE setup
# =========================
log "MUNGE setup..."
install -o munge -g munge -m 0700 -d /etc/munge
install -o munge -g munge -m 0700 -d /var/lib/munge /var/log/munge /run/munge

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
if [ ! -f /etc/munge/munge.key ]; then
  if [ -f "$SCRIPT_DIR/create-munge-key.sh" ]; then
    sed -i 's/\r$//' "$SCRIPT_DIR/create-munge-key.sh" || true
    chmod +x "$SCRIPT_DIR/create-munge-key.sh"
    bash "$SCRIPT_DIR/create-munge-key.sh"
  else
    dd if=/dev/urandom of=/etc/munge/munge.key bs=1 count=1024 status=none
  fi
  chown munge:munge /etc/munge/munge.key
  chmod 0400 /etc/munge/munge.key
fi

systemctl enable --now munge
mkdir -p /run/munge && chown -R munge:munge /run/munge && chmod 700 /run/munge
systemctl restart munge

log "MUNGE self-test..."
if ! munge -n | unmunge >/dev/null 2>&1; then
  die "MUNGE self-test failed. Check /var/log/munge/munged.log"
fi

# =========================
# Slurm directories
# =========================
log "Creating Slurm state/log dirs..."
mkdir -p /var/spool/slurmctld /var/spool/slurmd /var/log/slurm
chown -R slurm:slurm /var/spool/slurmctld /var/spool/slurmd /var/log/slurm
chmod 755 /var/spool/slurmctld /var/spool/slurmd
: > /var/log/slurmctld.log && chown slurm:slurm /var/log/slurmctld.log
: > /var/log/slurmd.log   && chown slurm:slurm /var/log/slurmd.log

# =========================
# Generate slurm.conf
# =========================
# gather nodes from CLI or $NODES
NODES_CLI="$(printf '%s' "${*:-}" | tr ' ' ',' | sed 's/^,\+//;s/,\+$//;s/,,\+/,/g')"
if [ -z "$NODES_CLI" ] && [ -n "${NODES:-}" ]; then
  NODES_CLI="$(printf '%s' "$NODES" | tr ' ' ',' | sed 's/^,\+//;s/,\+$//;s/,,\+/,/g')"
fi
ALL_NODES="${HOST_SHORT}${NODES_CLI:+,${NODES_CLI}}"

SLURM_CONF=/etc/slurm/slurm.conf
log "Writing $SLURM_CONF ..."
tee "$SLURM_CONF" >/dev/null <<EOF
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

NodeName=${HOST_SHORT} CPUs=${CPUS} RealMemory=${MEM_MB} State=UNKNOWN
$( [ -n "$NODES_CLI" ] && echo "NodeName=${NODES_CLI} CPUs=${CPUS} RealMemory=${MEM_MB} State=UNKNOWN" )

PartitionName=${PARTITION_NAME} Nodes=${ALL_NODES} Default=YES MaxTime=INFINITE State=UP
EOF

# =========================
# JWT (for scontrol token only)
# =========================
# Create a JWT key and enable AuthAlt* in slurm.conf.
sudo dd if=/dev/urandom of=/etc/slurm/jwt_hs256.key bs=32 count=1 status=none
sudo chown slurm:slurm /etc/slurm/jwt_hs256.key
sudo chmod 600 /etc/slurm/jwt_hs256.key


# Ensure AuthAlt lines exist
awk '
  BEGIN{t=0;p=0}
  /^AuthAltTypes/      { $0="AuthAltTypes=auth/jwt"; t=1 }
  /^AuthAltParameters/ { $0="AuthAltParameters=jwt_key=/etc/slurm/jwt_hs256.key"; p=1 }
  {print}
  END{
    if(!t) print "AuthAltTypes=auth/jwt";
    if(!p) print "AuthAltParameters=jwt_key=/etc/slurm/jwt_hs256.key";
  }
' /etc/slurm/slurm.conf > /etc/slurm/slurm.conf.new && mv /etc/slurm/slurm.conf.new /etc/slurm/slurm.conf

# =========================
# Configless slurmd setup
# =========================
log "Pointing slurmd at conf-server=${CONTROLLER_HOST} …"
if [[ -f /etc/default/slurmd ]]; then
  if grep -q '^SLURMD_OPTIONS=' /etc/default/slurmd; then
    sed -i 's|^SLURMD_OPTIONS=.*|SLURMD_OPTIONS="--conf-server='"${CONTROLLER_HOST}"'"|' /etc/default/slurmd
  else
    echo 'SLURMD_OPTIONS="--conf-server='"${CONTROLLER_HOST}"'"' >> /etc/default/slurmd
  fi
else
  echo 'SLURMD_OPTIONS="--conf-server='"${CONTROLLER_HOST}"'"' > /etc/default/slurmd
fi

# =========================
# Start/restart services
# =========================
log "Enable and start slurm daemons..."
systemctl daemon-reload || true
systemctl enable slurmctld slurmd >/dev/null 2>&1 || true
systemctl restart slurmctld
systemctl restart slurmd
scontrol reconfigure || true

# =========================
# Smoke tests
# =========================
log "Smoke test..."
sinfo || warn "sinfo not ready yet"
srun -N1 -n1 hostname || warn "srun failed"

log "Attempting to mint a JWT (optional)..."
if command -v scontrol >/dev/null 2>&1; then
  TOKEN="$(scontrol token 2>/dev/null | tail -n1 | tr -d '\r\n')"
  if [ -n "${TOKEN}" ]; then
    echo "${TOKEN}" > /tmp/SLURM_JWT
    log "JWT saved to /tmp/SLURM_JWT"
  else
    warn "'scontrol token' produced no token (check AuthAlt* in slurm.conf)."
  fi
fi

# =========================
# Verify services
# =========================
systemctl --no-pager --full status munge || true
systemctl --no-pager --full status slurmctld || true
systemctl --no-pager --full status slurmd || true

echo
echo "[DONE] Controller ready on ${HOST_SHORT}."
echo "      - Cluster: ${CLUSTER_NAME}"
echo "      - Nodes in default partition: ${NODES}"
echo
if [ "${ENABLE_CONFIGLESS}" = "1" ]; then
  cat <<'TIP'
TIP: For compute nodes, copy /etc/munge/munge.key, install Slurm,
and point slurmd at this controller:
  CTRL=<controller-fqdn-or-ip>
  echo "SLURMD_OPTIONS=\"--conf-server=$CTRL\"" | sudo tee /etc/default/slurmd
  sudo systemctl enable --now munge
  sudo systemctl restart slurmd
Then verify from the controller:
  sinfo -N -l
  srun -w <node> -N1 -n1 hostname
TIP
fi
