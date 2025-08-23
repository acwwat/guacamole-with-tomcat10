# Guacamole 1.6.0 on Ubuntu 24.04 (Jakarta / Tomcat 10.1.44) — **README**

> **TL;DR**  
> Run on a clean Ubuntu 24.04 host:  
> ```bash
> chmod +x guac.sh
> sudo ./guac.sh
> ```  
> Answer 5 prompts → script **removes old installs**, **drops & recreates** `guacamole_db`, builds **guacd 1.6.0**, installs **Tomcat 10.1.44**, migrates Guacamole 1.6.0 to **Jakarta**, deploys **JDBC/TOTP/QuickConnect/Encrypted-JSON/Recording Player**, and performs health checks.  
> **Risk**: Tomcat 10 for Guacamole 1.6.0 is an advanced (unsupported) path using Jakarta migration. Keep a Tomcat 9 fallback handy.

---

## 0) What this installer does

- **Destructive clean** of previous Guacamole/Tomcat (backs up to `/root/guac-backup-<timestamp>`).
- **Fixes `/tmp`** & stabilizes APT, then installs build deps + **OpenJDK 21 + MariaDB**.
- Builds **guacd 1.6.0** (from source) and sets up a hardened systemd service.
- Installs **Tomcat 10.1.44** (manual) with systemd & `GUACAMOLE_HOME=/etc/guacamole`.
- Downloads **Guacamole 1.6.0 WAR + extensions**, migrates WAR/JARs from `javax.*` → `jakarta.*`.
- Deploys **JDBC (MariaDB)**, **TOTP**, **QuickConnect**, **Encrypted JSON**, **History Recording Player**.
- Creates **MariaDB**: `guacamole_db`, user `guacamole_user` / pass `123Beta`, **(drops existing DB)**, loads schema.
- Creates **recording** path, writes `guacamole.properties`, restarts Tomcat, and runs **health checks**.
- Optional **Nginx + Let’s Encrypt** reverse proxy (if selected in Q2).

---

## 1) Prerequisites

- **Ubuntu 24.04 LTS** (fresh or with no conflicting Tomcat/Guacamole).
- Root (or `sudo`) access.
- Outbound internet to download Apache artifacts & packages.
- If choosing **Nginx mode**: a public **DNS A record** pointing to this host, port **80** reachable.

---

## 2) Running the installer

```bash
chmod +x guac.sh
sudo ./guac.sh
```

You’ll be asked **5 questions**:

1. **Destructive confirmation** — type `YES` to continue.
2. **Mode** — `direct` (Tomcat on :8080) **or** `nginx,example.com,admin@example.com`.
3. **JSON secret** — `auto` or paste a **32-hex** key (used by Encrypted JSON auth).
4. **QuickConnect protocols** — default `rdp,ssh,vnc`.
5. **Recording path** — default `/var/lib/guacamole/recordings`.

> **Note:** The script **drops & recreates** `guacamole_db`. A backup is stored under `/root/guac-backup-*/db_guacamole_db_*.sql.gz` before dropping.

---

## 3) After install — first login

- **URL (direct mode):** `http://<server-ip>:8080/guacamole/`  
  **URL (nginx mode):** `http(s)://<your-domain>/`
- Default credentials (created by JDBC schema):  
  **user:** `guacadmin` — **pass:** `guacadmin`
- Immediately:
  1. Login and **change** `guacadmin` password.
  2. Create a real admin, **disable** `guacadmin`.

---

## 4) What gets installed & where

**Services**
- `guacd` — systemd (`/etc/systemd/system/guacd.service`)
- `tomcat` — systemd (`/etc/systemd/system/tomcat.service`)

**Paths**
- Tomcat home: `/opt/tomcat`
- Guacamole home (`GUACAMOLE_HOME`): `/etc/guacamole`
  - Extensions: `/etc/guacamole/extensions`
  - JDBC driver: `/etc/guacamole/lib`
  - Config: `/etc/guacamole/guacamole.properties`
