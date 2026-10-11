#!/bin/bash
# =====================================================================
#  wiki-setup.sh — Wiki.js (Docker + PostgreSQL) (ÕV 3, Eesti AS)
#  Ubuntu Server 22.04 / 24.04, VÄRSKE VM, vnet508 küljes (DHCP).
#  Käivita Proxmoxi konsoolis:  sudo bash wiki-setup.sh
#  Pärast: ava WINTEST-is http://wiki.vahtra.local (või http://10.11.12.4)
# =====================================================================
set -euo pipefail

### ---------- MUUDA VAJADUSEL ---------- ###
HOST_SHORT="wiki"
DOMAIN="vahtra.local"
IP="10.11.12.4"
PREFIX="24"
GATEWAY="10.11.12.1"
DC_IP="10.11.12.2"
DB_PASS="WikiDB123!"
### ------------------------------------- ###

log() { echo -e "\n\e[1;34m>> $*\e[0m"; }
[[ $EUID -eq 0 ]] || { echo "Käivita sudo-ga: sudo bash $0"; exit 1; }

IFACE=$(ip -o -4 route show to default | awk '{print $5; exit}')
[[ -n "$IFACE" ]] || IFACE=$(ip -o link show | awk -F': ' '$2!="lo"{print $2; exit}')
log "Võrgukaart: $IFACE"

# 0. Installeri jäägid
log "Parandan apt-i"
sed -i '/cdrom/d' /etc/apt/sources.list 2>/dev/null || true
dpkg --configure -a || true

# 1. Docker
log "Paigaldan Dockeri"
export DEBIAN_FRONTEND=noninteractive
apt-get update
apt-get install -y docker.io bind9-dnsutils
apt-get install -y docker-compose-v2 2>/dev/null || apt-get install -y docker-compose
if docker compose version >/dev/null 2>&1; then DC="docker compose"; else DC="docker-compose"; fi
systemctl enable --now docker

# 2. Hostname
log "Hostname: $HOST_SHORT.$DOMAIN"
hostnamectl set-hostname "$HOST_SHORT"
sed -i '/127\.0\.1\.1/d' /etc/hosts
sed -i "/[[:space:]]$HOST_SHORT\.$DOMAIN/d" /etc/hosts
echo "$IP $HOST_SHORT.$DOMAIN $HOST_SHORT" >> /etc/hosts

# 3. Staatiline IP + DNS = DC
log "Staatiline IP $IP/$PREFIX, DNS $DC_IP"
systemctl disable --now systemd-resolved 2>/dev/null || true
rm -f /etc/resolv.conf
printf "nameserver %s\nsearch %s\n" "$DC_IP" "$DOMAIN" > /etc/resolv.conf
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

# 4. Wiki.js + PostgreSQL
log "Käivitan Wiki.js konteinerid"
mkdir -p /opt/wikijs
cat > /opt/wikijs/docker-compose.yml <<EOF
services:
  db:
    image: postgres:15-alpine
    restart: unless-stopped
    environment:
      POSTGRES_DB: wiki
      POSTGRES_USER: wikijs
      POSTGRES_PASSWORD: "$DB_PASS"
    volumes:
      - db-data:/var/lib/postgresql/data

  wiki:
    image: ghcr.io/requarks/wiki:2
    restart: unless-stopped
    depends_on:
      - db
    environment:
      DB_TYPE: postgres
      DB_HOST: db
      DB_PORT: 5432
      DB_USER: wikijs
      DB_PASS: "$DB_PASS"
      DB_NAME: wiki
    ports:
      - "80:3000"

volumes:
  db-data:
EOF
cd /opt/wikijs
$DC up -d

log "Ootan, kuni Wiki.js käivitub (kuni 2 min)"
for i in $(seq 1 24); do
  if curl -s -o /dev/null -w '%{http_code}' http://localhost | grep -qE '200|302'; then break; fi
  sleep 5
done

# 5. Kontrollid
log "KONTROLLID"
$DC ps
echo "--- DC nähtav? ---"; host -t A "dc.$DOMAIN" || true
echo "--- HTTP ---"; curl -s -o /dev/null -w 'http://localhost -> %{http_code}\n' http://localhost || true

log "VALMIS. Ava WINTEST-is: http://$IP  (pärast DNS kirjet: http://$HOST_SHORT.$DOMAIN)"
