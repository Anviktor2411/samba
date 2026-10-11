#!/bin/bash
# =====================================================================
#  wiki-ldap.sh — Wiki.js LDAP/AD autentimine otse andmebaasi
#  Käivita wiki serveris PÄRAST seda, kui Wiki.js on veebis installitud:
#      sudo bash wiki-ldap.sh
# =====================================================================
set -euo pipefail

### ---------- MUUDA VAJADUSEL ---------- ###
LDAP_URL="ldaps://dc.vahtra.local:636"
BIND_DN="CN=Administrator,CN=Users,DC=vahtra,DC=local"
BIND_PASS="Parool123!"
SEARCH_BASE="OU=Kasutajad,DC=vahtra,DC=local"
TEST_USER="martin"
COMPOSE="/opt/wikijs/docker-compose.yml"
### ------------------------------------- ###

log() { echo -e "\n\e[1;34m>> $*\e[0m"; }
die() { echo -e "\e[1;31mVIGA: $*\e[0m"; exit 1; }
[[ $EUID -eq 0 ]] || die "Käivita sudo-ga: sudo bash $0"

if docker compose version >/dev/null 2>&1; then DC="docker compose -f $COMPOSE"; else DC="docker-compose -f $COMPOSE"; fi
psql() { $DC exec -T db psql -U wikijs -d wiki -v ON_ERROR_STOP=1 "$@"; }

# 1. LDAPS test
log "Testin LDAPS ühendust DC-ga"
export DEBIAN_FRONTEND=noninteractive
command -v ldapsearch >/dev/null || { apt-get update -qq; apt-get install -y -qq ldap-utils; }
LDAPTLS_REQCERT=never ldapsearch -LLL -H "$LDAP_URL" -D "$BIND_DN" -w "$BIND_PASS" \
  -b "$SEARCH_BASE" "(sAMAccountName=$TEST_USER)" sAMAccountName mail givenName \
  || die "LDAPS ei tööta. Kas DC töötab ja parool on õige?"

# 2. Andmebaasi struktuuri kontroll
log "Kontrollin Wiki.js andmebaasi"
COLS=$(psql -tAc "SELECT string_agg(column_name, ',') FROM information_schema.columns WHERE table_name='authentication';")
for c in key strategyKey displayName order isEnabled config selfRegistration domainWhitelist autoEnrollGroups; do
  [[ ",$COLS," == *",$c,"* ]] || die "Tabelis 'authentication' puudub veerg '$c' – Wiki.js versioon erineb. Seadista veebis."
done
GUESTS=$(psql -tAc "SELECT id FROM groups WHERE name='Guests' LIMIT 1;")
[[ -n "$GUESTS" ]] || GUESTS=2

# 3. LDAP strateegia
log "Kirjutan LDAP seaded"
KEY=$(cat /proc/sys/kernel/random/uuid)
psql <<SQL
DELETE FROM authentication WHERE "strategyKey" = 'ldap';
INSERT INTO authentication
  (key, "strategyKey", "displayName", "order", "isEnabled", config,
   "selfRegistration", "domainWhitelist", "autoEnrollGroups")
VALUES (
  '$KEY', 'ldap', 'Active Directory (vahtra.local)', 1, true,
  \$J\${
    "url": "$LDAP_URL",
    "bindDn": "$BIND_DN",
    "bindCredentials": "$BIND_PASS",
    "searchBase": "$SEARCH_BASE",
    "searchFilter": "(sAMAccountName={{username}})",
    "tlsEnabled": true,
    "verifyTLSCertificate": false,
    "tlsCertPath": "",
    "mappingUID": "sAMAccountName",
    "mappingEmail": "mail",
    "mappingDisplayName": "givenName",
    "mappingPicture": "thumbnailPhoto",
    "mapGroups": false,
    "groupSearchBase": "OU=Grupid,DC=vahtra,DC=local",
    "groupSearchFilter": "(member={{dn}})",
    "groupSearchScope": "sub",
    "groupDnProperty": "dn",
    "groupNameField": "name"
  }\$J\$,
  true,
  '{"v":[]}',
  '{"v":[$GUESTS]}'
);
SQL

# 4. Taaskäivitus
log "Taaskäivitan Wiki.js"
$DC restart wiki
for i in $(seq 1 24); do
  curl -s -o /dev/null -w '%{http_code}' http://localhost | grep -qE '200|302' && break
  sleep 5
done

log "KONTROLL"
psql -c 'SELECT "displayName", "strategyKey", "isEnabled", "selfRegistration" FROM authentication ORDER BY "order";'
curl -s -o /dev/null -w 'http://localhost -> %{http_code}\n' http://localhost || true

log "VALMIS. Logi sisse: http://wiki.vahtra.local/login → 'Active Directory (vahtra.local)' → $TEST_USER"
