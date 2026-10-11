#!/bin/bash
# =====================================================================
#  samba-fs.sh — Samba failiserver, domeeni liige (ÕV 3, Eesti AS)
#  Ubuntu Server 22.04 / 24.04, VÄRSKE VM, vnet508 küljes (DHCP).
#  DC (10.11.12.2) peab töötama!
#  Käivita Proxmoxi konsoolis:  sudo bash samba-fs.sh
# =====================================================================
set -euo pipefail

### ---------- MUUDA VAJADUSEL ---------- ###
HOST_SHORT="fs"
DOMAIN="vahtra.local"
REALM="VAHTRA.LOCAL"
NETBIOS="VAHTRA"
IP="10.11.12.10"
PREFIX="24"
GATEWAY="10.11.12.1"
DC_IP="10.11.12.2"
ADMIN_PASS="Parool123!"        # domeeni Administratori parool
SHARE_ROOT="/srv/samba"
### ------------------------------------- ###

log() { echo -e "\n\e[1;34m>> $*\e[0m"; }
[[ $EUID -eq 0 ]] || { echo "Käivita sudo-ga: sudo bash $0"; exit 1; }

IFACE=$(ip -o -4 route show to default | awk '{print $5; exit}')
[[ -n "$IFACE" ]] || IFACE=$(ip -o link show | awk -F': ' '$2!="lo"{print $2; exit}')
log "Võrgukaart: $IFACE"

# 0. Paranda installeri jäägid (cdrom allikas, pooleli dpkg)
log "Parandan apt-i (cdrom rida, pooleli paigaldused)"
sed -i '/cdrom/d' /etc/apt/sources.list 2>/dev/null || true
dpkg --configure -a || true

# 1. Paketid
log "Paigaldan paketid"
echo "krb5-config krb5-config/default_realm string $REALM"         | debconf-set-selections
echo "krb5-config krb5-config/kerberos_servers string dc.$DOMAIN"  | debconf-set-selections
echo "krb5-config krb5-config/admin_server string dc.$DOMAIN"      | debconf-set-selections
export DEBIAN_FRONTEND=noninteractive
apt-get update
apt-get install -y samba winbind libnss-winbind libpam-winbind krb5-user krb5-config \
                   smbclient acl attr bind9-dnsutils

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

log "Kontrollin, kas DC on nähtav"
host -t SRV "_ldap._tcp.$DOMAIN." || { echo "DC-d ei leitud! Kas dc VM töötab?"; exit 1; }

# 4. Kerberos
cat > /etc/krb5.conf <<EOF
[libdefaults]
    default_realm = $REALM
    dns_lookup_realm = false
    dns_lookup_kdc = true
EOF

# 5. smb.conf
log "Kirjutan smb.conf"
[[ -f /etc/samba/smb.conf ]] && mv /etc/samba/smb.conf /etc/samba/smb.conf.orig
mkdir -p "$SHARE_ROOT"/{Juhatus,Eesti,Avalik}
cat > /etc/samba/smb.conf <<EOF
[global]
    workgroup = $NETBIOS
    realm = $REALM
    security = ADS
    netbios name = ${HOST_SHORT^^}

    winbind use default domain = yes
    winbind refresh tickets = yes
    winbind enum users = yes
    winbind enum groups = yes
    template shell = /bin/bash
    template homedir = /home/%U

    idmap config * : backend = tdb
    idmap config * : range = 3000-7999
    idmap config $NETBIOS : backend = rid
    idmap config $NETBIOS : range = 10000-999999

    vfs objects = acl_xattr
    map acl inherit = yes
    store dos attributes = yes

[Juhatus]
    path = $SHARE_ROOT/Juhatus
    read only = no
    valid users = @juhatus

[Eesti]
    path = $SHARE_ROOT/Eesti
    read only = no
    valid users = @tootajad

[Avalik]
    path = $SHARE_ROOT/Avalik
    read only = yes
    valid users = "@domain users"
    write list = "@domain admins"
EOF

# 6. NSS winbind
sed -i 's/^passwd:.*/passwd:         files systemd winbind/' /etc/nsswitch.conf
sed -i 's/^group:.*/group:          files systemd winbind/' /etc/nsswitch.conf

# 7. Domeeniga liitumine
log "Liitun domeeniga $DOMAIN"
net ads join -U "administrator%$ADMIN_PASS"
systemctl enable smbd nmbd winbind
systemctl restart winbind smbd nmbd
sleep 5

# 8. Kaustade õigused domeeni gruppidega
log "Sean kaustade õigused"
getent group juhatus >/dev/null || { echo "Grupp 'juhatus' ei lahendu (winbind)!"; exit 1; }

chown root:juhatus   "$SHARE_ROOT/Juhatus"; chmod 2770 "$SHARE_ROOT/Juhatus"
setfacl -m  g:juhatus:rwx  "$SHARE_ROOT/Juhatus"
setfacl -dm g:juhatus:rwx  "$SHARE_ROOT/Juhatus"

chown root:tootajad  "$SHARE_ROOT/Eesti";   chmod 2770 "$SHARE_ROOT/Eesti"
setfacl -m  g:tootajad:rwx "$SHARE_ROOT/Eesti"
setfacl -dm g:tootajad:rwx "$SHARE_ROOT/Eesti"

chown root:"domain users" "$SHARE_ROOT/Avalik"; chmod 2755 "$SHARE_ROOT/Avalik"
setfacl -m  g:"domain users":rx  "$SHARE_ROOT/Avalik"
setfacl -m  g:"domain admins":rwx "$SHARE_ROOT/Avalik"
setfacl -dm g:"domain admins":rwx "$SHARE_ROOT/Avalik"
echo "Tere tulemast Eesti AS avalikku kausta!" > "$SHARE_ROOT/Avalik/LOEMIND.txt"

# 9. Kontrollid
log "KONTROLLID"
echo "--- wbinfo -t (usaldus DC-ga) ---"; wbinfo -t || true
echo "--- Grupid ---"; getent group juhatus tootajad || true
echo "--- Kaustad ---"; ls -lah "$SHARE_ROOT"
echo "--- Jagatud kaustad ---"; smbclient -L localhost -U "administrator%$ADMIN_PASS" 2>/dev/null | grep -E 'Disk' || true

log "VALMIS. Failiserver $HOST_SHORT.$DOMAIN ($IP) on domeenis."
echo "Raporti jaoks: ls -lah $SHARE_ROOT   ja   testparm -s"
