#!/usr/bin/env bash
set -uo pipefail

# ============================================================
# ood-enable-pam.sh
# Configure OOD to authenticate via PAM → SSSD → LDAP
# Ubuntu 22.04/24.04/25.04+
# ============================================================

need_root() { [[ $EUID -eq 0 ]] || { echo "Run as root (sudo)."; exit 1; }; }
msg() { echo -e "[$(date +%H:%M:%S)] $*"; }
backup() { [[ -f "$1" ]] && cp -a "$1" "$1.bak.$(date +%Y%m%d-%H%M%S)"; }

need_root

# 0) Preconditions (OOD should already be installed)
if ! command -v /opt/ood/ood-portal-generator/sbin/update_ood_portal >/dev/null 2>&1; then
  echo "ERROR: Open OnDemand not found. Install OOD first."
  exit 1
fi

# 1) Packages
msg "Installing required packages..."
export DEBIAN_FRONTEND=noninteractive
apt-get update -y
apt-get install -y libapache2-mod-authnz-pam libpam-sss libnss-sss libpam-mkhomedir

# 2) Enable Apache PAM module
msg "Enabling Apache PAM auth module..."
a2enmod authnz_pam >/dev/null

# 3) PAM service file for OOD
msg "Writing /etc/pam.d/ood ..."
PAM_OOD="/etc/pam.d/ood"
backup "$PAM_OOD"
cat >"$PAM_OOD" <<'PAM_EOF'
# PAM stack for Open OnDemand (Apache BasicAuth via mod_authnz_pam)
auth     required pam_sss.so
account  required pam_sss.so
password required pam_sss.so
session  required pam_sss.so
# Create $HOME on first login (useful when /home is NFS)
session  required pam_mkhomedir.so skel=/etc/skel umask=0077
PAM_EOF

# 4) Ensure mkhomedir is active for noninteractive sessions too (defensive)
for f in /etc/pam.d/common-session /etc/pam.d/common-session-noninteractive; do
  if ! grep -q 'pam_mkhomedir.so' "$f"; then
    msg "Adding pam_mkhomedir to $f ..."
    sed -i '/^session\s\+required\s\+pam_unix.so/a session required pam_mkhomedir.so skel=/etc/skel umask=0077' "$f" \
      || echo 'session required pam_mkhomedir.so skel=/etc/skel umask=0077' >> "$f"
  fi
done

# 5) Switch OOD portal to PAM auth
PORTAL_YML="/etc/ood/config/ood_portal.yml"
if [[ ! -f "$PORTAL_YML" ]]; then
  msg "Creating $PORTAL_YML ..."
  mkdir -p /etc/ood/config
  touch "$PORTAL_YML"
fi
backup "$PORTAL_YML"

# Replace existing 'auth:' block with PAM lines; if no block, append one.
msg "Configuring PAM auth in $PORTAL_YML ..."
awk '
  BEGIN { inauth=0; printed=0 }
  /^auth:/ { 
    print "auth:";
    print "  - \"AuthType Basic\"";
    print "  - \"AuthName \\\"Open OnDemand\\\"\"";
    print "  - \"AuthBasicProvider PAM\"";
    print "  - \"AuthPAMService ood\"";
    print "  - \"Require valid-user\"";
    inauth=1; printed=1; next 
  }
  inauth && /^[^[:space:]-]/ { inauth=0 }           # next top-level key ends the auth block
  !inauth { print }
  END {
    if (!printed) {
      print "";
      print "auth:";
      print "  - \"AuthType Basic\"";
      print "  - \"AuthName \\\"Open OnDemand\\\"\"";
      print "  - \"AuthBasicProvider PAM\"";
      print "  - \"AuthPAMService ood\"";
      print "  - \"Require valid-user\"";
    }
  }
' "$PORTAL_YML" > "${PORTAL_YML}.new"

mv "${PORTAL_YML}.new" "$PORTAL_YML"

# 6) (Optional but recommended) ensure Apache waits for network + NFS
msg "Adding Apache systemd override to wait for remote filesystems..."
mkdir -p /etc/systemd/system/apache2.service.d
cat >/etc/systemd/system/apache2.service.d/override.conf <<'EOF'
[Unit]
Wants=network-online.target remote-fs.target
After=network-online.target remote-fs.target
EOF
systemctl daemon-reload

# 7) Regenerate OOD portal and reload Apache
msg "Regenerating OOD portal config and reloading Apache..."
/opt/ood/ood-portal-generator/sbin/update_ood_portal
systemctl reload apache2

# 8) Quick checks and hints
msg "Done. Quick verification:"
echo "  - Ensure LDAP/SSSD works locally:  getent passwd <ldap_user>  &&  id <ldap_user>"
echo "  - Ensure /home is mounted (NFS) before user login on the OOD host."
echo "  - Try logging in to OOD with an LDAP user now."
echo " create new user directory and initialize using sudo -u <username> -i , this should be automatically reflected in the share"
exit 0
