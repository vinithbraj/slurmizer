#!/usr/bin/env bash
set -euo pipefail

# =========================
# Tunables (override via env)
# =========================
CLUSTER_NAME="${CLUSTER_NAME:-mini}"

# Use socket-only MariaDB & unix_socket auth (recommended)
USE_SOCKET_AUTH="${USE_SOCKET_AUTH:-1}"      # 1=on, 0=use password auth
DB_NAME="${DB_NAME:-slurm_acct_db}"
DB_USER="${DB_USER:-slurm}"
DB_PASS="${DB_PASS:-change_me}"              # only used if USE_SOCKET_AUTH=0

# slurmdbd bind (dbd listens to slurmctld; keep on localhost)
SLURMDBD_HOST="${SLURMDBD_HOST:-localhost}"
SLURMDBD_PORT="${SLURMDBD_PORT:-6819}"

# Paths
SLURM_ETC="${SLURM_ETC:-/etc/slurm}"
SLURMDBD_CONF="${SLURMDBD_CONF:-$SLURM_ETC/slurmdbd.conf}"
SLURM_CONF="${SLURM_CONF:-$SLURM_ETC/slurm.conf}"

# Whether to patch slurm.conf to use slurmdbd
PATCH_SLURM_CONF="${PATCH_SLURM_CONF:-1}"

# =========================
# Helpers
# =========================
log()  { echo "[*] $*"; }
warn() { echo "[!] $*"; }
die()  { echo "[x] $*" >&2; exit 1; }

need_root() {
  [[ $EUID -eq 0 ]] || die "Run as root or with sudo."
}

pkg_install() {
  if command -v apt >/dev/null 2>&1; then
    apt-get update -y
    DEBIAN_FRONTEND=noninteractive apt-get install -y mariadb-server mariadb-client slurmdbd slurm-client
  else
    die "This script targets Debian/Ubuntu (apt)."
  fi
}

ensure_munge_running() {
  if ! systemctl is-active --quiet munge; then
    warn "munge is not active. Starting…"
    systemctl enable --now munge || die "Start munge and ensure /etc/munge/munge.key exists with correct perms."
  fi
}

harden_mariadb() {
  log "Hardening MariaDB for local-only socket access…"
  install -d -m 0755 /etc/mysql/mariadb.conf.d
  cat >/etc/mysql/mariadb.conf.d/60-slurm.cnf <<'EOF'
[mysqld]
# Local-only; slurmdbd talks via socket
skip-networking
bind-address=127.0.0.1
socket=/run/mysqld/mysqld.sock

# Durable InnoDB (safer for accounting data)
innodb_flush_log_at_trx_commit=1
sync_binlog=1

# Charset
character-set-server=utf8mb4
collation-server=utf8mb4_unicode_ci
EOF
  systemctl enable --now mariadb
  systemctl restart mariadb
}

mariadb_ready() { systemctl is-active --quiet mariadb; }

wait_for_mariadb() {
  log "Waiting for MariaDB…"
  for i in {1..30}; do
    if mariadb_ready && mysqladmin --protocol=socket ping &>/dev/null; then
      log "MariaDB is ready."
      return 0
    fi
    sleep 1
  done
  die "MariaDB not ready."
}

