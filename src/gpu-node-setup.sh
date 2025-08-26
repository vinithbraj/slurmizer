#!/usr/bin/env bash
set -euo pipefail

# =========================
# Tunables (override via env)
# =========================
CONTROLLER_HOST="${CONTROLLER_HOST:-slurm-ctl}"  # short/FQDN or IP of controller
ENABLE_CONFIGLESS="${ENABLE_CONFIGLESS:-1}"       # 1=use --conf-server, 0=classic files
GPU_ENABLE="${GPU_ENABLE:-0}"                     # 1=detect NVIDIA GPUs with NVML
OPEN_PORTS="${OPEN_PORTS:-1}"                     # 1=open ufw port 6818 (slurmd)
NODENAME_OVERRIDE="${NODENAME_OVERRIDE:-}"        # Optional: force SlurmNodeName

# If copying munge key from controller via scp:
#   export CONTROLLER_SSH_USER=ubuntu (or leave empty to use current user)
CONTROLLER_SSH_USER="${CONTROLLER_SSH_USER:-}"

# =========================
# Derived
# =========================
HOST_SHORT="$(hostname -s)"
HOST_FQDN="$(hostname -f || echo "$HOST_SHORT")"

echo "[*] Installing packages..."
sudo apt-get update -y
sudo DEBIAN_FRONTEND=noninteractive apt-get install -y \
  slurmd slurm-client \
  munge libmunge2 libmunge-dev jq

# ---------- Hostname sanity (helps Slurm & munge) ----------
echo "[*] Ensuring /etc/hosts has this host and controller entries..."
if ! grep -qE "[[:space:]]${HOST_SHORT}(\s|$)" /etc/hosts; then
  echo "127.0.1.1 ${HOST_FQDN} ${HOST_SHORT}" | sudo tee -a /etc/hosts >/dev/null
fi
if [[ -n "${CONTROLLER_HOST}" ]] && ! grep -q "${CONTROLLER_HOST}" /etc/hosts; then
  # Safe add a placeholder if CONTROLLER_HOST is a bare name; you can edit later for IP
  echo "# Edit with correct IP if needed" | sudo tee -a /etc/hosts >/dev/null
  echo "10.0.0.1  ${CONTROLLER_HOST}" | sudo tee -a /etc/hosts >/dev/null
fi

# ---------- MUNGE setup ----------
echo "[*] Setting up MUNGE..."
if [[ ! -f /etc/munge/munge.key ]]; then
  echo "[*] No munge key found locally. Attempting to copy from controller..."
  SRC_HOST="${CONTROLLER_HOST}"
  [[ -n "${CONTROLLER_SSH_USER}" ]] && SRC_HOST="${CONTROLLER_SSH_USER}@${CONTROLLER_HOST}"

  set +e
  scp -q "${SRC_HOST}:/etc/munge/munge.key" /tmp/munge.key
  SCP_RC=$?
  set -e

  if [[ $SCP_RC -ne 0 ]]; then
    echo "[-] Could not scp /etc/munge/munge.key from ${CONTROLLER_HOST}."
    echo "    Copy it manually to this node, then re-run this script, e.g.:"
    echo "    sudo scp ${SRC_HOST}:/etc/munge/munge.key /etc/munge/munge.key"
    exit 1
  fi

  sudo install -o munge -g munge -m 0400 /tmp/munge.key /etc/munge/munge.key
  rm -f /tmp/munge.key
fi

echo "[*] Enabling and starting munge..."
sudo systemctl enable --now munge
sudo systemctl --no-pager --full status munge | sed -n '1,8p' || true

# ---------- Slurm (compute) ----------
echo "[*] Preparing slurmd configuration..."

if [[ "${ENABLE_CONFIGLESS}" == "1" ]]; then
  echo "[*] Using CONFIGLESS mode via --conf-server=${CONTROLLER_HOST} ..."
  # Create a systemd override to pass --conf-server to slurmd
  sudo mkdir -p /etc/systemd/system/slurmd.service.d
  cat <<EOF | sudo tee /etc/systemd/system/slurmd.service.d/override.conf >/dev/null