- Session recordings: `/var/lib/guacamole/recordings` (configurable)

**Logs**
- Tomcat: `/opt/tomcat/logs/catalina.out` (and related)
- guacd: `journalctl -u guacd` (systemd)

---

## 5) Health checks & common commands

```bash
# service status
sudo systemctl --no-pager status guacd tomcat

# listening ports (should show 4822 and 8080 in direct mode)
ss -lntp | grep -E ':4822|:8080'

# HTTP check (direct mode)
curl -I http://127.0.0.1:8080/guacamole/ | head -n1  # 200/302/401 are OK

# versions
guacd -v   # should show 1.6.0
```

---

## 6) Security checklist (minimum)

- **Rotate** DB password (`123Beta`) and `json-secret-key` after testing. Store in a secret manager.
- If using **Nginx**, enable `use-remote-address: true` (the script does this automatically for Nginx mode).
- Consider removing Tomcat default apps:
  ```bash
  sudo rm -rf /opt/tomcat/webapps/{docs,examples,host-manager,manager,ROOT}
  sudo systemctl restart tomcat
  ```
- Firewall: allow **80/443** (Nginx) or only trusted **8080** (direct). Example (UFW):
  ```bash
  sudo ufw allow 8080/tcp    # direct mode only
  sudo ufw allow 80,443/tcp  # nginx mode
  sudo ufw enable
  ```

---

## 7) Feature notes

### 7.1 TOTP (2FA)
- TOTP extension is installed.  
- Users enroll TOTP at first login if enforced.  
- Optional props exist (issuer, host rules) — see `guacamole.properties` comments.

### 7.2 Session Recording
- Recording **playback** is enabled by the **History Recording Storage** extension.  
- In each **connection** (SSH/RDP/etc.), set:
  - `recording-path` = `/var/lib/guacamole/recordings`  
  - (optional) `recording-name` = `${USERNAME}-${CONNECTION_NAME}-${START_TIME}`
- Recordings become viewable from **History → View**.

### 7.3 QuickConnect (ad-hoc)
- QuickConnect bar accepts URIs like:  
  `ssh://10.10.10.10:22/?username=ubuntu`  
- Allowed protocols configured by `quickconnect-allowed-protocols` (default: `rdp,ssh,vnc`).
- **Recommendation:** Avoid passwords in URIs; use vaulted creds.

### 7.4 Encrypted JSON authentication
- The script sets `json-secret-key` (prompt 3).
- A service can POST an **encrypted+signed** token to `/api/tokens` to log users into specific connections.  
- Minimal test (replace `SECRET_HEX` with your `json-secret-key`):

```bash
SECRET_HEX="<32-hex-from-guacamole.properties>"
cat >/tmp/payload.json <<'JSON'
{
  "username":"adhoc",
  "expires":"2030-01-01T00:00:00Z",
  "connections":[{"name":"My SSH","protocol":"ssh","parameters":{"hostname":"10.10.10.10","port":"22","username":"ubuntu"}}]
}
JSON

HMAC=$(openssl dgst -sha256 -mac HMAC -macopt hexkey:${SECRET_HEX} -binary /tmp/payload.json | base64 -w0)
openssl enc -aes-128-cbc -K ${SECRET_HEX} -iv 00000000000000000000000000000000 -nosalt -a \
  -in <(printf "%s" "$(echo -n "$HMAC" | base64 -d)"; cat /tmp/payload.json) \
  -out /tmp/token.b64

curl --data-urlencode "data=$(cat /tmp/token.b64)" http://127.0.0.1:8080/guacamole/api/tokens
```

---

## 8) Database management

**Credentials (default)**  
- DB: `guacamole_db`  
- User: `guacamole_user`  
- Pass: `123Beta`

**Backup**  
```bash
sudo mariadb-dump guacamole_db | gzip -9 > ~/guacamole_db_$(date +%F_%H%M).sql.gz
```

**Restore**  
```bash
gunzip -c ~/guacamole_db_YYYY-MM-DD_HHMM.sql.gz | sudo mariadb guacamole_db
```

