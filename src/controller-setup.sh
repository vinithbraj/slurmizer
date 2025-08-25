#!/usr/bin/env bash
set -euo pipefail

# =========================
# Tunables (override via env)
# =========================
CLUSTER_NAME="${CLUSTER_NAME:-mini}"
PARTITION_NAME="${PARTITION_NAME:-debug}"

# Nodes to include in the default partition (range ok: n[01-04])
# Default: just this host (keeps single-node working out of the box)
NODES="${NODES:-$(hostname -s)}"

# Configless lets compute nodes fetch config from controller (recommended)
ENABLE_CONFIGLESS="${ENABLE_CONFIGLESS:-1}"       # 1=on, 0=off

# Controller hostname/FQDN used by --conf-server (short is fine if resolvable)
CONTROLLER_HOST="${CONTROLLER_HOST:-$(hostname -f || hostname -s)}"

# GPU support (optional). If 1, we'll add GresTypes=gpu in slurm.conf.
GPU_ENABLE="${GPU_ENABLE:-0}"

# slurmrestd bind
LISTEN_ADDR="${LISTEN_ADDR:-0.0.0.0}"
RESTD_PORT="${RESTD_PORT:-6820}"

# Open firewall ports with ufw (set 1 to allow; harmless if ufw not present)
OPEN_PORTS="${OPEN_PORTS:-1}"

# =========================
# Derived
# =========================
HOST_SHORT="$(hostname -s)"
HOST_FQDN="$(hostname -f || echo "$HOST_SHORT")"
CPUS="$(nproc)"
# RealMemory in MB (subtract ~5% to avoid OOM on tiny VMs)
MEM_MB="$(free -m | awk '/Mem:/ {printf "%d", $2*0.95}')"
echo "CPUS=$CPUS MEM_MB=$MEM_MB"

echo "[*] Installing packages..."
sudo apt-get update -y
sudo apt-get install -y \
  slurm-wlm slurmctld slurmd slurm-client slurmrestd \
  munge libmunge2 libmunge-dev jq chrony libpmix2 libpmix-dev binutils

# (Optional) Open firewall ports for slurm + slurmrestd
if [ "${OPEN_PORTS}" = "1" ]; then
  if command -v ufw >/dev/null 2>&1; then
    echo "[*] Opening ports with ufw..."
    sudo ufw allow 6817:6819/tcp || true  # slurmctld/slurmd/slurmdbd
    sudo ufw allow "${RESTD_PORT}"/tcp || true
  fi
fi

echo "[*] Hostname sanity..."
if ! grep -qE "[[:space:]]${HOST_SHORT}(\s|$)" /etc/hosts; then
  echo "127.0.1.1  ${HOST_SHORT} ${HOST_FQDN}" | sudo tee -a /etc/hosts >/dev/null
fi

echo "[*] Time sync (chrony)..."
sudo systemctl enable --now chrony

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

# === Slurm Directories ===
echo "[*] Slurm state dirs..."
sudo mkdir -p /var/spool/slurmctld /var/spool/slurmd /var/log/slurm
sudo chown -R slurm:slurm /var/spool/slurmctld /var/spool/slurmd /var/log/slurm
sudo chmod 755 /var/spool/slurmctld /var/spool/slurmd

# confirm slurm.conf points here (first-run safe)
test -f /etc/slurm/slurm.conf && grep -E '^(StateSaveLocation|SlurmUser)' /etc/slurm/slurm.conf || true

# Ensure log files exist with correct ownership/perms
sudo touch /var/log/slurmctld.log /var/log/slurmd.log
sudo chown slurm:slurm /var/log/slurmctld.log /var/log/slurmd.log

# =========================
# slurm.conf (controller copy)
# =========================
SLURM_CONF=/etc/slurm/slurm.conf
echo "[*] Writing $SLURM_CONF ..."
sudo tee "$SLURM_CONF" >/dev/null <<EOF
# --- Cluster config (controller: ${CONTROLLER_HOST}) ---
ClusterName=${CLUSTER_NAME}
SlurmctldHost=${CONTROLLER_HOST}
SlurmUser=slurm
AuthType=auth/munge
$( [ "${ENABLE_CONFIGLESS}" = "1" ] && echo "SlurmctldParameters=enable_configless" )

# Logging
SlurmctldLogFile=/var/log/slurmctld.log
SlurmdLogFile=/var/log/slurmd.log

# Runtime/State
SlurmctldPidFile=/run/slurmctld.pid
SlurmdPidFile=/run/slurmd.pid
StateSaveLocation=/var/spool/slurmctld
SlurmdSpoolDir=/var/spool/slurmd

