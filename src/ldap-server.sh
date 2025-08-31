#!/usr/bin/env bash
set -uo pipefail

### ======== TUNABLES ========
LDAP_DOMAIN="${LDAP_DOMAIN:-lab.local}"          # your DNS domain
LDAP_ORG="${LDAP_ORG:-Lab}"                      # org/Company
LDAP_BASE_DN="${LDAP_BASE_DN:-dc=lab,dc=local}"  # base DN (must match LDAP_DOMAIN)
LDAP_ADMIN_PASS="${LDAP_ADMIN_PASS:-pass123}"    # admin password (cn=admin,$BASE_DN)

# Service/bind (read-only) account for clients (SSSD)
BIND_DN_CN="${BIND_DN_CN:-sssd}"
BIND_PASS="${BIND_PASS:-pass123}"

# Optional: UFW enable?
ENABLE_UFW="${ENABLE_UFW:-1}"

### ======== HELPERS ========
need_root() { [[ $EUID -eq 0 ]] || { echo "Run as root"; exit 1; }; }
msg() { echo -e "[$(date +%H:%M:%S)] $*"; }

# Find the first mdb/hdb/bdb DB DN under cn=config; wait for it to appear
find_db_dn() {
  local dn=""
  for i in {1..20}; do
    dn="$(ldapsearch -Q -LLL -Y EXTERNAL -H ldapi:/// -b cn=config \
           '(|(olcDatabase=mdb)(olcDatabase=hdb)(olcDatabase=bdb))' dn \
           | awk '/^dn: /{print $2; exit}')"
    [[ -n "$dn" ]] && { echo "$dn"; return 0; }
    sleep 0.5
  done
  return 1
}

need_root
export DEBIAN_FRONTEND=noninteractive

### ======== PACKAGES ========
msg "Installing packages..."
apt-get update -y
apt-get install -y slapd ldap-utils ufw || true

### ======== LISTENERS (NO TLS) ========
msg "Configuring /etc/default/slapd to enable ldap + ldapi only (no TLS)..."
install -d /etc/default
cat >/etc/default/slapd <<'EOF'
SLAPD_CONF=
SLAPD_PIDFILE=
SLAPD_SERVICES="ldap:/// ldapi:///"
SLAPD_SOCKS=/run/slapd
EOF

systemctl enable slapd
systemctl restart slapd
sleep 2

### ======== SANITY: cn=config reachable ========
ldapsearch -Q -LLL -Y EXTERNAL -H ldapi:/// -b cn=config dn >/dev/null \
  || { echo "ERROR: Cannot query cn=config via ldapi:/// as EXTERNAL"; exit 1; }

### ======== PREP DB PATHS (idempotent) ========
install -d -o openldap -g openldap /var/lib/ldap
install -d -o openldap -g openldap /etc/ldap/slapd.d

### ======== DETECT DB DN ========
DB_DN="$(find_db_dn)" || { echo "ERROR: Database DN not ready under cn=config"; exit 1; }
msg "Detected database entry: ${DB_DN}"

### ======== SET BASE DN / ADMIN DN & PASSWORD ========
msg "Setting database suffix, root DN, and root password..."
ADMIN_SSHA="$(slappasswd -s "$LDAP_ADMIN_PASS")"
cat >/tmp/db-init.ldif <<EOF
dn: ${DB_DN}
changetype: modify
replace: olcSuffix
olcSuffix: ${LDAP_BASE_DN}
-
replace: olcRootDN
olcRootDN: cn=admin,${LDAP_BASE_DN}
-
replace: olcRootPW
olcRootPW: ${ADMIN_SSHA}
EOF
ldapmodify -Q -Y EXTERNAL -H ldapi:/// -f /tmp/db-init.ldif

### ======== BASE ENTRIES (dc=..., OUs) ========
msg "Creating base DIT (domain + OUs)..."
cat >/tmp/base.ldif <<EOF
dn: ${LDAP_BASE_DN}
objectClass: top
objectClass: dcObject
objectClass: organization
o: ${LDAP_ORG}
dc: $(echo "$LDAP_DOMAIN" | cut -d. -f1)

dn: ou=People,${LDAP_BASE_DN}
objectClass: top
objectClass: organizationalUnit
ou: People

dn: ou=Groups,${LDAP_BASE_DN}
objectClass: top
objectClass: organizationalUnit
ou: Groups

dn: ou=System,${LDAP_BASE_DN}
objectClass: top
objectClass: organizationalUnit
ou: System
EOF
ldapadd -x -D "cn=admin,${LDAP_BASE_DN}" -w "$LDAP_ADMIN_PASS" -f /tmp/base.ldif || true

