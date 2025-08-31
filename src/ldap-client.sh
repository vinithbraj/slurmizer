#!/usr/bin/env bash
set -euo pipefail

# ============================================================
# LDAP CLIENT SETUP (SSSD + PAM + mkhomedir) for Ubuntu
# ------------------------------------------------------------
# Usage (defaults shown):
#   sudo ./ldap-client-setup.sh
# or override via env:
#   LDAP_URI="ldap://192.168.11.10" LDAP_BASE_DN="dc=lab,dc=local" LDAP_DOMAIN="lab.local" \
#   LDAP_BIND_DN="cn=sssd,dc=lab,dc=local" LDAP_BIND_PASS="pass123" \
#   USE_LDAPS=0 START_TLS=0 TLS_CACERT="/etc/ssl/certs/ca-certificates.crt" \
#   TLS_REQCERT="demand" ENUMERATE=0 HOME_TMPL="/home/%u" LOGIN_SHELL="/bin/bash" \
#   sudo -E ./ldap-client-setup.sh
#
# Notes:
# - Set USE_LDAPS=1 to use ldaps:// (port 636).
# - Or set START_TLS=1 to use StartTLS over ldap:// (port 389).
# - Provide a valid CA certificate for TLS via TLS_CACERT and keep TLS_REQCERT="demand".
# - If you don't have TLS yet, leave START_TLS=0 and USE_LDAPS=0 (plain LDAP inside a trusted LAN).
# ============================================================

# --------------------------
# Tunables (env overrides)
# --------------------------
LDAP_URI="${LDAP_URI:-ldap://ldap.local.lab}"        # e.g., ldap://ip or ldaps://ip
LDAP_BASE_DN="${LDAP_BASE_DN:-dc=lab,dc=local}"
LDAP_DOMAIN="${LDAP_DOMAIN:-lab.local}"              # used by SSSD for domain naming
LDAP_BIND_DN="${LDAP_BIND_DN:-cn=admin,${LDAP_BASE_DN}}"
LDAP_BIND_PASS="${LDAP_BIND_PASS:-pass123}"

# TLS options
USE_LDAPS="${USE_LDAPS:-0}"                          # 1=use ldaps:// (port 636)
START_TLS="${START_TLS:-0}"                          # 1=use StartTLS over ldap://
TLS_CACERT="${TLS_CACERT:-/etc/ssl/certs/ca-certificates.crt}"
TLS_REQCERT="${TLS_REQCERT:-demand}"                 # demand|allow|never (prefer 'demand' with real CA)

# Other SSSD options
ENUMERATE="${ENUMERATE:-0}"                          # 0=no full listing; faster/lean
HOME_TMPL="${HOME_TMPL:-/home/%u}"
LOGIN_SHELL="${LOGIN_SHELL:-/bin/bash}"

# --------------------------
need_root() { [[ $EUID -eq 0 ]] || { echo "Run as root (use sudo)."; exit 1; }; }
msg() { echo -e "[$(date +%H:%M:%S)] $*"; }

need_root

# --------------------------
# Package install
# --------------------------
msg "Installing packages..."
export DEBIAN_FRONTEND=noninteractive
apt-get update -y
apt-get install -y sssd sssd-ldap sssd-tools libnss-sss libpam-sss nscd libpam-mkhomedir ldap-utils

# --------------------------
# NSS switch (ensure 'sss' after 'files')
# --------------------------
msg "Configuring /etc/nsswitch.conf..."
for key in passwd group shadow; do
  if grep -qE "^$key:.*\bsss\b" /etc/nsswitch.conf; then
    true
  else
    sed -i "s/^$key:.*/$key:     files sss/" /etc/nsswitch.conf
  fi
done

# --------------------------
# Build sssd.conf
# --------------------------
SSSD_CONF="/etc/sssd/sssd.conf"
msg "Writing ${SSSD_CONF}..."

# Determine ldap_uri and TLS knobs
effective_uri="$LDAP_URI"
ldap_id_use_start_tls="False"
tls_lines=""

if [[ "$USE_LDAPS" == "1" ]]; then
  # Force ldaps:// schema
  hostport="${LDAP_URI#*://}"
  hostport="${hostport%%/*}"
  host="${hostport%%:*}"
  port="${hostport#*:}"
  [[ "$host" == "$port" ]] && port="636"
  effective_uri="ldaps://${host}:${port}"
  ldap_id_use_start_tls="False"
  tls_lines="ldap_tls_reqcert = ${TLS_REQCERT}
