#!/bin/bash
# =====================================================================
#  pilv-setup.sh — NextCloud + AD/LDAP (ainult Juhatus) + External Storage "Eesti"
#  Ubuntu Server 22.04 / 24.04, VÄRSKE VM, vnet508 küljes (DHCP).
#  DC (10.11.12.2) ja FS (10.11.12.10) peavad töötama!
#  Käivita Proxmoxi konsoolis:  sudo bash pilv-setup.sh
# =====================================================================
set -euo pipefail

### ---------- MUUDA VAJADUSEL ---------- ###
HOST_SHORT="pilv"
DOMAIN="vahtra.local"
IP="10.11.12.8"
PREFIX="24"
GATEWAY="10.11.12.1"
DC_IP="10.11.12.2"
NC_ADMIN="admin"
NC_ADMIN_PASS="Parool123!"
DB_PASS="NcDB123!"
BIND_DN="CN=Administrator,CN=Users,DC=vahtra,DC=local"
BIND_PASS="Parool123!"
BASE_DN="DC=vahtra,DC=local"
JUHATUS_DN="CN=Juhatus,OU=Grupid,DC=vahtra,DC=local"
NC_VERSION="latest-31"
### ------------------------------------- ###

NC_DIR="/var/www/nextcloud"
log() { echo -e "\n\e[1;34m>> $*\e[0m"; }
die() { echo -e "\e[1;31mVIGA: $*\e[0m"; exit 1; }
occ() { sudo -u www-data php "$NC_DIR/occ" "$@"; }
[[ $EUID -eq 0 ]] || die "Käivita sudo-ga: sudo bash $0"

IFACE=$(ip -o -4 route show to default | awk '{print $5; exit}')
[[ -n "$IFACE" ]] || IFACE=$(ip -o link show | awk -F': ' '$2!="lo"{print $2; exit}')
log "Võrgukaart: $IFACE"

# 0. Installeri jäägid + DNS (resolved võib olla kinni jäänud)
log "Parandan apt-i ja DNS-i"
sed -i '/cdrom/d' /etc/apt/sources.list 2>/dev/null || true
dpkg --configure -a || true
systemctl disable --now systemd-resolved 2>/dev/null || true
rm -f /etc/resolv.conf
printf "nameserver %s\nsearch %s\n" "$DC_IP" "$DOMAIN" > /etc/resolv.conf

# 1. Paketid
log "Paigaldan Apache, MariaDB, PHP"
export DEBIAN_FRONTEND=noninteractive
apt-get update
apt-get install -y apache2 mariadb-server libapache2-mod-php bzip2 curl ldap-utils smbclient \
  php-gd php-mysql php-curl php-mbstring php-intl php-gmp php-bcmath php-xml php-zip \
  php-ldap php-imagick php-apcu bind9-dnsutils
apt-get install -y php-smbclient || echo "php-smbclient puudub – kasutan smbclient programmi"
PHPV=$(php -r 'echo PHP_MAJOR_VERSION.".".PHP_MINOR_VERSION;')

# 2. Hostname + staatiline IP
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

# 3. LDAPS self-signed sertifikaat lubatud
grep -q '^TLS_REQCERT' /etc/ldap/ldap.conf 2>/dev/null || echo "TLS_REQCERT never" >> /etc/ldap/ldap.conf
LDAPTLS_REQCERT=never ldapsearch -LLL -H "ldaps://dc.$DOMAIN" -D "$BIND_DN" -w "$BIND_PASS" \
  -b "$BASE_DN" "(sAMAccountName=martin)" memberOf >/dev/null || die "LDAPS DC-ga ei tööta"

# 4. PHP seaded
for ini in /etc/php/$PHPV/apache2/php.ini; do
  sed -i 's/^memory_limit = .*/memory_limit = 512M/' "$ini"
  sed -i 's/^upload_max_filesize = .*/upload_max_filesize = 512M/' "$ini"
  sed -i 's/^post_max_size = .*/post_max_size = 512M/' "$ini"
done
echo "apc.enable_cli=1" > /etc/php/$PHPV/cli/conf.d/99-apcu-cli.ini

# 5. Andmebaas
log "Loon andmebaasi"
mysql <<SQL
CREATE DATABASE IF NOT EXISTS nextcloud CHARACTER SET utf8mb4 COLLATE utf8mb4_general_ci;
CREATE USER IF NOT EXISTS 'nextcloud'@'localhost' IDENTIFIED BY '$DB_PASS';
GRANT ALL PRIVILEGES ON nextcloud.* TO 'nextcloud'@'localhost';
FLUSH PRIVILEGES;
SQL

# 6. NextCloud failid
log "Laadin alla NextCloudi ($NC_VERSION)"
if [[ ! -f "$NC_DIR/occ" ]]; then
  curl -fL "https://download.nextcloud.com/server/releases/$NC_VERSION.tar.bz2" -o /tmp/nc.tar.bz2
  tar -xjf /tmp/nc.tar.bz2 -C /var/www/
  rm -f /tmp/nc.tar.bz2