[Service]
Environment=SLURMD_OPTIONS=--conf-server=${CONTROLLER_HOST}
EOF
  sudo systemctl daemon-reload
else
  echo "[*] Classic mode: expecting /etc/slurm/slurm.conf from controller..."
  # Try to fetch slurm.conf and gres.conf (if present)
  SRC_HOST="${CONTROLLER_HOST}"
  [[ -n "${CONTROLLER_SSH_USER}" ]] && SRC_HOST="${CONTROLLER_SSH_USER}@${CONTROLLER_HOST}"
  sudo mkdir -p /etc/slurm
  set +e
  scp -q "${SRC_HOST}:/etc/slurm/slurm.conf" /tmp/slurm.conf && sudo mv /tmp/slurm.conf /etc/slurm/slurm.conf
  scp -q "${SRC_HOST}:/etc/slurm/gres.conf" /tmp/gres.conf && sudo mv /tmp/gres.conf /etc/slurm/gres.conf
  set -e
  if [[ ! -f /etc/slurm/slurm.conf ]]; then
    echo "[-] /etc/slurm/slurm.conf not present and could not be copied."
    echo "    Copy it from controller, then re-run this script."
    exit 1
  fi
fi

# ---------- Optional: GPU (gres) ----------
if [[ "${GPU_ENABLE}" == "1" ]]; then
  echo "[*] Configuring GPU GRES (AutoDetect=nvml)..."
  # NVML comes with NVIDIA drivers. We don't install drivers here (node-specific),
  # we just configure Slurm to auto-detect if drivers are present.
  sudo mkdir -p /etc/slurm
  if [[ ! -f /etc/slurm/gres.conf ]]; then
    echo "AutoDetect=nvml" | sudo tee /etc/slurm/gres.conf >/dev/null
  fi
fi

# ---------- NodeName override (optional) ----------
if [[ -n "${NODENAME_OVERRIDE}" ]]; then
  echo "[*] Setting NodeName override to ${NODENAME_OVERRIDE}"
  sudo mkdir -p /etc/systemd/system/slurmd.service.d
  cat <<EOF | sudo tee /etc/systemd/system/slurmd.service.d/nodename.conf >/dev/null
[Service]
Environment=SLURMD_OPTIONS=\$SLURMD_OPTIONS --nodename=${NODENAME_OVERRIDE}
EOF
  sudo systemctl daemon-reload
fi

# ---------- CGroup basic config (safe defaults) ----------
echo "[*] Ensuring basic cgroup config..."
sudo mkdir -p /etc/slurm
cat <<'EOF' | sudo tee /etc/slurm/cgroup.conf >/dev/null
CgroupAutomount=yes
ConstrainCores=yes
ConstrainRAMSpace=yes
ConstrainDevices=yes
# If using swap accounting and you want to constrain it, enable next line:
# ConstrainSwapSpace=yes
EOF

# ---------- Open firewall (optional) ----------
if [[ "${OPEN_PORTS}" == "1" ]]; then
  if command -v ufw >/dev/null 2>&1; then
    echo "[*] Opening slurmd port 6818 via ufw..."
    sudo ufw allow 6818/tcp || true
  else
    echo "[*] ufw not present; skipping firewall changes."
  fi
fi

# ---------- Start slurmd ----------
echo "[*] Enabling and starting slurmd..."
sudo systemctl enable --now slurmd
sleep 1
sudo systemctl --no-pager --full status slurmd | sed -n '1,12p' || true

echo
echo "[✓] Worker node setup complete."
echo "Next steps / quick checks:"
echo "  On controller:  sinfo             # see node appear"
echo "                  scontrol show nodes ${NODENAME_OVERRIDE:-$HOST_SHORT}"
echo
echo "  From any node (debug):"
echo "    srun -N1 -w ${NODENAME_OVERRIDE:-$HOST_SHORT} hostname"
echo
echo "If node stays in DRAIN/DOWN:"
echo "  - Check 'journalctl -u slurmd -e' here"
echo "  - Check 'journalctl -u slurmctld -e' on controller"
echo "  - Verify MUNGE: run 'munge -n | unmunge' locally; and cross-node 'remunge' test."
