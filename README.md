# ÕV 3 – Eesti AS infosüsteem (automaatskriptid)

Skriptid ITS24 ÕV 3 labori serverite seadistamiseks.
Domeen: `vahtra.local` · Kohtvõrk: `10.11.12.0/24` · Ruuter: OPNsense `10.11.12.1`

| Skript | Server | IP | Mida teeb |
|---|---|---|---|
| `samba-dc.sh` | dc.vahtra.local | 10.11.12.2 | Samba AD domeenikontroller, DNS, OU-d, grupid, kasutajad |
| `samba-fs.sh` | fs.vahtra.local | 10.11.12.10 | Samba failiserver domeeni liikmena, kaustad Juhatus / Eesti / Avalik |
| `wiki-setup.sh` | wiki.vahtra.local | 10.11.12.4 | Wiki.js + PostgreSQL Dockeris (port 80) |

## Kasutamine

Värske Ubuntu Server 22.04 / 24.04, võrgukaart kohtvõrgus (DHCP).
Käivita **Proxmoxi konsoolis** (mitte SSH kaudu – IP muutub skripti ajal):

```bash
wget https://raw.githubusercontent.com/Anviktor2411/samba/main/<skript>.sh
sudo bash <skript>.sh
```

Järjekord: **dc → fs → wiki**. DC peab teiste skriptide ajal töötama.

## Märkused

- Paroolid on faili alguses muutujatena (`ADMIN_PASS`, `USER_PASS`, `DB_PASS`) – muuda enne käivitamist.
- Skriptid parandavad ise Ubuntu installeri jäägid (`cdrom` paketiallikas, pooleli `dpkg`).
- Laborikeskkonna jaoks – mitte tootmiskasutuseks.
