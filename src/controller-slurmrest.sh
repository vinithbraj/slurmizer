#!/usr/bin/env bash
set -euo pipefail
# ============================================================
# Script purpose:
#   Install & configure slurmrestd ONLY (no slurmctld/slurmd work here).
#   - Runs as dedicated 'slurmrestd' service account
#   - Uses JWT by default and reads the SAME key as slurmctld
#   - Binds to TCP (LISTEN_ADDR:RESTD_PORT)
#
# Prereqs:
#   - /etc/slurm/slurm.conf present on this host and points to your controller
#     (at minimum: ClusterName, SlurmctldHost, AuthAltTypes, AuthAltParameters, etc.)
#   - /etc/slurm/jwt_hs256.key exists, owned root:slurm, mode 0640
#     (copy from controller if this is a separate API host)
# ============================================================

# =========================
# Tunables (override via env)
# =========================
LISTEN_ADDR="${LISTEN_ADDR:-0.0.0.0}"        # HTTP bind address
RESTD_PORT="${RESTD_PORT:-6820}"             # HTTP port
AUTH_MODE="${AUTH_MODE:-jwt}"                # jwt | munge
JWT_KEY_PATH="${JWT_KEY_PATH:-/etc/slurm/jwt_hs256.key}"  # must match controller
OPEN_PORTS="${OPEN_PORTS:-1}"                # 1=open ufw
LOG_LEVEL="${LOG_LEVEL:-info}"               # trace|debug|info|verbose|fatal

# =========================
# Helpers
# =========================
die() { echo "[x] $*" >&2; exit 1; }
need_root() { [[ $EUID -eq 0 ]] || die "Run as root or with sudo."; }

need_root

echo "[*] Installing slurmrestd..."
apt-get update -y
DEBIAN_FRONTEND=noninteractive apt-get install -y slurmrestd jq

# Create service user (no home, no shell)
if ! id -u slurmrestd >/dev/null 2>&1; then
  useradd -r -s /usr/sbin/nologin slurmrestd
fi

# Ensure /etc/slurm exists (and warn if slurm.conf missing)
mkdir -p /etc/slurm
if [ ! -f /etc/slurm/slurm.conf ]; then
  echo "[!] Warning: /etc/slurm/slurm.conf not found on this host."
  echo "    slurmrestd needs a working slurm.conf pointing at your controller."
  echo "    Copy it from the controller before starting, or API calls will fail."
fi

# =========================
# Auth wiring
# =========================
case "${AUTH_MODE}" in
  jwt)
    # Expect existing key (created on controller): root:slurm 0640
    if [ ! -f "${JWT_KEY_PATH}" ]; then
      die "Missing ${JWT_KEY_PATH}. Copy it from the controller:
  scp /etc/slurm/jwt_hs256.key <api-host>:/etc/slurm/
  chown root:slurm /etc/slurm/jwt_hs256.key
  chmod 0640 /etc/slurm/jwt_hs256.key"
    fi

    AUTH_ARG="-a rest_auth/jwt"
    # Many deployments set SLURM_JWT_KEY for rest_auth/jwt to find the key:
    EXTRA_ENV="Environment=SLURM_JWT_KEY=${JWT_KEY_PATH}"
    ;;
  munge)
    echo "[*] Using rest_auth/munge; installing MUNGE runtime..."
    DEBIAN_FRONTEND=noninteractive apt-get install -y munge libmunge2
    systemctl enable --now munge
    AUTH_ARG="-a rest_auth/munge"
    EXTRA_ENV=""
    ;;
  *)
    die "AUTH_MODE must be 'jwt' or 'munge'"
    ;;
esac

# =========================
# Systemd override
# =========================
echo "[*] Writing systemd override for slurmrestd..."
mkdir -p /etc/systemd/system/slurmrestd.service.d

cat >/etc/systemd/system/slurmrestd.service.d/override.conf <<EOF
[Service]
User=slurmrestd
Group=slurmrestd
UMask=0077
Environment=SLURMRESTD_LOGLEVEL=${LOG_LEVEL}
${EXTRA_ENV}
ExecStart=
# Bind HTTP on LISTEN_ADDR:RESTD_PORT; adjust -s if you want to restrict API sets
ExecStart=/usr/sbin/slurmrestd ${AUTH_ARG} -s slurmctld,slurmdbd ${LISTEN_ADDR}:${RESTD_PORT}
EOF

# =========================
# Firewall (optional)
# =========================
if [ "${OPEN_PORTS}" = "1" ] && command -v ufw >/dev/null 2>&1; then
  echo "[*] Opening TCP/${RESTD_PORT} via ufw..."
  ufw allow "${RESTD_PORT}"/tcp || true
fi

# =========================
# Start service
# =========================
echo "[*] Starting slurmrestd..."
systemctl daemon-reload
systemctl enable --now slurmrestd

# =========================
# Quick ping
# =========================
echo "[*] Quick ping:"
if [ "${AUTH_MODE}" = "jwt" ]; then
  if [ -f /tmp/SLURM_JWT ]; then
    TOK="$(cat /tmp/SLURM_JWT)"
    curl -sf -H "Authorization: Bearer ${TOK}" \
      "http://127.0.0.1:${RESTD_PORT}/openapi/v0.0.40/ping" | jq . || true
  else
    echo "  No /tmp/SLURM_JWT found."
    echo "  On the controller: TOKEN=\$(scontrol token); then copy it here to /tmp/SLURM_JWT and retry:"
    echo "  curl -sf -H \"Authorization: Bearer \$(cat /tmp/SLURM_JWT)\" http://127.0.0.1:${RESTD_PORT}/openapi/v0.0.40/ping | jq"
  fi
else
  curl -sf "http://127.0.0.1:${RESTD_PORT}/openapi/v0.0.40/ping" | jq . || true
fi

systemctl --no-pager --full status slurmrestd || true

echo
echo "[DONE] slurmrestd listening on ${LISTEN_ADDR}:${RESTD_PORT} (auth=${AUTH_MODE})."
echo "      Expect /etc/slurm/slurm.conf to reference your controller (SlurmctldHost=...)."
