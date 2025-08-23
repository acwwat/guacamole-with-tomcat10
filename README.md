# Guacamole 1.6.0 — Fresh Install on Ubuntu 24.04 (RDP-enabled)

Single bash script to **remove old installs** and deploy a **clean** Apache Guacamole 1.6.0 stack:

- **guacd** compiled from source (with **RDP** via `freerdp3-dev`, plus **SSH/VNC`**)
- **Tomcat 10.1.44** (manual install) + **OpenJDK 21**
- **MariaDB** backend (JDBC auth via **MySQL Connector/J** 8.4.x)
- Extensions: **TOTP 2FA**, **QuickConnect**, **Session Recording**
- **Jakarta** migration for Tomcat 10 (WAR + extensions)
- Optional **Nginx + Let's Encrypt** reverse proxy

> ⚠️ **Destructive**: can drop/replace existing Guacamole/Tomcat/DB depending on your answers. The script backs up any prior install into `/root/guac-backup-YYYY-MM-DD_HHMMSS`.

---

## TL;DR

```bash
# 1) Copy the script to server as: guac_fresh_install.sh
sudo bash guac_fresh_install.sh

# 2) Answer the 20 pre-flight questions (summary shown; press ENTER to confirm).

# 3) Open Guacamole
# - direct mode:  http://<server-ip>:<Q3_PORT><Q4_CTX>/
# - nginx mode:   https://<domain><Q4_CTX>/
# Login: guacadmin / guacadmin (rotate & disable immediately)
```

---

## What this script installs

- **Apache Tomcat**: 10.1.44 at `/opt/tomcat` (systemd unit: `tomcat.service`).
- **guacd (server)**: built from `guacamole-server-1.6.0` with **RDP (FreeRDP 3)**, SSH, VNC, audio/video libs where available (systemd: `guacd.service`). Binds to your chosen address (default `127.0.0.1:4822`).
- **Guacamole client**: `guacamole-1.6.0` **WAR**, Jakarta-migrated, deployed to Tomcat as `<context>.war` (default path `/guacamole`).
- **MariaDB**: DB, user, and schema for JDBC auth (creates default `guacadmin`).
- **Extensions**: TOTP 2FA, QuickConnect, History Recording (all migrated to Jakarta).
- **JDBC driver**: **MySQL Connector/J** `8.4.x` in `/etc/guacamole/lib/` (fixes “No suitable driver…”).

**Why MySQL Connector/J?** MariaDB Connector/J 3.x may not claim `jdbc:mysql://` URLs. Using MySQL’s driver is the most reliable choice for Guacamole 1.6.0 on Tomcat 10.

---

## What it removes (with backup)

- Stops & removes prior **Tomcat** (`/opt/tomcat` + unit), **guacd** (`/usr/local/sbin/guacd` + libs), and **/etc/guacamole**.
- Saves copies to `/root/guac-backup-YYYY-MM-DD_HHMMSS` before removal.
- Optionally **drops and recreates** the DB if you answer `Q15 = y`.

---

## The 20 pre-flight questions

| #  | Prompt (default)                                                                                | Notes |
|----|--------------------------------------------------------------------------------------------------|-------|
| Q1 | This will REMOVE old installs. Type **YES** to proceed                                          | Safety gate |
| Q2 | Deployment mode: `direct` or `nginx,<domain>,<email>` (direct)                                  | Nginx enables HTTPS + optional HSTS |
| Q3 | Tomcat HTTP port (8080)                                                                         | Applies to Tomcat connector |
| Q4 | Web context path (/guacamole)                                                                   | WAR name follows this |
| Q5 | MariaDB database name (guacamole_db)                                                            |  |
| Q6 | MariaDB username (guacamole_user)                                                               |  |
| Q7 | MariaDB password (auto-generate if empty)                                                       | Stored in `guacamole.properties` |
| Q8 | MariaDB root auth method: `socket` / `password` (socket)                                        | If `password`, you’ll be asked for root password |
| Q9 | Enable TOTP 2FA? (Y)                                                                            | Installs TOTP extension |
| Q10| QuickConnect allowed protocols (rdp,ssh,vnc)                                                     | RDP supported via FreeRDP 3 |
| Q11| Session recording path (/var/lib/guacamole/recordings)                                          | Created & chowned to `tomcat` |
| Q12| Timezone (auto-detected, e.g., Africa/Cairo)                                                     | Applies to OS time |
| Q13| Tomcat heap (Xms Xmx) (512m 1g)                                                                 | e.g., `1024m 2048m` |
| Q14| If DB exists, DROP and recreate? (N)                                                            | Destructive; always backed up first |
| Q15| Create an additional admin user now? (N)                                                        | If Y, Q16 & Q17 appear |
| Q16| Extra admin username (admin)                                                                    | Only asked if Q15=Y |
| Q17| Extra admin password (auto-generate if empty)                                                   | Only asked if Q15=Y |
| Q18| `guacd` bind address (127.0.0.1)                                                                | Use `0.0.0.0` to expose on network |
| Q19| QuickConnect: deny plaintext `password` parameter? (Y)                                          | Security hardening |
| Q20| (nginx mode only) Enable HSTS on Nginx? (Y)                                                     | Adds `Strict-Transport-Security` |

A summary of your answers is shown before the install begins.

---

## File/Service layout

- **Tomcat**: `/opt/tomcat`, unit: `tomcat.service`  
- **Guacamole HOME**: `/etc/guacamole`  
  - `guacamole.properties`
  - `extensions/*.jar` (Jakarta-migrated TOTP/QuickConnect/History/JDBC MySQL)
  - `lib/mysql-connector-j-8.4.x.jar`
- **guacd**: `/usr/local/sbin/guacd`, unit: `guacd.service` (binds to your selection, default `127.0.0.1:4822`)  
- **Recordings**: `Q11` (default `/var/lib/guacamole/recordings`)  
- **Backups**: `/root/guac-backup-...`

---

## Running the installer

```bash
chmod +x guac_fresh_install.sh
sudo bash guac_fresh_install.sh
```

- Press **ENTER** to confirm the summary.
- The script runs idempotently where possible. If you re-run, previous backups remain.

---

## After installation

1. Visit the portal:
   - **direct**: `http://<server-ip>:<Q3_PORT><Q4_CTX>/`
   - **nginx**:  `https://<domain><Q4_CTX>/` (DNS must point to the server; Let’s Encrypt requires 80/443 inbound)
2. Login with **`guacadmin / guacadmin`** → change password, create your real admin, and **disable `guacadmin`**.
3. (If created) switch to your **extra admin** user from Q15–Q17.
4. Configure connections (RDP/SSH/VNC).

---

## Verification & Troubleshooting

### Quick checks

```bash
# Services
systemctl status guacd
systemctl status tomcat

# Guacamole logs (Tomcat)
journalctl -u tomcat -n 200 --no-pager | egrep -i "Loaded extension|mysql|jdbc|driver|SEVERE|ERROR"

# Extensions & JDBC driver
ls -1 /etc/guacamole/extensions
ls -1 /etc/guacamole/lib

# DB sanity (should return: guacadmin | 0)
mariadb -N -e "
SELECT e.name AS username, u.disabled
FROM guacamole_entity e JOIN guacamole_user u ON u.entity_id=e.entity_id
WHERE e.type='USER' AND e.name='guacadmin';" guacamole_db
```

### Common errors

- **“No suitable driver found for jdbc:mysql://…”**  
  Ensure `/etc/guacamole/lib/mysql-connector-j-8.4.x.jar` exists and Tomcat has been restarted.

- **Extension not a valid zip / migration issues**  
  Re-run the script to regenerate **Jakarta-migrated JARs** using the migration tool.

- **Login fails / “unknown error”**  
  Check Tomcat logs for **MySQL Authentication loaded** and any JDBC stack traces.

- **RDP doesn’t appear**  
  Confirm `freerdp3-dev` and `freerdp3-x11` installed and `guacd` rebuilt successfully.  
  `ldconfig` is run by the script; re-run if you added packages later.

- **HTTPS (nginx) fails**  
  Make sure your domain resolves to the server, ports **80/443** open, then re-run the script (nginx mode).

---

## Security notes

- Tomcat runs as **`tomcat`** with `UMask=0027`.
- QuickConnect can **deny** the `password` parameter if you keep `Q19 = Y`.
- `guacd` binds to `127.0.0.1` by default. Change to `0.0.0.0` only if you need remote guacd access (and firewall accordingly).
- Rotate the default `guacadmin` credentials and disable the account.

---

## Uninstall / Rollback

- Stop services: `sudo systemctl stop tomcat guacd`  
- Remove `/opt/tomcat`, `/etc/guacamole`, and guacd binaries if needed.  
- Restore from `/root/guac-backup-YYYY-MM-DD_HHMMSS` as desired.

---

## Customization

- Change Tomcat heap via Q13 or edit `JAVA_OPTS` in `/etc/systemd/system/tomcat.service` then `systemctl daemon-reload && systemctl restart tomcat`.
- Change context path by re-deploying the WAR name, e.g., `/opt/tomcat/webapps/<newname>.war` and updating your reverse proxy.

---

## Compatibility

- **Ubuntu**: 24.04 LTS (Noble)
- **FreeRDP**: 3.x (`freerdp3-dev`)
- **Java**: OpenJDK 21
- **Tomcat**: 10.1.44
- **Guacamole**: 1.6.0

If your distro mirrors lag behind for `freerdp3-dev`, install system updates (`apt update && apt upgrade -y`) and retry.
