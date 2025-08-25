#!/usr/bin/env bash
set -euo pipefail

# === Tunables (default)
CLUSTER_NAME="${CLUSTER_NAME:-mini}"
PARTITION_NAME="${PARTITION_NAME:-debug}"
LISTEN_ADDR="${LISTEN_ADDR:-0.0.0.0}"        # slurmrestd bind
RESTD_PORT="${RESTD_PORT:-6820}"

# === Derived ===
HOST_SHORT="$(hostname -s)"
HOST_FQDN="$(hostname -f || echo "$HOST_SHORT")"
CPUS="$(nproc)"
# RealMemory in MB (subtract ~5% to avoid OOM on tiny VMs)
MEM_MB="$(free -m | awk '/Mem:/ {printf "%d", $2*0.95}')"

echo "[*] Installing packages..."
sudo apt-get update -y
sudo apt-get install -y \
  slurm-wlm slurmctld slurmd slurm-client slurmrestd \
  munge libmunge2 libmunge-dev jq

echo "[*] Hostname sanity..."
if ! grep -qE "[[:space:]]${HOST_SHORT}(\s|$)" /etc/hosts; then
  echo "127.0.1.1  ${HOST_SHORT} ${HOST_FQDN}" | sudo tee -a /etc/hosts >/dev/null
fi

echo "[*] munge key..."
sudo install -o munge -g munge -m 0700 -d /etc/munge
sudo install -o munge -g munge -m 0700 -d /var/lib/munge /var/log/munge /run/munge
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
if [ ! -f /etc/munge/munge.key ]; then
  sed -i 's/\r$//' "$SCRIPT_DIR/create-munge-key.sh" || true   # harmless if already LF
  chmod +x "$SCRIPT_DIR/create-munge-key.sh"
  sudo bash "$SCRIPT_DIR/create-munge-key.sh"
  sudo chown munge:munge /etc/munge/munge.key
  sudo chmod 0400 /etc/munge/munge.key
fi
sudo systemctl enable --now munge

echo "[*] Ensure munge socket permissions..."
# Ensure proper permissions for the Munge socket
sudo mkdir -p /run/munge
sudo chown -R munge:munge /run/munge
sudo chmod 700 /run/munge
sudo systemctl restart munge

# === Slurm Directories ===
echo "[*] Slurm state dirs..."
sudo mkdir -p /var/spool/slurmctld /var/spool/slurmd
sudo chown -R slurm:slurm /var/spool/slurmctld /var/spool/slurmd

# Ensure log dirs exist with correct ownership/perms
sudo touch /var/log/slurmctld.log
sudo touch /var/log/slurmd.log 
sudo chown slurm:slurm /var/log/slurmctld.log /var/log/slurmd.log

SLURM_CONF=/etc/slurm/slurm.conf
echo "[*] Writing $SLURM_CONF ..."
sudo tee "$SLURM_CONF" >/dev/null <<EOF
# --- Minimal single-host config (controller + compute on ${HOST_SHORT}) ---
ClusterName=${CLUSTER_NAME}
SlurmctldHost=${HOST_SHORT}

# Auth & logging
AuthType=auth/munge
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
SelectTypeParameters=CR_Core

# Nodes & Partitions
NodeName=${HOST_SHORT} CPUs=${CPUS} RealMemory=${MEM_MB} State=UNKNOWN
PartitionName=${PARTITION_NAME} Nodes=${HOST_SHORT} Default=YES MaxTime=INFINITE State=UP
EOF

echo "[*] Enable and start slurm daemons..."
sudo systemctl enable --now slurmctld
sudo systemctl enable --now slurmd

# === Slurmrestd (JWT) as a systemd override ===
echo "[*] Configure slurmrestd (JWT)..."
sudo mkdir -p /etc/systemd/system/slurmrestd.service.d
sudo tee /etc/systemd/system/slurmrestd.service.d/override.conf >/dev/null <<EOF
[Service]
# Use JWT auth; bind on ${LISTEN_ADDR}:${RESTD_PORT}
ExecStart=
ExecStart=/usr/sbin/slurmrestd -a rest_auth/jwt -s ${LISTEN_ADDR}:${RESTD_PORT}
EOF

sudo systemctl daemon-reload
sudo systemctl enable --now slurmrestd || true

echo "[*] Quick smoke test..."
sinfo || true
srun -N1 -n1 hostname || true

# Emit a JWT for the current UNIX user (if supported by your Slurm build)
echo "[*] Attempting to mint a JWT (optional)..."
if command -v scontrol >/dev/null 2>&1 && scontrol token >/tmp/slurm.jwt 2>/dev/null; then
  TOKEN="$(jq -r '.token // empty' /tmp/slurm.jwt || true)"
  if [ -n "${TOKEN}" ]; then
    echo "${TOKEN}" > /tmp/SLURM_JWT
    echo "[ok] JWT saved to /tmp/SLURM_JWT (Bearer token)"
    echo "Try:  curl -s -H \"Authorization: Bearer \$(cat /tmp/SLURM_JWT)\" http://localhost:${RESTD_PORT}/slurm/v0.0.38/ping | jq"
  else
    echo "[warn] 'scontrol token' ran but didn't emit JSON token (older Slurm?); you can run slurmrestd with -a rest_auth/munge for dev-only."
  fi
else
  echo "[warn] Could not mint JWT. For dev, you may run:  sudo systemctl edit slurmrestd  # and switch to rest_auth/munge"
fi

# --- Restart munge to ensure it’s running properly ---
echo "[*] Restarting Munge..."
sudo systemctl restart munge
sudo systemctl status munge

echo "[*] MUNGE self-test..."
if ! munge -n | unmunge >/dev/null 2>&1; then
  echo "[ERROR] MUNGE self-test failed. Check /var/log/munge/munged.log"; exit 1
fi

# --- Check if Slurmctld is running properly ---
echo "[*] Verifying Slurmctld status..."
sudo systemctl status slurmctld

echo "[DONE] Controller ready on ${HOST_SHORT}. slurmctld/slurmd/slurmrestd running."

