#!/bin/bash
# =====================================================================
#  samba-dc.sh — Samba AD domeenikontroller (ÕV 3, Eesti AS)
#  Ubuntu Server 22.04 / 24.04 LTS, VÄRSKE VM, võrgukaart vnet508 küljes (DHCP).
#  Käivita Proxmoxi konsoolis:  sudo bash samba-dc.sh
#  (mitte SSH kaudu — IP muutub skripti ajal ja SSH ühendus katkeks)
# =====================================================================
set -euo pipefail

### ---------- MUUDA VAJADUSEL ---------- ###
HOST_SHORT="dc"
DOMAIN="vahtra.local"
REALM="VAHTRA.LOCAL"
NETBIOS="VAHTRA"
IP="10.11.12.2"
PREFIX="24"
GATEWAY="10.11.12.1"
FORWARDER="10.11.12.1"          # OPNsense Unbound
ADMIN_PASS="Parool123!"         # Administratori parool (peab olema keerukas!)
USER_PASS="Parool123!"          # kasutajate algparool
CREATE_OBJECTS=1                # 1 = loo OU-d/grupid/kasutajad, 0 = jäta vahele
### ------------------------------------- ###

BASE_DN="DC=${DOMAIN//./,DC=}"
log() { echo -e "\n\e[1;34m>> $*\e[0m"; }

[[ $EUID -eq 0 ]] || { echo "Käivita sudo-ga: sudo bash $0"; exit 1; }
[[ -f /var/lib/samba/private/sam.ldb ]] && { echo "Domeen on juba provisioneeritud, katkestan."; exit 1; }

IFACE=$(ip -o -4 route show to default | awk '{print $5; exit}')
[[ -n "$IFACE" ]] || IFACE=$(ip -o link show | awk -F': ' '$2!="lo"{print $2; exit}')
log "Võrgukaart: $IFACE"

# 1. Paketid (installime enne IP muutmist, kuni DHCP DNS töötab)
log "Paigaldan paketid"
echo "krb5-config krb5-config/default_realm string $REALM"                  | debconf-set-selections
echo "krb5-config krb5-config/kerberos_servers string $HOST_SHORT.$DOMAIN"  | debconf-set-selections
echo "krb5-config krb5-config/admin_server string $HOST_SHORT.$DOMAIN"      | debconf-set-selections
export DEBIAN_FRONTEND=noninteractive
apt-get update
PKGS="samba krb5-user krb5-config winbind smbclient bind9-dnsutils ldb-tools acl attr"
# Ubuntu 24.04+ on AD DC eraldi paketis, 22.04-l on see 'samba' sees
apt-cache show samba-ad-dc >/dev/null 2>&1 && PKGS="$PKGS samba-ad-dc"
apt-get install -y $PKGS

# 2. Hostname + /etc/hosts
log "Hostname: $HOST_SHORT.$DOMAIN"
hostnamectl set-hostname "$HOST_SHORT"
sed -i '/127\.0\.1\.1/d' /etc/hosts
sed -i "/[[:space:]]$HOST_SHORT\.$DOMAIN/d" /etc/hosts
echo "$IP $HOST_SHORT.$DOMAIN $HOST_SHORT" >> /etc/hosts

# 3. Teenused, mis AD DC-ga konfliktis
log "Peatan smbd/nmbd/winbind ja systemd-resolved"
for s in smbd nmbd winbind; do
  systemctl disable --now "$s" 2>/dev/null || true
  systemctl mask "$s" 2>/dev/null || true
done
systemctl disable --now systemd-resolved 2>/dev/null || true
rm -f /etc/resolv.conf
printf "nameserver %s\nsearch %s\n" "$IP" "$DOMAIN" > /etc/resolv.conf

# 4. Domeeni provisioneerimine
log "Provisioneerin domeeni $REALM"
[[ -f /etc/samba/smb.conf ]] && mv /etc/samba/smb.conf /etc/samba/smb.conf.orig
samba-tool domain provision \
  --use-rfc2307 \
  --realm="$REALM" \
  --domain="$NETBIOS" \
  --server-role=dc \
  --dns-backend=SAMBA_INTERNAL \
  --host-ip="$IP" \
  --adminpass="$ADMIN_PASS" \
  --option="dns forwarder = $FORWARDER"

cp /var/lib/samba/private/krb5.conf /etc/krb5.conf

# 5. Staatiline IP (netplan)
log "Seadistan staatilise IP $IP/$PREFIX"
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
        addresses: [$IP]
        search: [$DOMAIN]
EOF
chmod 600 /etc/netplan/01-static.yaml
netplan apply
sleep 3

# 6. Samba AD DC teenus
log "Käivitan samba-ad-dc"
systemctl unmask samba-ad-dc
systemctl enable --now samba-ad-dc
sleep 10

# 7. OU-d, grupid, kasutajad
if [[ "$CREATE_OBJECTS" == "1" ]]; then
  log "Loon OU struktuuri"
  mk_ou() { samba-tool ou add "$1" 2>/dev/null || samba-tool ou create "$1"; }
  mk_ou "OU=Grupid"
  mk_ou "OU=Kasutajad"
  mk_ou "OU=Tootajad,OU=Kasutajad"
  mk_ou "OU=Juhatus,OU=Kasutajad"
  mk_ou "OU=Arvutid"

  log "Loon turvagrupid"
  samba-tool group add Tootajad --groupou="OU=Grupid" --group-scope=Global --group-type=Security
  samba-tool group add Juhatus  --groupou="OU=Grupid" --group-scope=Global --group-type=Security

  log "Loon kasutajad"
  mk_user() {  # kasutajanimi Eesnimi OU
    samba-tool user create "$1" "$USER_PASS" \
      --given-name="$2" \
      --mail-address="$1@$DOMAIN" \
      --userou="$3"
  }
  # Juhatus (on ka töötajad)
  for u in Martin Toivo Viktor; do mk_user "${u,,}" "$u" "OU=Juhatus,OU=Kasutajad"; done
  # Ülejäänud töötajad
  for u in Ants Reeli Marge Tiiu Lembit; do mk_user "${u,,}" "$u" "OU=Tootajad,OU=Kasutajad"; done

  samba-tool group addmembers Juhatus  martin,toivo,viktor
  samba-tool group addmembers Tootajad ants,reeli,marge,tiiu,lembit,martin,toivo,viktor
fi

# 8. Kontrollid
log "KONTROLLID"
echo "--- DNS SRV kirje ---";      host -t SRV "_ldap._tcp.$DOMAIN." || true
echo "--- DC A-kirje ---";         host -t A "$HOST_SHORT.$DOMAIN." || true
echo "--- Väline DNS (forwarder) ---"; host -t A google.com || true
echo "--- Kerberos ---"
echo "$ADMIN_PASS" | kinit "administrator@$REALM" >/dev/null && klist || true
echo "--- Domeeni tase ---";       samba-tool domain level show || true
echo "--- Grupid (wbinfo -g) ---"; wbinfo -g || true

log "VALMIS. Domeen $DOMAIN töötab aadressil $IP."
echo "Soovitus: tee 'sudo reboot' ja kontrolli: systemctl status samba-ad-dc"