setup_db() {
  log "Creating database and user (idempotent)…"
  if [[ "$USE_SOCKET_AUTH" == "1" ]]; then
    mariadb --protocol=socket <<SQL
CREATE DATABASE IF NOT EXISTS \`$DB_NAME\` CHARACTER SET utf8mb4 COLLATE utf8mb4_unicode_ci;
CREATE USER IF NOT EXISTS '$DB_USER'@'localhost' IDENTIFIED VIA unix_socket;
GRANT ALL PRIVILEGES ON \`$DB_NAME\`.* TO '$DB_USER'@'localhost';
FLUSH PRIVILEGES;
SQL
  else
    mariadb --protocol=socket <<SQL
CREATE DATABASE IF NOT EXISTS \`$DB_NAME\` CHARACTER SET utf8mb4 COLLATE utf8mb4_unicode_ci;
CREATE USER IF NOT EXISTS '$DB_USER'@'localhost' IDENTIFIED BY '$DB_PASS';
GRANT ALL PRIVILEGES ON \`$DB_NAME\`.* TO '$DB_USER'@'localhost';
FLUSH PRIVILEGES;
SQL
  fi
}

write_slurmdbd_conf() {
  log "Writing $SLURMDBD_CONF (backup kept)…"
  install -o root -g root -m 0755 -d "$SLURM_ETC"
  [[ -f "$SLURMDBD_CONF" ]] && cp -a "$SLURMDBD_CONF" "$SLURMDBD_CONF.bak.$(date +%s)" || true

  if [[ "$USE_SOCKET_AUTH" == "1" ]]; then
    cat >"$SLURMDBD_CONF" <<EOF
# Auto-generated: socket-auth (unix_socket), no password stored.
AuthType=auth/munge
DbdHost=$SLURMDBD_HOST
DbdPort=$SLURMDBD_PORT
PidFile=/var/run/slurmdbd.pid
SlurmUser=slurm
LogFile=/var/log/slurm/slurmdbd.log
AuthAltTypes=auth/jwt
AuthAltParameters=jwt_key=/etc/slurm/jwt_hs256.key
StorageType=accounting_storage/mysql
StorageHost=localhost
StorageLoc=$DB_NAME
StorageUser=$DB_USER
StoragePass=
StoragePort=0
EOF
  else
    cat >"$SLURMDBD_CONF" <<EOF
# Auto-generated: password auth.
AuthType=auth/munge
DbdHost=$SLURMDBD_HOST
DbdPort=$SLURMDBD_PORT
PidFile=/var/run/slurmdbd.pid
SlurmUser=slurm
LogFile=/var/log/slurm/slurmdbd.log
AuthAltTypes=auth/jwt
AuthAltParameters=jwt_key=/etc/slurm/jwt_hs256.key
StorageType=accounting_storage/mysql
StorageHost=localhost
StorageLoc=$DB_NAME
StorageUser=$DB_USER
StoragePass=$DB_PASS
StoragePort=0
EOF
  fi

  chown slurm:slurm "$SLURMDBD_CONF"
  chmod 600 "$SLURMDBD_CONF"

  # Ensure log dir exists
  install -o slurm -g slurm -m 0755 -d /var/log/slurm || true
}

systemd_ordering() {
  log "Ensuring systemd ordering (mariadb -> slurmdbd)…"
  install -d -m 0755 /etc/systemd/system/slurmdbd.service.d
  cat >/etc/systemd/system/slurmdbd.service.d/override.conf <<'EOF'
[Unit]
Requires=mariadb.service
After=mariadb.service
EOF
  systemctl daemon-reload
}

start_slurmdbd() {
  log "Starting slurmdbd…"
  systemctl enable --now slurmdbd
  sleep 1
  systemctl --no-pager --full status slurmdbd || true
}

patch_slurm_conf() {
  [[ "$PATCH_SLURM_CONF" != "1" ]] && return 0
  [[ -f "$SLURM_CONF" ]] || die "Missing $SLURM_CONF. Create your base slurm.conf first."

  log "Patching $SLURM_CONF for accounting (backup kept)…"
  cp -a "$SLURM_CONF" "$SLURM_CONF.bak.$(date +%s)"

  # Accounting through slurmdbd
  grep -q '^AccountingStorageType=' "$SLURM_CONF" \
    && sed -i "s|^AccountingStorageType=.*|AccountingStorageType=accounting_storage/slurmdbd|" "$SLURM_CONF" \
    || echo "AccountingStorageType=accounting_storage/slurmdbd" >> "$SLURM_CONF"

  grep -q '^AccountingStorageHost=' "$SLURM_CONF" \
    && sed -i "s|^AccountingStorageHost=.*|AccountingStorageHost=$SLURMDBD_HOST|" "$SLURM_CONF" \
    || echo "AccountingStorageHost=$SLURMDBD_HOST" >> "$SLURM_CONF"

  grep -q '^AccountingStoragePort=' "$SLURM_CONF" \
    && sed -i "s|^AccountingStoragePort=.*|AccountingStoragePort=$SLURMDBD_PORT|" "$SLURM_CONF" \
    || echo "AccountingStoragePort=$SLURMDBD_PORT" >> "$SLURM_CONF"

  grep -q '^JobAcctGatherType=' "$SLURM_CONF" || echo "JobAcctGatherType=jobacct_gather/linux" >> "$SLURM_CONF"

  # Reload slurmctld to pick up accounting
  systemctl reload slurmctld || systemctl restart slurmctld
}

register_cluster() {
  log "Registering cluster '$CLUSTER_NAME' (safe if exists)…"
  sacctmgr -i add cluster "$CLUSTER_NAME" || true
  sacctmgr show cluster format=cluster,controlhost -Pn || true
}

verify() {
  echo
  log "Verification:"
  systemctl is-active --quiet slurmdbd && echo " - slurmdbd: ACTIVE" || echo " - slurmdbd: INACTIVE"
  echo " - Clusters in accounting:"
  sacctmgr show cluster format=cluster,controlhost -Pn || true
  echo " - Test query (may be empty if no jobs yet):"
  sacct -S now-1day --format=JobID,User,Account,Partition,Elapsed,State 2>/dev/null || true
  echo
  log "If slurmdbd fails on boot, check: journalctl -u slurmdbd -b"
}

# =========================
# Main
# =========================
need_root
ensure_munge_running
pkg_install
harden_mariadb
wait_for_mariadb
setup_db
write_slurmdbd_conf
systemd_ordering
start_slurmdbd
if [[ "$PATCH_SLURM_CONF" == "1" ]]; then patch_slurm_conf; fi
register_cluster
verify

log "Done."