### ======== BIND (SERVICE) ACCOUNT ========
msg "Creating bind/service account..."
BIND_SSHA="$(slappasswd -s "$BIND_PASS")"
cat >/tmp/bind-user.ldif <<EOF
dn: cn=${BIND_DN_CN},ou=System,${LDAP_BASE_DN}
objectClass: simpleSecurityObject
objectClass: organizationalRole
cn: ${BIND_DN_CN}
description: SSSD bind account
userPassword: ${BIND_SSHA}
EOF
ldapadd -x -D "cn=admin,${LDAP_BASE_DN}" -w "$LDAP_ADMIN_PASS" -f /tmp/bind-user.ldif || true

### ======== ACCESS CONTROLS ========
msg "Replacing olcAccess rules (read for bind user, proper password ACLs)..."
cat >/tmp/acl-replace.ldif <<EOF
dn: ${DB_DN}
changetype: modify
replace: olcAccess
olcAccess: {0}to attrs=userPassword,shadowLastChange by self write by dn.exact="cn=${BIND_DN_CN},ou=System,${LDAP_BASE_DN}" read by anonymous auth by * none
olcAccess: {1}to dn.subtree="${LDAP_BASE_DN}" by dn.exact="cn=admin,${LDAP_BASE_DN}" write by dn.exact="cn=${BIND_DN_CN},ou=System,${LDAP_BASE_DN}" read by * read
EOF
ldapmodify -Q -Y EXTERNAL -H ldapi:/// -f /tmp/acl-replace.ldif

### ======== INDEXES (useful for logins) ========
msg "Adding common indexes..."
cat >/tmp/indexes.ldif <<EOF
dn: ${DB_DN}
changetype: modify
add: olcDbIndex
olcDbIndex: objectClass eq
olcDbIndex: uid eq
olcDbIndex: uidNumber eq
olcDbIndex: gidNumber eq
olcDbIndex: cn eq
olcDbIndex: memberUid eq
EOF
ldapmodify -Q -Y EXTERNAL -H ldapi:/// -f /tmp/indexes.ldif || true

### ======== SAMPLE GROUP & USER (OPTIONAL) ========
msg "Creating sample group/user (optional)..."
cat >/tmp/sample-group.ldif <<EOF
dn: cn=devs,ou=Groups,${LDAP_BASE_DN}
objectClass: top
objectClass: posixGroup
cn: devs
gidNumber: 10001
EOF
ldapadd -x -D "cn=admin,${LDAP_BASE_DN}" -w "$LDAP_ADMIN_PASS" -f /tmp/sample-group.ldif || true

USER_PASS_HASH="$(slappasswd -s "UserPass123!")"
cat >/tmp/sample-user.ldif <<EOF
dn: uid=vinith,ou=People,${LDAP_BASE_DN}
objectClass: inetOrgPerson
objectClass: posixAccount
objectClass: shadowAccount
cn: Vinith Raj
sn: Raj
uid: vinith
uidNumber: 20001
gidNumber: 10001
homeDirectory: /home/vinith
loginShell: /bin/bash
mail: vinith@example.com
userPassword: ${USER_PASS_HASH}
EOF
ldapadd -x -D "cn=admin,${LDAP_BASE_DN}" -w "$LDAP_ADMIN_PASS" -f /tmp/sample-user.ldif || true

### ======== FIREWALL ========
if [[ "$ENABLE_UFW" == "1" ]]; then
  msg "Configuring UFW (389 only; no 636)..."
  ufw allow 389/tcp || true
  ufw --force enable || true
fi

systemctl restart slapd
sleep 2

### ======== TEST HINTS ========
msg ""
msg "========= DONE (NO TLS) ========="
msg "Base DN:     ${LDAP_BASE_DN}"
msg "Admin DN:    cn=admin,${LDAP_BASE_DN}"
msg "Bind DN:     cn=${BIND_DN_CN},ou=System,${LDAP_BASE_DN}"
msg ""
msg "Quick tests (replace <host-or-ip> as needed):"
msg "  ss -tlnp | awk '/:389/'"
msg "  ldapsearch -H ldap://<host-or-ip> -x -b ${LDAP_BASE_DN} -LLL '(objectClass=*)'"
msg "  ldapwhoami  -H ldap://<host-or-ip> -x -D cn=admin,${LDAP_BASE_DN} -W"
msg "  ldapwhoami  -H ldap://<host-or-ip> -x -D cn=${BIND_DN_CN},ou=System,${LDAP_BASE_DN} -W"
# ldapsearch -H ldaps://<SERVER_FQDN_or_IP> \
# -x -D "cn=admin,dc=lab,dc=local" -W \
#  -b "dc=lab,dc=local" "(objectClass=*)"
