#!/usr/bin/env bash
set -euo pipefail

# If this is a separate VM, ensure you copy /etc/munge/munge.key from the controller first.
# On a single-VM test, just run this after controller-setup.sh.

SLURM_CONF=/etc/slurm/slurm.conf
GRES_CONF=/etc/slurm/gres.conf
HOST_SHORT="$(hostname -s)"

echo "[*] Installing node bits..."
sudo apt-get update -y
sudo apt-get install -y slurmd munge

echo "[*] Ensure munge is running..."
sudo systemctl enable --now munge

echo "[*] Detect GPUs..."
GPU_CNT=0
if command -v nvidia-smi >/dev/null 2>&1; then
  GPU_CNT="$(nvidia-smi --query-gpu=name --format=csv,noheader 2>/dev/null | wc -l | tr -d ' ')"
fi
echo "Detected GPUs: ${GPU_CNT}"

echo "[*] Ensure GRES types and NodeName Gres are present in slurm.conf..."
# 1) Add/replace GresTypes=gpu (idempotent)
if grep -q "^GresTypes=" "$SLURM_CONF"; then
  sudo sed -i 's/^GresTypes=.*/GresTypes=gpu/' "$SLURM_CONF"
else
  echo "GresTypes=gpu" | sudo tee -a "$SLURM_CONF" >/dev/null
fi

# 2) Add/patch NodeName line to include Gres=gpu:X (only for this host)
if grep -q "^NodeName=${HOST_SHORT} " "$SLURM_CONF"; then
  # If a NodeName exists, ensure it contains a Gres=... entry matching GPU_CNT (or 0 if none)
  if grep -q "^NodeName=${HOST_SHORT} .*Gres=" "$SLURM_CONF"; then
    sudo sed -i "s/^NodeName=${HOST_SHORT} .*Gres=[^ ]*/NodeName=${HOST_SHORT} Gres=gpu:${GPU_CNT}/" "$SLURM_CONF"
  else
    sudo sed -i "s/^NodeName=${HOST_SHORT} .*/& Gres=gpu:${GPU_CNT}/" "$SLURM_CONF"
  fi
else
  # No NodeName yet (unlikely on single-VM); create a minimal one
  CPUS="$(nproc)"; MEM_MB="$(free -m | awk '/Mem:/ {printf "%d", $2*0.95}')"
  echo "NodeName=${HOST_SHORT} CPUs=${CPUS} RealMemory=${MEM_MB} Gres=gpu:${GPU_CNT} State=UNKNOWN" | sudo tee -a "$SLURM_CONF" >/dev/null
fi

echo "[*] Write ${GRES_CONF}..."
sudo mkdir -p /etc/slurm
if command -v nvidia-smi >/dev/null 2>&1 && [ "$GPU_CNT" -gt 0 ]; then
  # Prefer NVML autodetect when available
  sudo tee "$GRES_CONF" >/dev/null <<EOF
# Autodetect NVIDIA GPUs via NVML
AutoDetect=nvml
EOF
else
  # Fallback: static example (kept harmless when no GPUs)
  sudo tee "$GRES_CONF" >/dev/null <<'EOF'
# No NVML detected. Example static entries (commented):
# NodeName=DEFAULT Name=gpu File=/dev/nvidia0
EOF
fi

echo "[*] Restart slurmd..."
sudo systemctl enable --now slurmd
sudo systemctl restart slurmd

echo "[*] Show cluster view..."
sinfo || true
scontrol show node "${HOST_SHORT}" || true

if command -v nvidia-smi >/dev/null 2>&1; then
  echo "[*] nvidia-smi:"
  nvidia-smi || true
else
  echo "[warn] nvidia-smi not found. Install NVIDIA drivers to make GPUs usable by Slurm."
fi

echo "[DONE] GPU node setup complete on ${HOST_SHORT}."
