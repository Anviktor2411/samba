#!/bin/bash
# =====================================================================
#  dns-records.sh — lisab kõigile serveritele A- ja PTR-kirjed DC DNS-i
#  Käivita DC-s (dc.vahtra.local):  sudo bash dns-records.sh
# =====================================================================

DOMAIN="vahtra.local"
REVZONE="12.11.10.in-addr.arpa"
ADMIN_PASS="Parool123!"

# hostname  IP
RECORDS=(
  "ruuter 10.11.12.1"
  "fs     10.11.12.10"
  "wiki   10.11.12.4"
  "chat   10.11.12.6"
  "pilv   10.11.12.8"
)

[[ $EUID -eq 0 ]] || { echo "Käivita sudo-ga: sudo bash $0"; exit 1; }
AUTH=(-U administrator --password="$ADMIN_PASS")

# Pöördtsoon (PTR) – kui juba olemas, jätkab
samba-tool dns zonecreate 127.0.0.1 "$REVZONE" "${AUTH[@]}" 2>/dev/null \
  && echo "Pöördtsoon $REVZONE loodud" || echo "Pöördtsoon $REVZONE juba olemas"

for r in "${RECORDS[@]}"; do
  set -- $r
  name=$1; ip=$2; last=${ip##*.}

  # A-kirje: kui on olemas, uuenda; muidu lisa
  old=$(host -t A "$name.$DOMAIN" 127.0.0.1 2>/dev/null | awk '/has address/{print $4; exit}')
  if [[ -z "$old" ]]; then
    samba-tool dns add 127.0.0.1 "$DOMAIN" "$name" A "$ip" "${AUTH[@]}" >/dev/null && echo "A   $name -> $ip lisatud"
  elif [[ "$old" != "$ip" ]]; then
    samba-tool dns update 127.0.0.1 "$DOMAIN" "$name" A "$old" "$ip" "${AUTH[@]}" >/dev/null && echo "A   $name $old -> $ip uuendatud"
  else
    echo "A   $name -> $ip juba olemas"
  fi

  # PTR-kirje
  samba-tool dns add 127.0.0.1 "$REVZONE" "$last" PTR "$name.$DOMAIN" "${AUTH[@]}" >/dev/null 2>&1 \
    && echo "PTR $ip -> $name.$DOMAIN lisatud" || echo "PTR $ip juba olemas"
done

# DC enda PTR
samba-tool dns add 127.0.0.1 "$REVZONE" 2 PTR "dc.$DOMAIN" "${AUTH[@]}" >/dev/null 2>&1 || true

echo -e "\n--- Kontroll ---"
for h in dc ruuter fs wiki chat pilv; do host "$h.$DOMAIN" 127.0.0.1 | grep 'has address'; done
echo -e "\n--- Kõik kirjed tsoonis $DOMAIN ---"
samba-tool dns query 127.0.0.1 "$DOMAIN" @ ALL "${AUTH[@]}" 2>/dev/null | grep -E 'Name=|  A:' || true