# Scheduling
SchedulerType=sched/backfill
SelectType=select/cons_tres
# Use CPU+Memory scheduling (friendlier on mixed nodes)
SelectTypeParameters=CR_CPU_Memory
ProctrackType=proctrack/linuxproc
ReturnToService=2
AccountingStorageType=accounting_storage/none
MpiDefault=none

# Communication ports (default documented)
SlurmctldPort=6817
SlurmdPort=6818

# Optional GPU support
$( [ "${GPU_ENABLE}" = "1" ] && echo "GresTypes=gpu" )

# Nodes & Partitions
# Let nodes register and report their resources; keep first state UNKNOWN
NodeName=${HOST_SHORT} CPUs=${CPUS} RealMemory=${MEM_MB} State=UNKNOWN
PartitionName=${PARTITION_NAME} Nodes=${NODES} Default=YES MaxTime=INFINITE State=UP
EOF

# =========================
# JWT + non-root slurmrestd
# =========================
# 4a) Make sure slurm can talk to munge
sudo usermod -aG munge slurm

# 4b) Create a JWT signing key for Slurm and lock it down
sudo dd if=/dev/urandom of=/etc/slurm/jwt_hs256.key bs=32 count=1 status=none
sudo chown slurm:slurm /etc/slurm/jwt_hs256.key
sudo chmod 600 /etc/slurm/jwt_hs256.key

# 4c) Enable JWT in slurm.conf (controller side)
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

# 4d) Run slurmrestd as the slurm user via drop-in
echo "[*] Configure slurmrestd (JWT, non-root)..."
sudo mkdir -p /etc/systemd/system/slurmrestd.service.d
sudo tee /etc/systemd/system/slurmrestd.service.d/override.conf >/dev/null <<EOF
[Service]
User=slurm
Group=slurm
ExecStart=
ExecStart=/usr/sbin/slurmrestd -a rest_auth/jwt -s slurmctld ${LISTEN_ADDR}:${RESTD_PORT}
UMask=0077
EOF

# =========================
# Point slurmd at the controller (configless fetch)
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
# Start/Restart Slurm daemons (order matters)
# =========================
echo "[*] Enable and (re)start slurm daemons..."
sudo systemctl daemon-reload || true
sudo systemctl enable slurmctld slurmd >/dev/null 2>&1 || true

# Controller first (serves config)
sudo systemctl restart slurmctld
# Then node daemon (fetches config from controller)
sudo systemctl restart slurmd
# Push any pending changes
sudo scontrol reconfigure || true

# Start slurmrestd
sudo systemctl enable --now slurmrestd || true

# =========================
# Smoke tests
# =========================
echo "[*] Quick smoke test..."
sinfo || echo "[warn] sinfo not ready yet (first boot may take a few seconds)"
srun -N1 -n1 hostname || echo "[warn] srun failed (often fine on first boot)"

# Emit a JWT for the current UNIX user (if supported by your Slurm build)
echo "[*] Attempting to mint a JWT (optional)..."
if command -v scontrol >/dev/null 2>&1; then
  TOKEN="$(scontrol token 2>/dev/null | tail -n1 | tr -d '\r\n')"
  if [ -n "${TOKEN}" ]; then
    echo "${TOKEN}" > /tmp/SLURM_JWT
    echo "[ok] JWT saved to /tmp/SLURM_JWT (Bearer token)"
    echo "Try: curl -s -H \"Authorization: Bearer \$(cat /tmp/SLURM_JWT)\" http://localhost:${RESTD_PORT}/openapi/v0.0.40/ping | jq"
  else
    echo "[warn] 'scontrol token' did not emit a token. For dev, you can switch slurmrestd to: -a rest_auth/munge"
  fi
else
  echo "[warn] Could not mint JWT. For dev, you may run:  sudo systemctl edit slurmrestd  # and set -a rest_auth/munge"
fi

echo "[*] Verifying services..."
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
TIP: For additional compute nodes (not this controller), copy /etc/munge/munge.key,
install the same Slurm packages, and point slurmd at this controller:
  CTRL=${CONTROLLER_HOST}
  echo "SLURMD_OPTIONS=\\"--conf-server=\$CTRL\\"" | sudo tee /etc/default/slurmd
  sudo systemctl enable --now munge
  sudo systemctl restart slurmd
Then verify from the controller:
  sinfo -N -l
  srun -w <node> -N1 -n1 hostname
TIP
fi
