#!/bin/bash
# =====================================================================
#  chat-setup.sh — Rocket.Chat + MongoDB (Docker) + AD/LDAP, 2FA väljas
#  Ubuntu Server 22.04 / 24.04, VÄRSKE VM, vnet508 küljes (DHCP).
#  NB! Proxmoxis peab VM-i CPU type olema "host" (MongoDB vajab AVX-i).
#  Käivita Proxmoxi konsoolis:  sudo bash chat-setup.sh
#  Pärast: http://chat.vahtra.local  (ilma pordita)
# =====================================================================
set -euo pipefail

### ---------- MUUDA VAJADUSEL ---------- ###
HOST_SHORT="chat"
DOMAIN="vahtra.local"
IP="10.11.12.6"
PREFIX="24"
GATEWAY="10.11.12.1"
DC_IP="10.11.12.2"
RC_RELEASE="7.5.0"
MONGO_IMAGE="mongo:6.0"
RC_ADMIN="rcadmin"
RC_ADMIN_PASS="Parool123!"
BIND_DN="CN=Administrator,CN=Users,DC=vahtra,DC=local"
BIND_PASS="Parool123!"
SEARCH_BASE="OU=Kasutajad,DC=vahtra,DC=local"
### ------------------------------------- ###

log() { echo -e "\n\e[1;34m>> $*\e[0m"; }
die() { echo -e "\e[1;31mVIGA: $*\e[0m"; exit 1; }
[[ $EUID -eq 0 ]] || die "Käivita sudo-ga: sudo bash $0"

# 0. AVX kontroll (MongoDB 5+ ei käivitu ilma)
grep -qw avx /proc/cpuinfo || die "CPU-l puudub AVX. Proxmoxis: VM → Hardware → Processors → Type = host, siis Stop/Start."

IFACE=$(ip -o -4 route show to default | awk '{print $5; exit}')
[[ -n "$IFACE" ]] || IFACE=$(ip -o link show | awk -F': ' '$2!="lo"{print $2; exit}')
log "Võrgukaart: $IFACE"

# 1. Installeri jäägid + DNS
log "Parandan apt-i ja DNS-i"
sed -i '/cdrom/d' /etc/apt/sources.list 2>/dev/null || true
dpkg --configure -a || true
systemctl disable --now systemd-resolved 2>/dev/null || true
rm -f /etc/resolv.conf
printf "nameserver %s\nsearch %s\n" "$DC_IP" "$DOMAIN" > /etc/resolv.conf

# 2. Docker
log "Paigaldan Dockeri"
export DEBIAN_FRONTEND=noninteractive
apt-get update
apt-get install -y docker.io bind9-dnsutils ldap-utils curl
apt-get install -y docker-compose-v2 2>/dev/null || apt-get install -y docker-compose
if docker compose version >/dev/null 2>&1; then DC="docker compose"; else DC="docker-compose"; fi
systemctl enable --now docker