> The installer auto-backs up and **drops** `guacamole_db` on every run to ensure a **fresh** install.

---

## 9) Troubleshooting

**A. APT errors: “Couldn’t create temporary file /tmp/…”**  
The script now **heals `/tmp`** (ensures `chmod 1777` and remounts RW) and retries APT, temporarily disabling noisy PPAs/ESM if needed.

**B. Tomcat starts but `/guacamole/` 404/500**  
- Check WAR deployed: `/opt/tomcat/webapps/guacamole.war` (~7–8 MB).  
- Check logs: `sudo tail -n 200 /opt/tomcat/logs/catalina.out`.

**C. “Protocol violation” or weird runtime**  
- Confirm **guacd** and **client** both **1.6.0**.  
- This Jakarta path is advanced; if instability persists, consider **Tomcat 9** (supported path below).

**D. DB auth fails**  
- Verify `/etc/guacamole/guacamole.properties` `mysql-*` values.  
- Ensure JDBC driver exists: `/etc/guacamole/lib/mariadb-java-client-*.jar`.

**E. Recordings missing**  
- Ensure connection has `recording-path` set and Tomcat can read the directory (group `tomcat` + `2750` permissions).  
- Playback requires **history recording storage** extension JAR in `/etc/guacamole/extensions`.

---

## 10) Upgrades / re-running the script

- Re-running `guac.sh` performs another **destructive** reinstall:
  - Backs up config + DB.
  - Drops DB, recreates, reloads schema.  
- For **in-place upgrades** preserving DB, request the **non-destructive** variant.

---

## 11) Rollback to a **supported** stack (Tomcat 9)

If you need the officially supported path for Guacamole 1.6.0:

```bash
# stop Tomcat 10
sudo systemctl stop tomcat

# swap Tomcat
T9=9.0.108
sudo rm -rf /opt/tomcat
sudo mkdir -p /opt/tomcat
cd /tmp && wget -q https://archive.apache.org/dist/tomcat/tomcat-9/v${T9}/bin/apache-tomcat-${T9}.tar.gz
sudo tar -xzf apache-tomcat-${T9}.tar.gz -C /opt/tomcat --strip-components=1
sudo chown -R tomcat:tomcat /opt/tomcat

# restart
sudo systemctl start tomcat
```

No migration needed; Guacamole 1.6.0 targets the **javax** APIs Tomcat 9 uses.

---

## 12) File map & important knobs

- `/etc/guacamole/guacamole.properties`
  - `mysql-*` DB settings
  - `json-secret-key` (Encrypted JSON)
  - `quickconnect-allowed-protocols`
  - `recording-search-path`
  - `use-remote-address` (enable when behind Nginx)
- `/etc/guacamole/extensions/*.jar` — enable/disable features by adding/removing JARs.
- `/etc/guacamole/lib/*.jar` — JDBC driver.
- `/var/lib/guacamole/recordings` — server-side recordings store.
- `/opt/tomcat/webapps/guacamole.war` — migrated WAR.

---

## 13) Appendix: Example hardening (optional)

**Remove Tomcat default apps**
```bash
sudo rm -rf /opt/tomcat/webapps/{docs,examples,host-manager,manager,ROOT}
sudo systemctl restart tomcat
```

**Limit access with UFW (direct mode)**
```bash
sudo ufw allow from <trusted-cidr> to any port 8080 proto tcp
sudo ufw enable
```

**Systemd hardening already included**: `ProtectSystem=full`, `ProtectHome=true`, `PrivateTmp=true`, `NoNewPrivileges=true` for both `guacd` & `tomcat`.

---

### Support / Notes

- This installer intentionally targets the **Jakarta** path on **Tomcat 10** using the official **Jakarta migration** tool to rewrite Guacamole 1.6.0. This is not the upstream-supported combo; validate thoroughly in staging.
- For maximum stability today, use **Tomcat 9** with Guacamole 1.6.0.