ldap_tls_cacert = ${TLS_CACERT}"
elif [[ "$START_TLS" == "1" ]]; then
  ldap_id_use_start_tls="True"
  tls_lines="ldap_tls_reqcert = ${TLS_REQCERT}
ldap_tls_cacert = ${TLS_CACERT}"
fi

cat >"$SSSD_CONF" <<EOF
[sssd]
services = nss, pam
config_file_version = 2
domains = ${LDAP_DOMAIN}

[domain/${LDAP_DOMAIN}]
id_provider = ldap
auth_provider = ldap
chpass_provider = ldap

ldap_uri = ${effective_uri}
ldap_search_base = ${LDAP_BASE_DN}
ldap_default_bind_dn = ${LDAP_BIND_DN}
ldap_default_authtok = ${LDAP_BIND_PASS}

# TLS / StartTLS
ldap_id_use_start_tls = ${ldap_id_use_start_tls}
ldap_auth_disable_tls_never_use_in_production = True
${tls_lines}

# User attribute mappings
ldap_user_home_directory = homeDirectory
ldap_user_shell = loginShell

fallback_homedir = ${HOME_TMPL}
default_shell = ${LOGIN_SHELL}

# Cache & behavior
cache_credentials = True
enumerate = $( [[ "$ENUMERATE" == "1" ]] && echo True || echo False )

# Timeouts / robustness (reasonable defaults)
ldap_network_timeout = 3
ldap_opt_timeout = 5
ldap_connection_expire_timeout = 600
EOF

chmod 600 "$SSSD_CONF"
chown root:root "$SSSD_CONF"

# --------------------------
# PAM: auto-create home dirs on first login
# --------------------------
msg "Enabling pam_mkhomedir..."
for pamf in /etc/pam.d/common-session /etc/pam.d/common-session-noninteractive; do
  if ! grep -q 'pam_mkhomedir.so' "$pamf"; then
    sed -i '/^session\s\+required\s\+pam_unix.so/a session required pam_mkhomedir.so skel=/etc/skel umask=0077' "$pamf" \
      || echo 'session required pam_mkhomedir.so skel=/etc/skel umask=0077' >> "$pamf"
  fi
done

# --------------------------
# System services
# --------------------------
msg "Enabling and restarting services..."
systemctl enable --now sssd
systemctl restart sssd || true
systemctl enable --now nscd
systemctl restart nscd || true

# --------------------------
# Sanity tests
# --------------------------
msg "Basic sanity checks..."
# Clear SSSD cache on first run to avoid stale data
if [[ -d /var/lib/sss/db ]]; then
  find /var/lib/sss/db -maxdepth 1 -type f -name '*.ldb' | grep -q . && {
    systemctl stop sssd || true
    rm -f /var/lib/sss/db/*.ldb || true
    systemctl start sssd || true
  }
fi

# Test LDAP port reachability (best-effort)
hostport="${effective_uri#*://}"
hostport="${hostport%%/*}"
host="${hostport%%:*}"
port="${hostport#*:}"
[[ "$host" == "$port" ]] && port="$( [[ "$USE_LDAPS" == "1" ]] && echo 636 || echo 389 )"

if command -v nc >/dev/null 2>&1; then
  nc -z -w2 "$host" "$port" && msg "LDAP endpoint reachable at ${host}:${port}" || msg "WARN: Cannot reach ${host}:${port} (check network/firewall)."
fi

# Try an anonymous whoami (may fail if server disallows)
if ldapwhoami -x -H "${effective_uri}" -D "${LDAP_BIND_DN}" -w "${LDAP_BIND_PASS}" -b "${LDAP_BASE_DN}" >/dev/null 2>&1; then
  msg "Bind DN authentication (ldapwhoami) seems OK."
else
  msg "NOTE: ldapwhoami bind check failed (server policy or creds). SSSD may still work if config is correct."
fi

msg "Done."
echo
echo "Next steps:"
echo "  1) Test lookups:   getent passwd <ldap_user>    | id <ldap_user>"
echo "  2) Try a login (SSH or OOD); home dir should auto-create on first login."
echo "  3) If TLS is enabled, ensure CA is at: ${TLS_CACERT} and TLS_REQCERT=${TLS_REQCERT}."
echo