# 3. Hostname + staatiline IP
log "Hostname $HOST_SHORT.$DOMAIN, IP $IP"
hostnamectl set-hostname "$HOST_SHORT"
sed -i '/127\.0\.1\.1/d' /etc/hosts
sed -i "/[[:space:]]$HOST_SHORT\.$DOMAIN/d" /etc/hosts
echo "$IP $HOST_SHORT.$DOMAIN $HOST_SHORT" >> /etc/hosts
mkdir -p /etc/cloud/cloud.cfg.d
echo "network: {config: disabled}" > /etc/cloud/cloud.cfg.d/99-disable-network-config.cfg
rm -f /etc/netplan/*.yaml
cat > /etc/netplan/01-static.yaml <<EOF
network:
  version: 2
  ethernets:
    $IFACE:
      dhcp4: false
      addresses: [$IP/$PREFIX]
      routes:
        - to: default
          via: $GATEWAY
      nameservers:
        addresses: [$DC_IP]
        search: [$DOMAIN]
EOF
chmod 600 /etc/netplan/01-static.yaml
netplan apply
sleep 3
host -t A "dc.$DOMAIN" >/dev/null || die "DC-d ei leitud DNS-ist"

# 4. LDAPS test
log "Testin LDAPS ühendust"
LDAPTLS_REQCERT=never ldapsearch -LLL -H "ldaps://dc.$DOMAIN" -D "$BIND_DN" -w "$BIND_PASS" \
  -b "$SEARCH_BASE" "(sAMAccountName=ants)" sAMAccountName >/dev/null || die "LDAPS DC-ga ei tööta"

# 5. .env + docker-compose
log "Kirjutan Rocket.Chat seadistuse (/opt/rocketchat)"
mkdir -p /opt/rocketchat
cat > /opt/rocketchat/.env <<EOF
RELEASE=$RC_RELEASE
DOMAIN=$HOST_SHORT.$DOMAIN
ROOT_URL=http://$HOST_SHORT.$DOMAIN
HOST_PORT=80
EOF

cat > /opt/rocketchat/docker-compose.yml <<EOF
services:
  mongodb:
    image: $MONGO_IMAGE
    restart: unless-stopped
    command: ["--replSet", "rs0", "--bind_ip_all"]
    volumes:
      - mongodb-data:/data/db
    healthcheck:
      test: >
        echo 'try { rs.status().ok } catch (e) { rs.initiate({_id: "rs0", members: [{_id: 0, host: "mongodb:27017"}]}).ok }'
        | mongosh --quiet
      interval: 10s
      timeout: 10s
      retries: 30
      start_period: 20s

  rocketchat:
    image: registry.rocket.chat/rocketchat/rocket.chat:\${RELEASE}
    restart: unless-stopped
    depends_on:
      mongodb:
        condition: service_healthy
    ports:
      - "\${HOST_PORT}:3000"
    environment:
      MONGO_URL: "mongodb://mongodb:27017/rocketchat?replicaSet=rs0"
      MONGO_OPLOG_URL: "mongodb://mongodb:27017/local?replicaSet=rs0"
      ROOT_URL: "\${ROOT_URL}"
      PORT: "3000"
      DEPLOY_METHOD: docker
      # Admin + seadistusviisard vahele
      ADMIN_USERNAME: "$RC_ADMIN"
      ADMIN_PASS: "$RC_ADMIN_PASS"
      ADMIN_EMAIL: "$RC_ADMIN@$DOMAIN"
      OVERWRITE_SETTING_Show_Setup_Wizard: "completed"
      # 2FA välja (e-posti ei saa saata)
      OVERWRITE_SETTING_Accounts_TwoFactorAuthentication_Enabled: "false"
      OVERWRITE_SETTING_Accounts_TwoFactorAuthentication_By_Email_Enabled: "false"
      OVERWRITE_SETTING_Accounts_TwoFactorAuthentication_By_Email_Auto_Opt_In: "false"
      # LDAP / Active Directory
      OVERWRITE_SETTING_LDAP_Enable: "true"
      OVERWRITE_SETTING_LDAP_Server_Type: "ad"
      OVERWRITE_SETTING_LDAP_Host: "dc.$DOMAIN"
      OVERWRITE_SETTING_LDAP_Port: "636"
      OVERWRITE_SETTING_LDAP_Encryption: "ssl"
      OVERWRITE_SETTING_LDAP_Reject_Unauthorized: "false"
      OVERWRITE_SETTING_LDAP_Login_Fallback: "true"
      OVERWRITE_SETTING_LDAP_Authentication: "true"
      OVERWRITE_SETTING_LDAP_Authentication_UserDN: "$BIND_DN"
      OVERWRITE_SETTING_LDAP_Authentication_Password: "$BIND_PASS"
      OVERWRITE_SETTING_LDAP_BaseDN: "$SEARCH_BASE"
      OVERWRITE_SETTING_LDAP_User_Search_Filter: "(objectclass=person)"
      OVERWRITE_SETTING_LDAP_User_Search_Field: "sAMAccountName"
      OVERWRITE_SETTING_LDAP_Unique_Identifier_Field: "objectGUID"
      OVERWRITE_SETTING_LDAP_Username_Field: "sAMAccountName"
      OVERWRITE_SETTING_LDAP_Name_Field: "givenName"
      OVERWRITE_SETTING_LDAP_Email_Field: "mail"

volumes:
  mongodb-data:
EOF

# 6. Käivitus
log "Käivitan konteinerid (esimene kord võtab mitu minutit)"
cd /opt/rocketchat
$DC up -d

log "Ootan, kuni Rocket.Chat vastab (kuni 5 min)"
for i in $(seq 1 60); do
  code=$(curl -s -o /dev/null -w '%{http_code}' http://localhost/ || true)
  [[ "$code" == "200" ]] && break
  sleep 5
done

# 7. Kontrollid
log "KONTROLLID"
$DC ps
echo "--- HTTP ---"; curl -s -o /dev/null -w "http://$HOST_SHORT.$DOMAIN -> %{http_code}\n" http://localhost/ || true
echo "--- API info ---"; curl -s http://localhost/api/info; echo

log "VALMIS. Ava WINTEST-is http://$HOST_SHORT.$DOMAIN"
echo "Admin: $RC_ADMIN / $RC_ADMIN_PASS   AD kasutajad: nt ants / (domeeni parool)"
echo "Kui ei vasta: cd /opt/rocketchat && sudo $DC logs rocketchat --tail 50"
