#!/usr/bin/env bash
# add-ldap-user.sh
# Create (if missing) ou=People & ou=Groups, then add:
#   - group: cn=<user>,ou=Groups,<BASE_DN>
#   - user : uid=<user>,ou=People,<BASE_DN>  (posixAccount, inetOrgPerson)
#
# Usage:
#   sudo ./add-ldap-user.sh <username> <password> [Full Name]
#
# Tunables (override via env):
#   BASE_DN="dc=lab,dc=local"
#   ADMIN_DN="cn=admin,dc=lab,dc=local"
#   ADMIN_PASS="pass123"
#   LDAP_URI="ldapi:///"            # local socket; avoids TLS on localhost
#   UID_MIN=10000                   # starting uidNumber if none exist yet
#   GID_MIN=10000                   # starting gidNumber if none exist yet

set -euo pipefail

# ===== Tunables =====
BASE_DN="${BASE_DN:-dc=lab,dc=local}"
ADMIN_DN="${ADMIN_DN:-cn=admin,${BASE_DN}}"
ADMIN_PASS="${ADMIN_PASS:-pass123}"
LDAP_URI="${LDAP_URI:-ldapi:///}"
UID_MIN="${UID_MIN:-10000}"
GID_MIN="${GID_MIN:-10000}"

PEOPLE_OU="ou=People,${BASE_DN}"
GROUPS_OU="ou=Groups,${BASE_DN}"

# ===== Helpers =====
die() { echo "ERROR: $*" >&2; exit 1; }
need() { command -v "$1" >/dev/null 2>&1 || die "Missing dependency: $1"; }
ld() { ldapsearch -LLL -H "$LDAP_URI" -x -D "$ADMIN_DN" -w "$ADMIN_PASS" "$@"; }
lda() { ldapadd    -H "$LDAP_URI" -x -D "$ADMIN_DN" -w "$ADMIN_PASS" "$@"; }
ldm() { ldapmodify -H "$LDAP_URI" -x -D "$ADMIN_DN" -w "$ADMIN_PASS" "$@"; }

# ===== Preflight =====
need ldapsearch
need ldapadd
need ldapmodify
need slappasswd
[[ $EUID -eq 0 ]] || die "Run as root (needed for local ldapi access & optional home dir creation)."

[[ $# -ge 2 ]] || die "Usage: $0 <username> <password> [Full Name]"
USER_NAME="$1"
USER_PASS="$2"
USER_CN="${3:-$1}"

# Sanity checks
[[ "$USER_NAME" =~ ^[a-z_][a-z0-9_-]*$ ]] || die "Username '$USER_NAME' is not a safe POSIX name."

# ===== Ensure base OUs exist =====
if ! ld -b "$PEOPLE_OU" -s base dn | grep -q "^dn: $PEOPLE_OU$"; then
  cat <<EOF | lda -f /dev/stdin
dn: $PEOPLE_OU
objectClass: organizationalUnit
ou: People
EOF
  echo "[*] Created $PEOPLE_OU"
fi

if ! ld -b "$GROUPS_OU" -s base dn | grep -q "^dn: $GROUPS_OU$"; then
  cat <<EOF | lda -f /dev/stdin
dn: $GROUPS_OU
objectClass: organizationalUnit
ou: Groups
EOF
  echo "[*] Created $GROUPS_OU"
fi

# ===== Compute next uidNumber/gidNumber =====
next_num() {
  local base="$1" attr="$2" minval="$3"
  local max
  max="$(ld -b "$base" "($attr=*)" "$attr" | awk "/^$attr:/{print \$2}" | sort -n | tail -1 || true)"
  if [[ -z "$max" ]]; then echo "$minval"; else echo $((max + 1)); fi
}

UID_NUM="$(next_num "$PEOPLE_OU" uidNumber "$UID_MIN")"
GID_NUM="$(next_num "$GROUPS_OU" gidNumber "$GID_MIN")"

USER_DN="uid=${USER_NAME},${PEOPLE_OU}"
GROUP_DN="cn=${USER_NAME},${GROUPS_OU}"

# ===== Create primary group (if missing) =====
if ld -b "$GROUPS_OU" "(cn=${USER_NAME})" cn | grep -q "^cn: ${USER_NAME}$"; then
  # If it exists, reuse its gidNumber (don’t assume ours)
  GID_NUM="$(ld -b "$GROUPS_OU" "(cn=${USER_NAME})" gidNumber | awk '/^gidNumber:/{print $2}' | head -1 || echo "$GID_NUM")"
  echo "[*] Group ${USER_NAME} already exists (gidNumber=$GID_NUM)"
else
  cat <<EOF | lda -f /dev/stdin
dn: $GROUP_DN
objectClass: top
objectClass: posixGroup
cn: $USER_NAME
gidNumber: $GID_NUM
EOF
  echo "[*] Created group ${USER_NAME} (gidNumber=$GID_NUM)"
fi

# ===== Hash the password (SSHA) =====
SSHA_PASS="$(slappasswd -s "$USER_PASS")"

# ===== Create user entry =====
if ld -b "$PEOPLE_OU" "(uid=${USER_NAME})" uid | grep -q "^uid: ${USER_NAME}$"; then
  die "User '${USER_NAME}' already exists in LDAP."
fi

HOME_DIR="/home/${USER_NAME}"
SHELL="/bin/bash"

cat <<EOF | lda -f /dev/stdin
dn: $USER_DN
objectClass: top
objectClass: person
objectClass: organizationalPerson
objectClass: inetOrgPerson
objectClass: posixAccount
cn: $USER_CN
sn: $USER_NAME
uid: $USER_NAME
uidNumber: $UID_NUM
gidNumber: $GID_NUM
homeDirectory: $HOME_DIR
loginShell: $SHELL
userPassword: $SSHA_PASS
mail: ${USER_NAME}@example.com
gecos: $USER_CN
EOF

echo "[*] Created user ${USER_NAME} (uidNumber=$UID_NUM, gidNumber=$GID_NUM)"

# ===== Add user to the group (memberUid) =====
# (safe to run even if already present)
cat <<EOF | ldm -f /dev/stdin
dn: $GROUP_DN
changetype: modify
add: memberUid
memberUid: $USER_NAME
EOF

echo "[✓] LDAP user '${USER_NAME}' added successfully."

# ===== (Optional) Create local home dir prototype (commented out) =====
if ! id -u "$USER_NAME" >/dev/null 2>&1; then
   useradd --no-create-home --uid "$UID_NUM" --gid "$GID_NUM" --shell "$SHELL" "$USER_NAME" || true
fi
mkdir -p "$HOME_DIR"
chown "$UID_NUM:$GID_NUM" "$HOME_DIR"
chmod 700 "$HOME_DIR"
echo "[*] Local home created at $HOME_DIR (ownership ${UID_NUM}:${GID_NUM})"