fi
mkdir -p /var/nc-data
chown -R www-data:www-data "$NC_DIR" /var/nc-data

# 7. Apache
log "Seadistan Apache"
cat > /etc/apache2/sites-available/nextcloud.conf <<EOF
<VirtualHost *:80>
    ServerName $HOST_SHORT.$DOMAIN
    DocumentRoot $NC_DIR
    <Directory $NC_DIR/>
        Require all granted
        AllowOverride All
        Options FollowSymLinks MultiViews
    </Directory>
</VirtualHost>
EOF
a2enmod -q rewrite headers env dir mime
a2dissite -q 000-default || true
a2ensite -q nextcloud
systemctl restart apache2

# 8. NextCloud install
log "Installin NextCloudi"
if ! occ status 2>/dev/null | grep -q 'installed: true'; then
  occ maintenance:install --database mysql --database-name nextcloud \
    --database-user nextcloud --database-pass "$DB_PASS" \
    --admin-user "$NC_ADMIN" --admin-pass "$NC_ADMIN_PASS" --data-dir /var/nc-data
fi
occ config:system:set trusted_domains 0 --value="$HOST_SHORT.$DOMAIN"
occ config:system:set trusted_domains 1 --value="$IP"
occ config:system:set overwrite.cli.url --value="http://$HOST_SHORT.$DOMAIN"
occ config:system:set memcache.local --value='\OC\Memcache\APCu'
occ config:system:set default_phone_region --value="EE"

# 9. LDAP / AD
log "Seadistan LDAP-i (sisse saavad ainult Juhatuse liikmed)"
occ app:enable user_ldap
CID=$(occ ldap:show-config 2>/dev/null | awk -F'|' '/Configuration/ {gsub(/ /,"",$3); print $3; exit}')
if [[ -z "$CID" ]]; then
  CID=$(occ ldap:create-empty-config | awk '{print $NF}' | tr -d "'\"" | head -1)
fi
[[ -n "$CID" ]] || die "LDAP konfiguratsiooni ID-d ei saanud"
USER_FILTER="(&(objectclass=person)(memberOf=$JUHATUS_DN))"
set_ldap() { occ ldap:set-config "$CID" "$1" "$2" >/dev/null; }
set_ldap ldapHost                  "ldaps://dc.$DOMAIN"
set_ldap ldapPort                  "636"
set_ldap ldapTLS                   "0"
set_ldap turnOffCertCheck          "1"
set_ldap ldapAgentName             "$BIND_DN"
set_ldap ldapAgentPassword         "$BIND_PASS"
set_ldap ldapBase                  "$BASE_DN"
set_ldap ldapBaseUsers             "OU=Kasutajad,$BASE_DN"
set_ldap ldapBaseGroups            "OU=Grupid,$BASE_DN"
set_ldap ldapUserFilterMode        "1"
set_ldap ldapUserFilter            "$USER_FILTER"
set_ldap ldapLoginFilterMode       "1"
set_ldap ldapLoginFilter           "(&$USER_FILTER(|(sAMAccountName=%uid)(mail=%uid)))"
set_ldap ldapGroupFilterMode       "1"
set_ldap ldapGroupFilter           "(&(objectclass=group)(|(cn=Juhatus)(cn=Tootajad)))"
set_ldap ldapGroupMemberAssocAttr  "member"
set_ldap ldapUserDisplayName       "givenName"
set_ldap ldapEmailAttribute        "mail"
set_ldap ldapExpertUsernameAttr    "sAMAccountName"
set_ldap ldapConfigurationActive   "1"

# 10. External Storage "Eesti" (FS Samba jagatud kaust, kasutaja enda paroolid)
log "Lisan External Storage: Eesti"
occ app:enable files_external
if ! occ files_external:list 2>/dev/null | grep -q '/Eesti'; then
  occ files_external:create /Eesti smb password::sessioncredentials \
    -c host="fs.$DOMAIN" -c share=Eesti -c root= -c domain=VAHTRA
fi

# 11. Kontrollid
log "KONTROLLID"
echo "--- LDAP test ---";      occ ldap:test-config "$CID" || true
echo "--- LDAP kasutajad ---"; occ ldap:search "" 2>/dev/null || true
echo "--- External Storage ---"; occ files_external:list || true
echo "--- HTTP ---"; curl -s -o /dev/null -w "http://$HOST_SHORT.$DOMAIN -> %{http_code}\n" -H "Host: $HOST_SHORT.$DOMAIN" http://localhost/login || true

log "VALMIS. Ava WINTEST-is http://$HOST_SHORT.$DOMAIN — logi sisse nt martin / (domeeni parool)"
echo "Ants (mitte Juhatus) EI tohiks sisse saada."
